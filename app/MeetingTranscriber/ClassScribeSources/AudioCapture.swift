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
    private var retainedStartOffset = 0
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
        let retainedCount = samples.count - retainedStartOffset
        if retainedCount > maximum {
            let removed = retainedCount - maximum
            retainedStartOffset += removed
            baseSampleIndex += Int64(removed)
            // Advance the logical ring in O(1) for normal callbacks and only
            // compact occasionally. Removing from the Array on every callback
            // copied the entire 45-second window repeatedly.
            if retainedStartOffset >= sampleRate * 5 {
                samples.removeFirst(retainedStartOffset)
                retainedStartOffset = 0
            }
        }
    }

    func reset() -> UUID {
        generation = UUID()
        samples.removeAll(keepingCapacity: true)
        retainedStartOffset = 0
        baseSampleIndex = 0
        totalSampleCount = 0
        latestLevelDBFS = -120
        return generation
    }

    func totalSamples() -> Int64 {
        totalSampleCount
    }

    /// Waits for the capture callback path to append at least one sample after
    /// `baseline`. This deliberately checks frame delivery rather than signal
    /// energy: a lecturer can be silent at startup, but a healthy audio device
    /// must still deliver silent frames. The actor is reentrant while sleeping,
    /// so callback tasks can continue appending during the wait.
    func waitForSamples(after baseline: Int64, timeout: TimeInterval) async throws -> Int64? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
        while totalSampleCount <= baseline {
            try Task.checkCancellation()
            guard clock.now < deadline else { return nil }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        return totalSampleCount
    }

    func window(
        seconds: Double,
        endingAt endIndex: Int64? = nil,
        requiresCompleteHistory: Bool = false,
    ) -> (samples: [Float], start: TimeInterval)? {
        let end = min(endIndex ?? totalSampleCount, totalSampleCount)
        let wanted = Int64(seconds * Double(sampleRate))
        let requestedStart = max(0, end - wanted)
        let start = max(baseSampleIndex, requestedStart)
        // Live ASR retries target a precise historical window. If its leading
        // samples already rotated out of the ring, returning a shorter slice
        // would silently commit a partial transcript for that range. Let the
        // caller rebase to a recent complete window instead.
        guard !requiresCompleteHistory || start == requestedStart else { return nil }
        guard end > start else { return nil }
        let lower = retainedStartOffset + Int(start - baseSampleIndex)
        let upper = retainedStartOffset + Int(end - baseSampleIndex)
        guard lower >= retainedStartOffset, upper <= samples.count else { return nil }
        return (Array(samples[lower ..< upper]), Double(start) / Double(sampleRate))
    }

    func hasRecentPause(milliseconds: Int = 550) -> Bool {
        let retainedCount = samples.count - retainedStartOffset
        let count = min(retainedCount, sampleRate * milliseconds / 1000)
        guard count > 0 else { return true }
        let tail = samples.suffix(count)
        let meanSquare = tail.reduce(0.0) { $0 + Double($1 * $1) } / Double(count)
        let db = meanSquare > 0 ? 10 * log10(meanSquare) : -120
        return db < -43
    }

    private static func mono16k(_ buffer: LiveAudioBuffer) -> [Float] {
        guard buffer.channelCount > 0, buffer.sampleRate > 0 else { return [] }
        let frames = buffer.samples.count / buffer.channelCount
        guard frames > 0 else { return [] }
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
    case microphoneUnavailable
    case noProcesses
    case applicationAudioUnavailable
    case applicationAudioStopped
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
        case .microphoneUnavailable: "El micrófono seleccionado ya no está disponible. Conéctalo de nuevo o elige otro."
        case .noProcesses: "La aplicación elegida ya no está en ejecución."
        case .applicationAudioUnavailable:
            "La aplicación no entregó audio. Comprueba que siga abierta y revisa el permiso de Audio del sistema en Privacidad y seguridad."
        case .applicationAudioStopped:
            "La aplicación dejó de entregar audio. Se detuvo la captura para conservar lo grabado; comprueba que la app siga abierta y el permiso de Audio del sistema."
        case .emptyAudio: "El archivo de audio está vacío. El original se conservó para diagnóstico."
        case .wavHeaderOnly: "El micrófono no entregó audio. El archivo se conservó para diagnóstico."
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

/// Detects a dead callback stream without treating digital silence as a
/// failure. `sampleCount` advances for both audible and silent buffers; only a
/// complete absence of frames for `stallTimeout` is terminal.
struct AudioFrameWatchdog: Sendable {
    let stallTimeout: TimeInterval
    private(set) var lastSampleCount: Int64 = 0
    private(set) var lastProgressTime: TimeInterval = 0

    mutating func reset(sampleCount: Int64, now: TimeInterval) {
        lastSampleCount = sampleCount
        lastProgressTime = now
    }

    mutating func observe(sampleCount: Int64, now: TimeInterval) -> Bool {
        if sampleCount > lastSampleCount || now < lastProgressTime {
            reset(sampleCount: sampleCount, now: now)
            return false
        }
        return now - lastProgressTime >= stallTimeout
    }
}

/// Awaits the transient CoreAudio registration that follows process launch.
/// The wait stays inside the caller's structured task: cancellation ends it
/// immediately, and there is no delayed retry block that could start capture
/// after Stop or after the owning workflow has gone away.
struct AudioProcessStartupWaiter {
    static func waitUntilRegistered(
        pids: [pid_t],
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        registrationProbe: @escaping @Sendable ([pid_t]) -> Bool = AppAudioCapture.hasRegisteredAudioProcess(in:),
    ) async throws -> Bool {
        guard !pids.isEmpty else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
        let interval = max(0.01, pollInterval)
        while true {
            try Task.checkCancellation()
            if registrationProbe(pids) { return true }
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .seconds(interval))
        }
    }
}

@MainActor
@Observable
final class CaptureController {
    // Leave enough room for the first TCC prompt and for CoreAudio route
    // negotiation. Mid-session the AudioTap restart policy normally settles in
    // ~1.5 s; twelve seconds avoids false stops during a slow Bluetooth/USB
    // handoff while still bounding a genuinely dead callback stream.
    nonisolated static let onlineFirstBufferTimeout: TimeInterval = 30
    nonisolated static let onlineStallTimeout: TimeInterval = 12
    nonisolated static let onlineProcessRegistrationTimeout: TimeInterval = 3

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
    private var liveBufferContinuation: AsyncStream<LiveAudioBuffer>.Continuation?
    private var liveBufferTask: Task<Void, Never>?
    private var activeCaptureGeneration: UUID?
    private var onlineRootPID: pid_t?
    private var onlineHealthCheckInFlight = false
    private var onlineFrameWatchdog = AudioFrameWatchdog(stallTimeout: onlineStallTimeout)

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
        try Task.checkCancellation()
        isStarting = true
        defer { isStarting = false }
        terminalCaptureFailure = nil
        completedStop = nil
        stopTask = nil
        sourceWAVURL = nil
        rawOnlineURL = nil
        stopLiveBufferPump()
        let liveGeneration = await liveStore.reset()
        activeCaptureGeneration = nil
        onlineRootPID = nil
        onlineHealthCheckInFlight = false
        let sourceURL = folder.appendingPathComponent("source.wav")
        // The pump normally drains far faster than real time. A generous bound
        // still prevents unbounded memory if the process is heavily starved;
        // newest buffers are the useful ones for a live view, while the complete
        // WAV remains the durable source for final transcription.
        let (liveStream, liveContinuation) = AsyncStream<LiveAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(2_048),
        )
        let liveBufferTask = Task.detached(priority: .userInitiated) { [liveStore] in
            for await buffer in liveStream {
                guard !Task.isCancelled else { break }
                await liveStore.append(buffer, generation: liveGeneration)
            }
        }
        var keepLiveBufferPump = false
        defer {
            if !keepLiveBufferPump {
                liveContinuation.finish()
                liveBufferTask.cancel()
            }
        }
        let sink: LiveAudioSink = { buffer in
            // AsyncStream preserves callback order without blocking the audio
            // thread. Spawning one unstructured Task per buffer allowed tasks
            // to reach the actor out of order and could scramble live ASR.
            _ = liveContinuation.yield(buffer)
        }

        switch mode {
        case .online:
            guard let application else { throw CaptureError.sourceMissing }
            guard Self.processIsRunning(application.id) else { throw CaptureError.noProcesses }
            var pids: [pid_t] = [application.id]
            if let bundleURL = application.bundleURL {
                pids.append(contentsOf: ProcessTreeEnumerator.pidsRooted(in: bundleURL))
            }
            var seenPIDs = Set<pid_t>()
            pids = pids.filter {
                $0 > 0 && $0 != getpid() && seenPIDs.insert($0).inserted
            }
            guard !pids.isEmpty else { throw CaptureError.noProcesses }
            guard try await AudioProcessStartupWaiter.waitUntilRegistered(
                pids: pids,
                timeout: Self.onlineProcessRegistrationTimeout,
            ) else {
                guard Self.processIsRunning(application.id) else { throw CaptureError.noProcesses }
                throw CaptureError.applicationAudioUnavailable
            }
            try Task.checkCancellation()
            guard Self.processIsRunning(application.id) else { throw CaptureError.noProcesses }
            let rawURL = folder.appendingPathComponent("source.raw")
            let session = AudioCaptureSession(
                pids: pids,
                appOutputURL: rawURL,
                micOutputURL: nil,
                appLiveSink: sink,
            )
            try session.start()
            let initialSampleCount: Int64
            do {
                guard let received = try await liveStore.waitForSamples(
                    after: 0,
                    timeout: Self.onlineFirstBufferTimeout,
                ) else {
                    throw CaptureError.applicationAudioUnavailable
                }
                try Task.checkCancellation()
                initialSampleCount = received
            } catch {
                _ = session.stop()
                throw error
            }
            rawOnlineURL = rawURL
            onlineSession = session
            onlineRootPID = application.id
            activeCaptureGeneration = liveGeneration
            onlineFrameWatchdog.reset(
                sampleCount: initialSampleCount,
                now: ProcessInfo.processInfo.systemUptime,
            )

        case .inPerson:
            let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
            MicCaptureDiagnostics.record(
                "authorization=\(authorization.rawValue) bundle=\(Bundle.main.bundleIdentifier ?? "unknown") requested=\(microphone?.id ?? "none")",
            )
            guard await requestMicrophonePermission() else { throw CaptureError.permissionDenied }
            // The permission sheet can outlive the task that initiated it.
            // Never start hardware after that owner has been cancelled.
            try Task.checkCancellation()
            guard let microphone else { throw CaptureError.sourceMissing }
            let connectedMicrophoneIDs = Set(currentMicrophones().map(\.uniqueID))
            guard connectedMicrophoneIDs.contains(microphone.id) else {
                throw CaptureError.microphoneUnavailable
            }
            let capture = MicCaptureHandler(outputURL: sourceURL, debugLogging: true, liveSink: sink)
            try capture.start(deviceUID: microphone.id)
            do {
                try await capture.waitForFirstBuffer()
                try Task.checkCancellation()
            } catch {
                // Do not rely on deinit timing to release the input tap and
                // close the WAV after a timeout/cancellation.
                capture.stop()
                throw error
            }
            microphoneCapture = capture
            activeCaptureGeneration = liveGeneration
        }

        do {
            // Close the final race between a successful first-buffer wait and
            // publishing `isCapturing`. A cancelled start must never leave
            // hardware running behind a UI that believes startup failed.
            try Task.checkCancellation()
        } catch {
            if let onlineSession {
                _ = onlineSession.stop()
                self.onlineSession = nil
            }
            microphoneCapture?.stop()
            microphoneCapture = nil
            activeCaptureGeneration = nil
            onlineRootPID = nil
            throw error
        }

        sourceWAVURL = sourceURL
        self.liveBufferContinuation = liveContinuation
        self.liveBufferTask = liveBufferTask
        keepLiveBufferPump = true
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
        // A manual stop can race the one-second model poll that consumes a
        // terminal channel error. Once teardown owns the session, the parked
        // failure must not leave `isBusy` stuck after finalization.
        terminalCaptureFailure = nil
        activeCaptureGeneration = nil
        onlineRootPID = nil
        onlineHealthCheckInFlight = false
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
        stopLiveBufferPump()
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
                    self.checkOnlineFrameProgress()
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

    private func checkOnlineFrameProgress() {
        guard !onlineHealthCheckInFlight,
              terminalCaptureFailure == nil,
              let generation = activeCaptureGeneration
        else { return }
        if let onlineRootPID, !Self.processIsRunning(onlineRootPID) {
            reportTerminalFailure(CaptureError.applicationAudioStopped.localizedDescription)
            return
        }
        onlineHealthCheckInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sampleCount = await self.liveStore.totalSamples()
            self.onlineHealthCheckInFlight = false
            guard self.isCapturing,
                  self.onlineSession != nil,
                  self.activeCaptureGeneration == generation,
                  self.terminalCaptureFailure == nil
            else { return }
            if self.onlineFrameWatchdog.observe(
                sampleCount: sampleCount,
                now: ProcessInfo.processInfo.systemUptime,
            ) {
                self.reportTerminalFailure(CaptureError.applicationAudioStopped.localizedDescription)
            }
        }
    }

    private func terminateMicrophoneCapture(_ error: MicCaptureError) {
        guard isCapturing else { return }
        microphoneCapture?.stop()
        microphoneCapture = nil
        reportTerminalFailure(error.localizedDescription)
        MicCaptureDiagnostics.record("CaptureController stopped after terminal microphone error")
    }

    /// Park the failure for the model's recovery path while leaving
    /// `isCapturing` true until `abortPreservingAudio()` performs the same
    /// idempotent stop/finalization used by a normal user stop. Clearing the
    /// recording flag here would strand a valid partial WAV outside that path.
    private func reportTerminalFailure(_ message: String) {
        guard terminalCaptureFailure == nil else { return }
        terminalCaptureFailure = message
        levelTimer?.invalidate()
        levelTimer = nil
        levelDBFS = -120
    }

    private func stopLiveBufferPump() {
        liveBufferContinuation?.finish()
        liveBufferContinuation = nil
        liveBufferTask?.cancel()
        liveBufferTask = nil
    }

    /// `kill(pid, 0)` checks process existence without sending a signal.
    /// EPERM still means the process exists; ESRCH means the selected source
    /// quit and continuing would only produce a misleading empty recording.
    nonisolated static func processIsRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func currentMicrophones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified,
        ).devices
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}
