@preconcurrency import Foundation
@preconcurrency import Dispatch
import Darwin

private struct AsrLengthPrefixedDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var payloads: [Data] = []
        while buffer.count >= 4 {
            let length = (UInt32(buffer[0]) << 24)
                | (UInt32(buffer[1]) << 16)
                | (UInt32(buffer[2]) << 8)
                | UInt32(buffer[3])
            guard length > 0 else {
                throw AsrWorkerTransportFault.malformedFrame("frame vacío")
            }
            guard length <= AsrWorkerProtocol.maximumMessageBytes else {
                throw AsrWorkerTransportFault.oversizedFrame
            }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            payloads.append(buffer.subdata(in: 4 ..< total))
            buffer.removeSubrange(0 ..< total)
        }
        return payloads
    }
}

/// Process-backed prototype transport. It deliberately owns only framing and
/// process lifecycle; envelope semantics stay in AsrWorkerProtocol.
/// The transport's mutable fields are protected by `lock`; supervisor
/// transitions remain serialized by `stateQueue`.
final class ProcessAsrWorkerTransport: AsrWorkerTransport {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let readQueue = DispatchQueue(label: "ClassScribe.AsrWorkerProcessTransport.read")
    private let writeQueue = DispatchQueue(label: "ClassScribe.AsrWorkerProcessTransport.write")
    private let lock = NSLock()

    private var messageHandler: ((AsrWorkerEnvelope) -> Void)?
    private var exitHandler: ((AsrWorkerExit) -> Void)?
    private var faultHandler: ((AsrWorkerTransportFault) -> Void)?
    private var terminatedStorage = false
    private var terminationRequested = false
    private var processExited = false
    private var exitReported = false
    private var faultReported = false
    private var terminateCountStorage = 0
    private var decoder = AsrLengthPrefixedDecoder()

    init(executableURL: URL, arguments: [String]) {
        process = Process()
        input = Pipe()
        output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
    }

    var onMessage: ((AsrWorkerEnvelope) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }

    var onExit: ((AsrWorkerExit) -> Void)? {
        get { lock.withLock { exitHandler } }
        set { lock.withLock { exitHandler = newValue } }
    }

    var onFault: ((AsrWorkerTransportFault) -> Void)? {
        get { lock.withLock { faultHandler } }
        set { lock.withLock { faultHandler = newValue } }
    }

    var isTerminated: Bool {
        lock.withLock { terminatedStorage }
    }

    var terminateCount: Int {
        lock.withLock { terminateCountStorage }
    }

    var processIdentifier: Int32? {
        lock.withLock {
            guard process.processIdentifier > 0 else { return nil }
            return process.processIdentifier
        }
    }

    var hasExited: Bool {
        lock.withLock { processExited || !process.isRunning }
    }

    func start(with hello: AsrWorkerEnvelope) {
        do {
            _ = try hello.encodedData()
            let readQueue = self.readQueue
            let readWork = DispatchWorkItem { [weak self] in
                self?.readAvailable()
            }
            output.fileHandleForReading.readabilityHandler = { _ in
                readQueue.async(execute: readWork)
            }
            let exitWork = DispatchWorkItem { [weak self] in
                self?.reportExit(self?.process.terminationStatus ?? -1)
            }
            process.terminationHandler = { process in
                _ = process
                readQueue.async(execute: exitWork)
            }
            try process.run()
            send(hello)
        } catch {
            reportFault(.launchFailed(String(describing: error)))
        }
    }

    /// Enqueues one framed write and returns immediately. The writer queue is
    /// never used by terminate(), so a blocked pipe cannot block kill.
    func send(_ message: AsrWorkerEnvelope) {
        guard !isTerminated else { return }
        do {
            let payload = try message.encodedData()
            let length = UInt32(payload.count)
            var frame = Data([
                UInt8((length >> 24) & 0xff),
                UInt8((length >> 16) & 0xff),
                UInt8((length >> 8) & 0xff),
                UInt8(length & 0xff),
            ])
            frame.append(payload)
            writeQueue.async(execute: DispatchWorkItem { [weak self] in
                guard let self, !self.isTerminated else { return }
                do {
                    try self.input.fileHandleForWriting.write(contentsOf: frame)
                } catch {
                    self.reportFault(.writeFailed(String(describing: error)))
                }
            })
        } catch {
            reportFault(.writeFailed(String(describing: error)))
        }
    }

    /// Kill is intentionally synchronous only for issuing the signal. It does
    /// not wait on the writer queue or on process shutdown.
    func terminate() {
        let shouldKill = lock.withLock { () -> Bool in
            guard !terminationRequested else { return false }
            terminationRequested = true
            terminatedStorage = true
            terminateCountStorage += 1
            return process.isRunning
        }
        output.fileHandleForReading.readabilityHandler = nil
        if shouldKill {
            process.terminate()
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func readAvailable() {
        guard !isTerminated else { return }
        let handle = output.fileHandleForReading
        let data = handle.availableData
        guard !data.isEmpty else {
            if let status = exitedStatusIfAvailable() {
                reportExit(status)
            } else {
                reportFault(.unexpectedEOF)
            }
            return
        }

        do {
            let payloads = try decoder.append(data)
            for payload in payloads {
                do {
                    let message = try AsrWorkerEnvelope.decode(payload)
                    let handler = lock.withLock { messageHandler }
                    handler?(message)
                } catch {
                    reportFault(.malformedFrame(String(describing: error)))
                    return
                }
            }
        } catch let fault as AsrWorkerTransportFault {
            reportFault(fault)
        } catch {
            reportFault(.readFailed(String(describing: error)))
        }
    }

    private func reportExit(_ status: Int32) {
        let handler = lock.withLock { () -> ((AsrWorkerExit) -> Void)? in
            guard !exitReported else { return nil }
            exitReported = true
            processExited = true
            terminatedStorage = true
            guard !terminationRequested, !faultReported else { return nil }
            return exitHandler
        }
        handler?(status == 0 ? .clean(status) : .crashed(status))
    }

    private func exitedStatusIfAvailable() -> Int32? {
        for _ in 0 ..< 10 {
            let status = lock.withLock { () -> Int32? in
                guard !process.isRunning else { return nil }
                return process.terminationStatus
            }
            if let status { return status }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    private func reportFault(_ fault: AsrWorkerTransportFault) {
        let handler = lock.withLock { () -> ((AsrWorkerTransportFault) -> Void)? in
            guard !faultReported else { return nil }
            faultReported = true
            return faultHandler
        }
        handler?(fault)
        terminate()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
