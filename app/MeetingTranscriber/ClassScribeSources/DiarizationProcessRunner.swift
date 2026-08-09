import ClassScribeProcessingIPC
import Darwin
@preconcurrency import Foundation

enum DiarizationProcessTermination: Equatable, Sendable {
    case exit(Int32)
    case signal(Int32)
}

enum DiarizationProcessError: LocalizedError, Equatable, Sendable {
    case helperUnavailable
    case invalidAudioLocation
    case launchFailed
    case terminatedBySignal(Int32)
    case nonzeroExit(Int32)
    case missingResponse
    case oversizedResponse
    case malformedResponse
    case incompatibleProtocol
    case mismatchedJob
    case workerFailure(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "No se encontró el procesador aislado de hablantes. El audio y la transcripción se conservaron."
        case .invalidAudioLocation:
            "No se pudo preparar el audio para identificar hablantes. El archivo original se conservó."
        case .launchFailed:
            "No se pudo iniciar la identificación aislada de hablantes. Puedes reintentar."
        case let .terminatedBySignal(signal):
            "La identificación de hablantes falló de forma aislada (señal \(signal)); ClassScribe, el audio y el texto siguen seguros."
        case let .nonzeroExit(status):
            "La identificación de hablantes terminó con error \(status). El audio y la transcripción siguen disponibles."
        case .missingResponse, .oversizedResponse, .malformedResponse, .incompatibleProtocol, .mismatchedJob:
            "La identificación de hablantes devolvió una respuesta inválida. El audio y la transcripción siguen disponibles."
        case .workerFailure:
            "No se pudieron identificar los hablantes. La transcripción completa se conservó y puedes reintentar."
        case .timedOut:
            "La identificación de hablantes excedió el tiempo máximo. El audio y la transcripción se conservaron para reintentar."
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var cancellationRequested = false
    private var timeoutRequested = false

    init(process: Process) {
        self.process = process
    }

    func launch() throws {
        lock.lock()
        let cancelledBeforeLaunch = cancellationRequested
        let timedOutBeforeLaunch = timeoutRequested
        lock.unlock()
        if cancelledBeforeLaunch {
            if timedOutBeforeLaunch { throw DiarizationProcessError.timedOut }
            throw CancellationError()
        }

        try process.run()

        lock.lock()
        let shouldTerminate = cancellationRequested && process.isRunning
        lock.unlock()
        if shouldTerminate {
            terminateAndEscalateIfNeeded()
        }
    }

    func requestCancellation() {
        requestStop(timedOut: false)
    }

    func requestTimeout() {
        requestStop(timedOut: true)
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeoutRequested
    }

    private func requestStop(timedOut: Bool) {
        lock.lock()
        cancellationRequested = true
        timeoutRequested = timeoutRequested || timedOut
        let shouldTerminate = process.isRunning
        lock.unlock()
        if shouldTerminate {
            terminateAndEscalateIfNeeded()
        }
    }

    /// A stop request can arrive in the narrow gap between the pre-launch
    /// cancellation check and `Process.run()`. Both that path and a normal
    /// in-flight timeout need the same TERM-then-KILL escalation; otherwise a
    /// helper that ignores SIGTERM could keep the continuation suspended.
    private func terminateAndEscalateIfNeeded() {
        guard process.isRunning else { return }
        let processID = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning, process.processIdentifier == processID {
                Darwin.kill(processID, SIGKILL)
            }
        }
    }
}

private final class ProcessContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<DiarizationProcessTermination, Error>

    init(_ continuation: CheckedContinuation<DiarizationProcessTermination, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: DiarizationProcessTermination) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

enum DiarizationSubprocess {
    static func execute(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeout: TimeInterval? = nil,
    ) async throws -> DiarizationProcessTermination {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let box = ProcessBox(process: process)
        let timeoutTask: Task<Void, Never>? = timeout.map { timeout in
            Task.detached(priority: .utility) {
                do {
                    try await Task.sleep(for: .seconds(max(0, timeout)))
                    box.requestTimeout()
                } catch {
                    // Normal completion cancels this watchdog.
                }
            }
        }
        defer { timeoutTask?.cancel() }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let termination = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<DiarizationProcessTermination, Error>) in
                let continuationBox = ProcessContinuationBox(continuation)
                process.terminationHandler = { finished in
                    let value: DiarizationProcessTermination = switch finished.terminationReason {
                    case .exit: .exit(finished.terminationStatus)
                    case .uncaughtSignal: .signal(finished.terminationStatus)
                    @unknown default: .signal(finished.terminationStatus)
                    }
                    continuationBox.resume(returning: value)
                }
                do {
                    try box.launch()
                } catch {
                    process.terminationHandler = nil
                    continuationBox.resume(throwing: error)
                }
            }
            try Task.checkCancellation()
            if box.didTimeOut {
                throw DiarizationProcessError.timedOut
            }
            return termination
        } onCancel: {
            box.requestCancellation()
        }
    }
}

actor DiarizationProcessRunner {
    private static let maximumResponseBytes = 10 * 1024 * 1024
    private let explicitExecutableURL: URL?
    private let processingTimeout: TimeInterval

    init(executableURL: URL? = nil, processingTimeout: TimeInterval = 30 * 60) {
        explicitExecutableURL = executableURL
        self.processingTimeout = max(0, processingTimeout)
    }

    func run(audioURL: URL) async throws -> DiarizationWorkerResponse {
        try Task.checkCancellation()
        let audio = audioURL.standardizedFileURL
        let folder = audio.deletingLastPathComponent().standardizedFileURL
        let audioValues = try? audio.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard folder.appendingPathComponent(audio.lastPathComponent).standardizedFileURL == audio,
              FileManager.default.fileExists(atPath: audio.path),
              audioValues?.isRegularFile == true,
              audioValues?.isSymbolicLink != true
        else { throw DiarizationProcessError.invalidAudioLocation }

        let executableURL = try resolvedExecutableURL()
        let jobID = UUID()
        let requestName = ".diarization-request-\(jobID.uuidString).json"
        let responseName = ".diarization-response-\(jobID.uuidString).json"
        let requestURL = folder.appendingPathComponent(requestName)
        let responseURL = folder.appendingPathComponent(responseName)
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
        }

        let request = DiarizationWorkerRequest(
            jobID: jobID,
            inputFilename: audio.lastPathComponent,
            outputFilename: responseName,
        )
        try writePrivateAtomically(JSONEncoder().encode(request), to: requestURL)

        let termination: DiarizationProcessTermination
        do {
            termination = try await DiarizationSubprocess.execute(
                executableURL: executableURL,
                arguments: [requestName],
                currentDirectoryURL: folder,
                timeout: processingTimeout,
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DiarizationProcessError {
            throw error
        } catch {
            throw DiarizationProcessError.launchFailed
        }

        switch termination {
        case let .signal(signal):
            throw DiarizationProcessError.terminatedBySignal(signal)
        case let .exit(status) where status != 0:
            if let response = try? decodeResponse(at: responseURL),
               response.schemaVersion == DiarizationIPC.schemaVersion,
               response.jobID == jobID,
               let failure = response.failure {
                throw DiarizationProcessError.workerFailure(failure.code)
            }
            throw DiarizationProcessError.nonzeroExit(status)
        case .exit:
            break
        }

        let response = try decodeResponse(at: responseURL)
        guard response.schemaVersion == DiarizationIPC.schemaVersion else {
            throw DiarizationProcessError.incompatibleProtocol
        }
        guard response.jobID == jobID else { throw DiarizationProcessError.mismatchedJob }
        if let failure = response.failure {
            throw DiarizationProcessError.workerFailure(failure.code)
        }
        guard response.spans.allSatisfy({
            $0.start.isFinite && $0.end.isFinite && $0.quality.isFinite
                && $0.start >= 0 && $0.end >= $0.start
        }), response.embeddings.values.allSatisfy({ values in
            !values.isEmpty && values.allSatisfy(\.isFinite)
        }) else { throw DiarizationProcessError.malformedResponse }
        return response
    }

    private func decodeResponse(at url: URL) throws -> DiarizationWorkerResponse {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DiarizationProcessError.missingResponse
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DiarizationProcessError.malformedResponse
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw DiarizationProcessError.missingResponse }
        guard size <= Self.maximumResponseBytes else { throw DiarizationProcessError.oversizedResponse }
        do {
            return try JSONDecoder().decode(
                DiarizationWorkerResponse.self,
                from: Data(contentsOf: url, options: [.mappedIfSafe]),
            )
        } catch let error as DiarizationProcessError {
            throw error
        } catch {
            throw DiarizationProcessError.malformedResponse
        }
    }

    private func resolvedExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let explicitExecutableURL {
            candidates.append(explicitExecutableURL)
        }
        candidates.append(
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClassScribeDiarizer"),
        )
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("ClassScribeDiarizer"))
        }
        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(current.appendingPathComponent(".build/debug/ClassScribeDiarizer"))
        candidates.append(current.appendingPathComponent(".build/release/ClassScribeDiarizer"))
        candidates.append(current.appendingPathComponent(".toolchain/ClassScribePackage/.build/debug/ClassScribeDiarizer"))
        candidates.append(current.appendingPathComponent(".toolchain/ClassScribePackage/.build/release/ClassScribeDiarizer"))

        for candidate in candidates.map(\.standardizedFileURL) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw DiarizationProcessError.helperUnavailable
    }

    private func writePrivateAtomically(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".diarization-write-\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600],
        ) else { throw DiarizationProcessError.invalidAudioLocation }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try fileManager.moveItem(at: temporary, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
