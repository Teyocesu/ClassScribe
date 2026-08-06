import AppKit
import AudioTapLib
@preconcurrency import AVFoundation
import Darwin
import Foundation
import Observation

actor LiveAudioBufferStore {
    private let sampleRate = 16000
    private let retainedSeconds = 45
    private var generation = UUID()
    private var samples: [Float] = []
    private var baseSampleIndex: Int64 = 0
    private var totalSampleCount: Int64 = 0
    private(set) var latestLevelDBFS = -120.0

    func append(_ buffer: LiveAudioBuffer, generation expectedGeneration: UUID) {
        guard expectedGeneration == generation else { return }
        let mono = Self.mono16k(buffer)
        guard !mono.isEmpty else { return }
        samples.append(contentsOf: mono)
        totalSampleCount += Int64(mono.count)
        let meanSquare = mono.reduce(0.0) { $0 + Double($1 * $1) } / Double(mono.count)
        latestLevelDBFS = meanSquare > 0 ? 10 * log10(meanSquare) : -120

        let maximum = sampleRate * retainedSeconds
        if samples.count > maximum {
            let removed = samples.count - maximum
            samples.removeFirst(removed)
            baseSampleIndex += Int64(removed)
        }
    }

    func reset() -> UUID {
        generation = UUID()
        samples.removeAll(keepingCapacity: true)
        baseSampleIndex = 0
        totalSampleCount = 0
        latestLevelDBFS = -120
        return generation
    }

    func totalSamples() -> Int64 {
        totalSampleCount
    }

    func window(seconds: Double, endingAt endIndex: Int64? = nil) -> (samples: [Float], start: TimeInterval)? {
        let end = min(endIndex ?? totalSampleCount, totalSampleCount)
        let wanted = Int64(seconds * Double(sampleRate))
        let start = max(baseSampleIndex, end - wanted)
        guard end > start else { return nil }
        let lower = Int(start - baseSampleIndex)
        let upper = Int(end - baseSampleIndex)
        guard lower >= 0, upper <= samples.count else { return nil }
        return (Array(samples[lower ..< upper]), Double(start) / Double(sampleRate))
    }

    func hasRecentPause(milliseconds: Int = 550) -> Bool {
        let count = min(samples.count, sampleRate * milliseconds / 1000)
        guard count > 0 else { return true }
        let tail = samples.suffix(count)
        let meanSquare = tail.reduce(0.0) { $0 + Double($1 * $1) } / Double(count)
        let db = meanSquare > 0 ? 10 * log10(meanSquare) : -120
        return db < -43
    }

    private static func mono16k(_ buffer: LiveAudioBuffer) -> [Float] {
        guard buffer.channelCount > 0, buffer.sampleRate > 0 else { return [] }
        let frames = buffer.samples.count / buffer.channelCount
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0 ..< frames {
            var sum: Float = 0
            for channel in 0 ..< buffer.channelCount {
                sum += buffer.samples[frame * buffer.channelCount + channel]
            }
            mono[frame] = sum / Float(buffer.channelCount)
        }
        guard buffer.sampleRate != 16000 else { return mono }
        let outputCount = max(1, Int(Double(mono.count) * 16000 / Double(buffer.sampleRate)))
        return (0 ..< outputCount).map { index in
            let source = min(mono.count - 1, Int(Double(index) * Double(buffer.sampleRate) / 16000))
            return mono[source]
        }
    }
}

enum WavFile {
    static func wrapFloat32Raw(_ rawURL: URL, destination: URL, sampleRate: Int = 16000) throws {
        let rawSize = try validatedFloat32RawByteCount(rawURL)
        var header = Data()
        header.appendASCII("RIFF")
        header.appendUInt32LE(UInt32(36 + rawSize))
        header.appendASCII("WAVEfmt ")
        header.appendUInt32LE(16)
        header.appendUInt16LE(3) // IEEE float
        header.appendUInt16LE(1)
        header.appendUInt32LE(UInt32(sampleRate))
        header.appendUInt32LE(UInt32(sampleRate * 4))
        header.appendUInt16LE(4)
        header.appendUInt16LE(32)
        header.appendASCII("data")
        header.appendUInt32LE(UInt32(rawSize))

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        let input = try FileHandle(forReadingFrom: rawURL)
        let output = try FileHandle(forWritingTo: temporary)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.write(contentsOf: header)
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        try output.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        shouldRemoveTemporary = false
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func validateFloat32Raw(_ rawURL: URL, sampleRate: Int = 16000) throws -> TimeInterval {
        let byteCount = try validatedFloat32RawByteCount(rawURL)
        return Double(byteCount / MemoryLayout<Float>.size) / Double(sampleRate)
    }

    /// Rebuilds the canonical WAV without deleting the RAW evidence. If an invalid
    /// canonical WAV exists, an owner-only copy is retained before replacement.
    static func recoverFloat32Raw(
        _ rawURL: URL,
        destination: URL,
        sampleRate: Int = 16000,
    ) throws -> TimeInterval {
        _ = try validateFloat32Raw(rawURL, sampleRate: sampleRate)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CaptureError.invalidAudioFile
            }
            if let duration = try? validate(destination) {
                return duration
            }
            let preserved = destination.deletingLastPathComponent().appendingPathComponent(
                "source-invalid-preserved-\(UUID().uuidString).wav",
            )
            try fileManager.copyItem(at: destination, to: preserved)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preserved.path)
        }
        try wrapFloat32Raw(rawURL, destination: destination, sampleRate: sampleRate)
        return try validate(destination)
    }

    static func writeFloat32(_ samples: [Float], to destination: URL, sampleRate: Int = 16000) throws {
        let temporary = destination.deletingPathExtension().appendingPathExtension("raw")
        let data = samples.withUnsafeBytes { Data($0) }
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try wrapFloat32Raw(temporary, destination: destination, sampleRate: sampleRate)
    }

    static func validate(_ url: URL) throws -> TimeInterval {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CaptureError.invalidAudioFile
        }
        let size = values.fileSize ?? 0
        guard size > 0 else { throw CaptureError.emptyAudioFile }
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.sampleRate > 0 else { throw CaptureError.emptyAudio }
        guard file.length > 0 else { throw CaptureError.wavHeaderOnly }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private static func validatedFloat32RawByteCount(_ rawURL: URL) throws -> Int {
        let values = try rawURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        let rawSize = values.fileSize ?? 0
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              rawSize > 0,
              rawSize <= Int(UInt32.max) - 36,
              rawSize.isMultiple(of: MemoryLayout<Float>.size)
        else { throw CaptureError.invalidRawAudio }
        return rawSize
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt32>.size))
    }
}

enum CaptureError: LocalizedError, Sendable {
    case sourceMissing
    case permissionDenied
    case noProcesses
    case emptyAudio
    case wavHeaderOnly
    case emptyAudioFile
    case invalidAudioFile
    case invalidRawAudio
    case notRecording
    case audioFinalization(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing: "Selecciona una fuente de audio."
        case .permissionDenied: "El permiso de micrófono fue denegado. Actívalo en Privacidad y seguridad."
        case .noProcesses: "La aplicación elegida ya no está en ejecución."
        case .emptyAudio: "El archivo de audio está vacío. El original se conservó para diagnóstico."
        case .wavHeaderOnly: "El WAV solo contiene cabecera; el micrófono no entregó frames. El archivo se conservó para diagnóstico."
        case .emptyAudioFile: "El archivo de audio no llegó a crearse con datos. Se conservó la sesión para diagnóstico."
        case .invalidAudioFile: "El audio no es un archivo regular propio de la sesión. No se siguió ni reemplazó ningún enlace."
        case .invalidRawAudio: "El audio crudo conservado está vacío, truncado o no es un archivo regular."
        case .notRecording: "No hay una clase en grabación."
        case let .audioFinalization(detail): "No se pudo finalizar el audio: \(detail)"
        }
    }
}

struct CaptureStopResult: Sendable, Equatable {
    var url: URL
    var duration: TimeInterval
}

@MainActor
@Observable
final class CaptureController {
    private(set) var applications: [RunningApplication] = []
    private(set) var microphones: [MicrophoneOption] = []
    private(set) var levelDBFS = -120.0
    private(set) var isCapturing = false
    private(set) var isStarting = false

    let liveStore = LiveAudioBufferStore()
    private var onlineSession: AudioCaptureSession?
    private var microphoneCapture: MicCaptureHandler?
    private var levelTimer: Timer?
    private var rawOnlineURL: URL?
    private var sourceWAVURL: URL?
    private var terminalCaptureFailure: String?
    private var completedStop: Result<CaptureStopResult, CaptureError>?
    private var stopTask: Task<Result<CaptureStopResult, CaptureError>, Never>?

    var isBusy: Bool {
        isCapturing || isStarting || terminalCaptureFailure != nil
    }

    func refreshSources() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        applications = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  let name = app.localizedName,
                  !name.isEmpty else { return nil }
            return RunningApplication(
                id: app.processIdentifier,
                name: name,
                bundleIdentifier: app.bundleIdentifier ?? "",
                bundleURL: app.bundleURL,
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified,
        )
        microphones = discovery.devices.map {
            MicrophoneOption(id: $0.uniqueID, name: $0.localizedName)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start(
        mode: CaptureMode,
        application: RunningApplication?,
        microphone: MicrophoneOption?,
        folder: URL,
    ) async throws -> URL {
        guard !isBusy else { throw CaptureError.notRecording }
        isStarting = true
        defer { isStarting = false }
        terminalCaptureFailure = nil
        completedStop = nil
        stopTask = nil
        sourceWAVURL = nil
        rawOnlineURL = nil
        let liveGeneration = await liveStore.reset()
        let sourceURL = folder.appendingPathComponent("source.wav")
        let sink: LiveAudioSink = { [liveStore] buffer in
            Task { await liveStore.append(buffer, generation: liveGeneration) }
        }

        switch mode {
        case .online:
            guard let application else { throw CaptureError.sourceMissing }
            var pids: [pid_t] = [application.id]
            if let bundleURL = application.bundleURL {
                pids.append(contentsOf: ProcessTreeEnumerator.pidsRooted(in: bundleURL))
            }
            pids = Array(Set(pids)).filter { $0 > 0 && $0 != getpid() }
            guard !pids.isEmpty else { throw CaptureError.noProcesses }
            let rawURL = folder.appendingPathComponent("source.raw")
            let session = AudioCaptureSession(
                pids: pids,
                appOutputURL: rawURL,
                micOutputURL: nil,
                appLiveSink: sink,
            )
            try session.start()
            rawOnlineURL = rawURL
            onlineSession = session

        case .inPerson:
            let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
            MicCaptureDiagnostics.record(
                "authorization=\(authorization.rawValue) bundle=\(Bundle.main.bundleIdentifier ?? "unknown") requested=\(microphone?.id ?? "none")",
            )
            guard await requestMicrophonePermission() else { throw CaptureError.permissionDenied }
            guard let microphone else { throw CaptureError.sourceMissing }
            let capture = MicCaptureHandler(outputURL: sourceURL, debugLogging: true, liveSink: sink)
            try capture.start(deviceUID: microphone.id)
            microphoneCapture = capture
            do {
                try await capture.waitForFirstBuffer()
            } catch {
                microphoneCapture = nil
                throw error
            }
        }

        sourceWAVURL = sourceURL
        isCapturing = true
        startLevelTimer()
        return sourceURL
    }

    func stop() async throws -> CaptureStopResult {
        if let completedStop {
            return try completedStop.get()
        }
        if let stopTask {
            return try await stopTask.value.get()
        }
        guard isCapturing, let sourceWAVURL else { throw CaptureError.notRecording }
        isCapturing = false
        levelTimer?.invalidate()
        levelTimer = nil
        let rawToWrap: URL?
        if let onlineSession {
            _ = onlineSession.stop()
            self.onlineSession = nil
            rawToWrap = rawOnlineURL
        } else {
            rawToWrap = nil
        }
        microphoneCapture?.stop()
        microphoneCapture = nil
        levelDBFS = -120
        let finalization = Task.detached(priority: .userInitiated) { () -> Result<CaptureStopResult, CaptureError> in
            do {
                if let rawToWrap {
                    try WavFile.wrapFloat32Raw(rawToWrap, destination: sourceWAVURL)
                }
                let duration = try WavFile.validate(sourceWAVURL)
                if let rawToWrap {
                    try? FileManager.default.removeItem(at: rawToWrap)
                }
                return .success(CaptureStopResult(url: sourceWAVURL, duration: duration))
            } catch let error as CaptureError {
                return .failure(error)
            } catch {
                return .failure(CaptureError.audioFinalization(error.localizedDescription))
            }
        }
        stopTask = finalization
        let result = await finalization.value
        stopTask = nil
        completedStop = result
        return try result.get()
    }

    func abortPreservingAudio() async {
        guard isCapturing else { return }
        _ = try? await stop()
    }

    func takeTerminalFailure() -> String? {
        defer { terminalCaptureFailure = nil }
        return terminalCaptureFailure
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let onlineSession = self.onlineSession {
                    self.levelDBFS = onlineSession.appLevelDBFS
                } else if let microphoneCapture = self.microphoneCapture {
                    if let error = microphoneCapture.terminalError {
                        self.terminateMicrophoneCapture(error)
                        return
                    }
                    self.levelDBFS = microphoneCapture.currentLevelDBFS
                }
            }
        }
    }

    private func terminateMicrophoneCapture(_ error: MicCaptureError) {
        guard isCapturing else { return }
        microphoneCapture?.stop()
        microphoneCapture = nil
        isCapturing = false
        levelTimer?.invalidate()
        levelTimer = nil
        levelDBFS = -120
        terminalCaptureFailure = error.localizedDescription
        MicCaptureDiagnostics.record("CaptureController stopped after terminal microphone error")
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
