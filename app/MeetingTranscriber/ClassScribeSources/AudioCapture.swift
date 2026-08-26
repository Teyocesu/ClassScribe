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
    private var totalCallbackCount: Int64 = 0
    private(set) var latestLevelDBFS = -120.0

    func append(_ buffer: LiveAudioBuffer, generation expectedGeneration: UUID) {
        guard expectedGeneration == generation else { return }
        // Callback arrival is transport evidence even when the adapter has no
        // samples to append. Signal health must not infer liveness from RMS or
        // from a non-empty buffer alone.
        totalCallbackCount &+= 1
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
        totalCallbackCount = 0
        latestLevelDBFS = -120
        return generation
    }

    func callbackCount() -> Int64 {
        totalCallbackCount
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

    /// Waits for a callback, not for a non-empty buffer. A callback carrying
    /// digital zero or zero frames is a live silent stream and must be allowed
    /// to complete startup.
    func waitForCallbacks(after baseline: Int64, timeout: TimeInterval) async throws -> Int64? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
        while totalCallbackCount <= baseline {
            try Task.checkCancellation()
            guard clock.now < deadline else { return nil }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        return totalCallbackCount
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

    /// Measures trailing silence in short windows instead of treating every
    /// ordinary hesitation as a paragraph boundary. The live transcript can
    /// still confirm a hypothesis after a brief pause while reserving layout
    /// breaks for substantially longer silence.
    func recentSilenceDuration(
        maximumMilliseconds: Int = 8_000,
        analysisWindowMilliseconds: Int = 100,
        thresholdDBFS: Double = CaptureSignalThresholds.macOSApplication.silenceEnergyDBFS,
        endingAt endIndex: Int64? = nil,
    ) -> TimeInterval {
        let end = min(endIndex ?? totalSampleCount, totalSampleCount)
        guard end > baseSampleIndex else { return 0 }
        let retainedCount = Int(end - baseSampleIndex)
        let maximumCount = min(retainedCount, sampleRate * max(0, maximumMilliseconds) / 1_000)
        guard maximumCount > 0 else { return 0 }

        let windowCount = max(1, sampleRate * max(1, analysisWindowMilliseconds) / 1_000)
        let silencePower = pow(10, thresholdDBFS / 10)
        var silentSamples = 0
        let retainedEnd = retainedStartOffset + retainedCount
        guard retainedEnd <= samples.count else { return 0 }
        while silentSamples < maximumCount {
            let count = min(windowCount, maximumCount - silentSamples)
            let upper = retainedEnd - silentSamples
            let lower = upper - count
            let meanSquare = samples[lower ..< upper]
                .reduce(0.0) { $0 + Double($1 * $1) } / Double(count)
            guard meanSquare < silencePower else { break }
            silentSamples += count
        }
        return Double(silentSamples) / Double(sampleRate)
    }

    func hasRecentPause(milliseconds: Int = 550) -> Bool {
        recentSilenceDuration(maximumMilliseconds: milliseconds)
            >= Double(milliseconds) / 1_000
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

    /// Validates the source-rate online master using the session manifest.
    /// Unlike the legacy Float32 helper, this deliberately has no RIFF-size
    /// limit because the master is a raw stream until Fase 2E chooses a long
    /// container.
    static func validateMaster(_ masterURL: URL, manifestURL: URL) throws -> TimeInterval {
        let manifest = try AudioManifestStore.read(from: manifestURL)
        let declaredMaster = try AudioManifestStore.resolve(
            manifest.master.relativePath,
            from: manifestURL,
        )
        guard declaredMaster.standardizedFileURL == masterURL.standardizedFileURL else {
            throw CaptureError.invalidAudioFile
        }
        let values = try masterURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
        )
        let bytesPerFrame = manifest.master.channels * MemoryLayout<Float>.size
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size.isMultiple(of: bytesPerFrame)
        else { throw CaptureError.invalidRawAudio }
        return Double(size / bytesPerFrame) / Double(manifest.master.sampleRate)
    }

    /// Regenerates the ASR WAV from a valid master without deleting or
    /// rewriting the authoritative master descriptor.
    static func deriveASRFromMaster(
        masterURL: URL,
        manifestURL: URL,
        destination: URL,
    ) throws -> TimeInterval {
        _ = try validateMaster(masterURL, manifestURL: manifestURL)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            )
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

        let temporaryRaw = destination.deletingLastPathComponent()
            .appendingPathComponent(".source-asr-\(UUID().uuidString).raw")
        defer { try? fileManager.removeItem(at: temporaryRaw) }
        _ = try MasterAudioDerivative.writeFloat32Raw(
            masterURL: masterURL,
            manifestURL: manifestURL,
            destinationURL: temporaryRaw,
        )
        try wrapFloat32Raw(temporaryRaw, destination: destination, sampleRate: 16000)
        return try validate(destination)
    }

    static func recoverMaster(
        _ masterURL: URL,
        manifestURL: URL,
        destination: URL,
    ) throws -> TimeInterval {
        _ = try validateMaster(masterURL, manifestURL: manifestURL)
        if let duration = try? validate(destination) {
            return duration
        }
        return try deriveASRFromMaster(
            masterURL: masterURL,
            manifestURL: manifestURL,
            destination: destination,
        )
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
    case systemOutputAuthorizationRequired
    case permissionDenied
    case microphoneUnavailable
    case noProcesses
    case applicationIdentityAmbiguous
    case applicationIdentityUnsupported
    case applicationAudioUnavailable
    case applicationAudioStopped
    case captureCallbacksStalled
    case emptyAudio
    case wavHeaderOnly
    case emptyAudioFile
    case invalidAudioFile
    case invalidRawAudio
    case notRecording
    case audioFinalization(String)
    case terminalFailure(CaptureTerminalFailure)

    var errorDescription: String? {
        switch self {
        case .sourceMissing: "Selecciona una fuente de audio."
        case .systemOutputAuthorizationRequired:
            "La captura del audio del sistema requiere una autorización explícita para este intento."
        case .permissionDenied: "El permiso de micrófono fue denegado. Actívalo en Privacidad y seguridad."
        case .microphoneUnavailable: "El micrófono seleccionado ya no está disponible. Conéctalo de nuevo o elige otro."
        case .noProcesses: "La aplicación elegida ya no está en ejecución."
        case .applicationIdentityAmbiguous:
            "La aplicación seleccionada tiene más de una coincidencia válida. Cierra la copia adicional o vuelve a elegir la fuente."
        case .applicationIdentityUnsupported:
            "La aplicación seleccionada no tiene una identidad estable verificable. Vuelve a actualizar y elegir la fuente."
        case .applicationAudioUnavailable:
            "La aplicación no entregó audio. Comprueba que siga abierta y revisa el permiso de Audio del sistema en Privacidad y seguridad."
        case .applicationAudioStopped:
            "La aplicación dejó de entregar audio. Se detuvo la captura para conservar lo grabado; comprueba que la app siga abierta y el permiso de Audio del sistema."
        case .captureCallbacksStalled:
            "La fuente de audio dejó de entregar callbacks. El audio recibido se conserva para recuperación."
        case .emptyAudio: "El archivo de audio está vacío. El original se conservó para diagnóstico."
        case .wavHeaderOnly: "El micrófono no entregó audio. El archivo se conservó para diagnóstico."
        case .emptyAudioFile: "El archivo de audio no llegó a crearse con datos. Se conservó la sesión para diagnóstico."
        case .invalidAudioFile: "El audio no es un archivo regular propio de la sesión. No se siguió ni reemplazó ningún enlace."
        case .invalidRawAudio: "El audio crudo conservado está vacío, truncado o no es un archivo regular."
        case .notRecording: "No hay una clase en grabación."
        case let .audioFinalization(detail): "No se pudo finalizar el audio: \(detail)"
        case let .terminalFailure(failure): "No se pudo finalizar el audio: \(failure.message)"
        }
    }
}

struct CaptureStopResult: Sendable, Equatable {
    var url: URL
    var duration: TimeInterval
}

/// MainActor-owned startup slot for resources that must be stopped if the
/// final startup cancellation/generation gate rejects publication. Clearing
/// the slot before invoking `cleanup` makes release idempotent and prevents a
/// second cleanup path from stopping a different attempt's resource.
@MainActor
final class CaptureStartupResourceOwner<Resource> {
    private(set) var ownedResource: Resource?
    private let cleanup: (Resource) -> Void

    init(cleanup: @escaping (Resource) -> Void) {
        self.cleanup = cleanup
    }

    func acquire(_ resource: Resource) {
        precondition(ownedResource == nil, "startup resource already owned")
        ownedResource = resource
    }

    func release() {
        guard let resource = ownedResource else { return }
        ownedResource = nil
        cleanup(resource)
    }
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

typealias CaptureApplicationReconcile = @Sendable (
    _ selectedIdentity: ApplicationIdentity,
    _ previousPID: pid_t,
    _ attempt: SessionAttemptID,
    _ timeout: TimeInterval
) async throws -> MacApplicationStartupPlan

@MainActor
@Observable
final class CaptureController {
    // These aliases preserve the existing focused tests/API while keeping all
    // signal-health budgets in CaptureSignalThresholds.
    nonisolated static let onlineFirstBufferTimeout =
        CaptureSignalThresholds.macOSApplication.initialCallbackBudget
    nonisolated static let onlineStallTimeout =
        CaptureSignalThresholds.macOSApplication.stallBudget
    nonisolated static let microphoneFirstBufferTimeout =
        CaptureSignalThresholds.macOSMicrophone.initialCallbackBudget
    nonisolated static let onlineProcessRegistrationTimeout: TimeInterval = 3

    private(set) var applications: [RunningApplication] = []
    private(set) var microphones: [MicrophoneOption] = []
    private(set) var levelDBFS = -120.0
    private(set) var signalHealth: CaptureSignalHealthSnapshot?
    private(set) var isCapturing = false
    private(set) var isStarting = false

    let liveStore = LiveAudioBufferStore()
    private let nativeExecutor: CaptureNativeExecutor
    private let systemOutputAuthorizationAuthority: SystemOutputCaptureAuthorizationAuthority
    private let rebindDriver: any CaptureApplicationRebindDriver
    private let applicationReconcileOverride: CaptureApplicationReconcile?
    private let attemptGate = CaptureAttemptGate()
    private let sourceGenerationGate = CaptureSourceGenerationGate()
    private let rebindCoordinator = CaptureRebindCoordinator()
    private let microphoneCaptureOwner = CaptureStartupResourceOwner<MicCaptureHandler> { $0.stop() }
    private var microphoneCapture: MicCaptureHandler? {
        microphoneCaptureOwner.ownedResource
    }
    private var activeAttempt: SessionAttemptID?
    private var startCancellation: CaptureStartCancellation?
    private var nativeStartWork: CaptureNativeWork<Void>?
    private var nativeStopWork: CaptureNativeWork<CaptureNativeStopResult>?
    private var nativeStopAttempt: SessionAttemptID?
    private var levelTimer: Timer?
    private var rawOnlineURL: URL?
    private var audioManifestURL: URL?
    private var sourceWAVURL: URL?
    private var terminalCaptureFailure: CaptureTerminalFailure?
    private var completedStop: Result<CaptureStopResult, CaptureError>?
    private var stopTask: Task<Result<CaptureStopResult, CaptureError>, Never>?
    private var liveBufferContinuation: AsyncStream<LiveAudioBuffer>.Continuation?
    private var liveBufferTask: Task<Void, Never>?
    private var activeCaptureGeneration: UUID?
    private var activeCaptureScope: CaptureScope?
    private var activeSourceGeneration: CaptureSourceGeneration?
    private var onlineRootPID: pid_t?
    private var onlineSelectedIdentity: ApplicationIdentity?
    private var onlineTargetPIDs: Set<pid_t> = []
    private var onlineProbeTask: Task<Void, Never>?
    private var onlineRebindTask: Task<Void, Never>?
    private var onlineRebindCancellation: CaptureStartCancellation?
    private var onlineProbeToken: UUID?
    private var onlineRebindToken: UUID?
    private var onlineSourceAvailable = false
    private var lastOnlineProbeUptime: TimeInterval = 0
    private var onlineRecoveryDeadline: TimeInterval?
    private var onlineRebindFailureCount = 0
    private var signalHealthTracker: CaptureSignalHealthTracker?

    init(
        rebindDriver: (any CaptureApplicationRebindDriver)? = nil,
        applicationReconcile: CaptureApplicationReconcile? = nil,
    ) {
        let authorizationAuthority = SystemOutputCaptureAuthorizationAuthority()
        let executor = CaptureNativeExecutor(
            systemOutputAuthorizationAuthority: authorizationAuthority,
        )
        systemOutputAuthorizationAuthority = authorizationAuthority
        nativeExecutor = executor
        self.rebindDriver = rebindDriver ?? CaptureNativeRebindDriver(executor: executor)
        applicationReconcileOverride = applicationReconcile
    }

    var isBusy: Bool {
        isCapturing
            || isStarting
            || startCancellation != nil
            || nativeStartWork != nil
            || nativeStopWork != nil
            || terminalCaptureFailure != nil
    }

    func refreshSources() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var seenIdentityIDs = Set<String>()
        applications = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  let name = app.localizedName,
                  !name.isEmpty else { return nil }
            return RunningApplication(
                identity: ApplicationIdentity(
                    bundleIdentifier: app.bundleIdentifier,
                    bundleURL: app.bundleURL,
                    executableURL: app.executableURL,
                ),
                name: name,
                processID: app.processIdentifier,
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        .filter { seenIdentityIDs.insert($0.logicalIdentityID).inserted }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified,
        )
        microphones = discovery.devices.map {
            MicrophoneOption(id: $0.uniqueID, name: $0.localizedName)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // Focused model tests can inject the same source shapes that the product
    // discovery path publishes without replacing the capture controller.
    @MainActor
    func setSourcesForTesting(
        applications: [RunningApplication],
        microphones: [MicrophoneOption],
    ) {
        self.applications = applications
        self.microphones = microphones
    }

    func start(
        attempt: SessionAttemptID,
        mode: CaptureMode,
        captureScope: CaptureScope? = nil,
        application: RunningApplication?,
        microphone: MicrophoneOption?,
        folder: URL,
        systemOutputAuthorization: SystemOutputCaptureAuthorization? = nil,
    ) async throws -> URL {
        guard !isBusy else { throw CaptureError.notRecording }
        let resolvedScope = captureScope ?? mode.captureScope
        do {
            try Task.checkCancellation()
        } catch {
            if resolvedScope == .systemOutput {
                systemOutputAuthorizationAuthority.invalidate(attempt)
            }
            throw error
        }
        guard resolvedScope != .systemOutput
            || systemOutputAuthorizationAuthority.accepts(systemOutputAuthorization, for: attempt)
        else {
            throw CaptureError.systemOutputAuthorizationRequired
        }
        if let previousAttempt = activeAttempt {
            attemptGate.invalidate(previousAttempt)
            sourceGenerationGate.invalidate(previousAttempt)
            rebindCoordinator.cancel(previousAttempt)
            systemOutputAuthorizationAuthority.invalidate(previousAttempt)
        }
        onlineRebindCancellation?.cancel()
        onlineRebindTask?.cancel()
        onlineRebindCancellation = nil
        onlineRebindTask = nil
        onlineRebindToken = nil
        isStarting = true
        activeAttempt = attempt
        attemptGate.begin(attempt)
        let startCancellation = CaptureStartCancellation()
        self.startCancellation = startCancellation
        let signalTracker = CaptureSignalHealthTracker(
            attempt: attempt,
            thresholds: resolvedScope == .microphone
                ? .macOSMicrophone
                : .macOSApplication,
        )
        signalHealthTracker = signalTracker
        signalHealth = signalTracker.snapshot(for: attempt)
        defer {
            if self.startCancellation === startCancellation {
                self.startCancellation = nil
                self.isStarting = false
            }
        }
        terminalCaptureFailure = nil
        completedStop = nil
        stopTask = nil
        sourceWAVURL = nil
        rawOnlineURL = nil
        audioManifestURL = nil
        stopLiveBufferPump()
        let liveGeneration = await liveStore.reset()
        try Task.checkCancellation()
        guard activeAttempt == attempt else { throw CancellationError() }
        activeCaptureGeneration = nil
        activeCaptureScope = nil
        activeSourceGeneration = nil
        onlineRootPID = nil
        onlineSelectedIdentity = nil
        onlineTargetPIDs = []
        onlineSourceAvailable = false
        onlineProbeTask?.cancel()
        onlineProbeTask = nil
        onlineRebindCancellation?.cancel()
        onlineRebindCancellation = nil
        onlineRebindTask?.cancel()
        onlineRebindTask = nil
        lastOnlineProbeUptime = 0
        onlineRecoveryDeadline = nil
        onlineRebindFailureCount = 0
        let sourceURL = folder.appendingPathComponent("source.wav")
        let masterURL = folder.appendingPathComponent("master.raw")
        let manifestURL = folder.appendingPathComponent("audio-manifest.json")
        sourceWAVURL = sourceURL
        audioManifestURL = resolvedScope == .microphone ? nil : manifestURL
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
        let callbackAttemptGate = attemptGate
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
            guard callbackAttemptGate.accepts(attempt) else { return }
            _ = signalTracker.recordCallback(
                for: attempt,
                measurement: CaptureSignalMeasurement(
                    samples: buffer.samples,
                    channelCount: buffer.channelCount,
                ),
            )
            _ = liveContinuation.yield(buffer)
        }

        do {
            switch resolvedScope {
            case .application:
                guard let application else { throw CaptureError.sourceMissing }
                let reconciliationStarted = DispatchTime.now().uptimeNanoseconds
                let selectedIdentity = application.identity
                let previousPID = application.processID
                let callbackAttemptGate = attemptGate
                let reconciliationTask = Task.detached(priority: .userInitiated) {
                    try await MacApplicationStartupReconciler.reconcile(
                        selectedIdentity: selectedIdentity,
                        previousPID: previousPID,
                        attempt: attempt,
                        timeout: CaptureController.onlineProcessRegistrationTimeout,
                        candidates: {
                            var observed = MacApplicationIdentityResolver.liveCandidates(excluding: getpid())
                            // Command-line players and other weakly identified
                            // sources may not appear in NSWorkspace. Keeping the
                            // exact live PID is safe for this incarnation only;
                            // the resolver never uses it to replace a dead PID.
                            if selectedIdentity.strength == .weak,
                               Self.processIsRunning(previousPID),
                               !observed.contains(where: { $0.pid == previousPID }) {
                                observed.append(MacApplicationProcessSnapshot(
                                    pid: previousPID,
                                    identity: selectedIdentity,
                                    displayName: "selected-source",
                                ))
                            }
                            return observed
                        },
                        topology: { candidate in
                            if let bundleURL = candidate.identity.bundleURL {
                                return ProcessTreeEnumerator.pidsRooted(in: bundleURL)
                            }
                            if let executableURL = candidate.identity.executableURL {
                                return ProcessTreeEnumerator.pidsRooted(inExecutableURL: executableURL)
                            }
                            return []
                        },
                        translatedTargets: { pids in
                            AppAudioCapture.validatedAudioProcessPIDs(in: pids)
                        },
                        isCurrentAttempt: { callbackAttemptGate.accepts($0) },
                    )
                }
                let startupPlan = try await MacApplicationStartupTask.value(of: reconciliationTask)
                try Task.checkCancellation()
                guard activeAttempt == attempt else { throw CancellationError() }
                switch startupPlan.result.state {
                case .missing:
                    throw CaptureError.noProcesses
                case .ambiguous:
                    throw CaptureError.applicationIdentityAmbiguous
                case .unsupportedWeakIdentity:
                    throw CaptureError.applicationIdentityUnsupported
                case .resolved:
                    break
                }
                guard let rootPID = startupPlan.rootPID,
                      !startupPlan.topologyPIDs.isEmpty,
                      !startupPlan.translatedTargetPIDs.isEmpty else {
                    throw CaptureError.applicationAudioUnavailable
                }
                try Task.checkCancellation()
                guard activeAttempt == attempt else { throw CancellationError() }
                let sourceGeneration = sourceGenerationGate.begin(attempt)
                let callbackSourceGate = sourceGenerationGate
                let sourceCallbackGate: @Sendable () -> Bool = {
                    callbackSourceGate.accepts(attempt, generation: sourceGeneration)
                }
                let applicationSink: LiveAudioSink = { buffer in
                    guard callbackAttemptGate.accepts(attempt),
                          callbackSourceGate.accepts(attempt, generation: sourceGeneration)
                    else { return }
                    _ = signalTracker.recordCallback(
                        for: attempt,
                        measurement: CaptureSignalMeasurement(
                            samples: buffer.samples,
                            channelCount: buffer.channelCount,
                        ),
                    )
                    _ = liveContinuation.yield(buffer)
                }
                let elapsed = Double(
                    DispatchTime.now().uptimeNanoseconds - reconciliationStarted,
                ) / 1_000_000_000
                let nativeStart = nativeExecutor.beginApplicationStart(
                    attempt: attempt,
                    sourceGeneration: sourceGeneration,
                    rootPID: rootPID,
                    pids: startupPlan.topologyPIDs,
                    outputURL: masterURL,
                    manifestURL: manifestURL,
                    // The resolver and the native registration retry share
                    // one monotonic startup budget. The native executor still
                    // performs its own immediate revalidation just before
                    // CATapDescription is constructed.
                    registrationTimeout: max(0, Self.onlineProcessRegistrationTimeout - elapsed),
                    liveSink: applicationSink,
                    sourceCallbackGate: sourceCallbackGate,
                )
                nativeStartWork = nativeStart
                observeNativeCompletion(nativeStart, kind: .start)
                try await nativeStart.value()
                try Task.checkCancellation()
                guard activeAttempt == attempt else { throw CancellationError() }

                _ = try await waitForFirstCallbacks(
                    after: 0,
                    timeout: Self.onlineFirstBufferTimeout,
                    cancellation: startCancellation,
                )
                guard activeAttempt == attempt else { throw CancellationError() }
                rawOnlineURL = masterURL
                onlineRootPID = rootPID
                onlineSelectedIdentity = selectedIdentity
                onlineTargetPIDs = Set(startupPlan.translatedTargetPIDs)
                activeSourceGeneration = sourceGeneration
                activeCaptureScope = .application
                onlineSourceAvailable = true
                onlineRecoveryDeadline = nil
                activeCaptureGeneration = liveGeneration

            case .systemOutput:
                let sourceGeneration = sourceGenerationGate.begin(attempt)
                let callbackSourceGate = sourceGenerationGate
                let sourceCallbackGate: @Sendable () -> Bool = {
                    callbackSourceGate.accepts(attempt, generation: sourceGeneration)
                }
                let systemOutputSink: LiveAudioSink = { buffer in
                    guard callbackAttemptGate.accepts(attempt),
                          callbackSourceGate.accepts(attempt, generation: sourceGeneration)
                    else { return }
                    _ = signalTracker.recordCallback(
                        for: attempt,
                        measurement: CaptureSignalMeasurement(
                            samples: buffer.samples,
                            channelCount: buffer.channelCount,
                        ),
                    )
                    _ = liveContinuation.yield(buffer)
                }
                let nativeStart = nativeExecutor.beginSystemOutputStart(
                    attempt: attempt,
                    sourceGeneration: sourceGeneration,
                    authorization: systemOutputAuthorization,
                    outputURL: masterURL,
                    manifestURL: manifestURL,
                    liveSink: systemOutputSink,
                    sourceCallbackGate: sourceCallbackGate,
                )
                nativeStartWork = nativeStart
                observeNativeCompletion(nativeStart, kind: .start)
                try await nativeStart.value()
                try Task.checkCancellation()
                guard activeAttempt == attempt else { throw CancellationError() }
                _ = try await waitForFirstCallbacks(
                    after: 0,
                    timeout: Self.onlineFirstBufferTimeout,
                    cancellation: startCancellation,
                )
                guard activeAttempt == attempt else { throw CancellationError() }
                rawOnlineURL = masterURL
                activeSourceGeneration = sourceGeneration
                activeCaptureScope = .systemOutput
                onlineSourceAvailable = true
                activeCaptureGeneration = liveGeneration

            case .microphone:
                let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
                MicCaptureDiagnostics.record(
                    "authorization=\(authorization.rawValue) bundle=\(Bundle.main.bundleIdentifier ?? "unknown") requested=\(microphone?.id ?? "none")",
                )
                guard await requestMicrophonePermission() else { throw CaptureError.permissionDenied }
                // The permission sheet can outlive the task that initiated it.
                // Never start hardware after that owner has been cancelled.
                try Task.checkCancellation()
                guard activeAttempt == attempt else { throw CancellationError() }
                guard let microphone else { throw CaptureError.sourceMissing }
                let connectedMicrophoneIDs = Set(currentMicrophones().map(\.uniqueID))
                guard connectedMicrophoneIDs.contains(microphone.id) else {
                    throw CaptureError.microphoneUnavailable
                }
                let capture = MicCaptureHandler(outputURL: sourceURL, debugLogging: true, liveSink: sink)
                try capture.start(deviceUID: microphone.id)
                do {
                    // Signal health observes every callback, including an
                    // empty callback, but publication still requires the
                    // legacy durability gate: real frames written to the WAV.
                    // Keep the attempt-owned cancellation wake while using
                    // the legacy durability gate. The gate only succeeds
                    // after real frames have reached the WAV writer.
                    _ = try await CaptureFirstSampleRace.wait(cancellation: startCancellation) {
                        try await capture.waitForFirstBuffer(
                            timeout: Self.microphoneFirstBufferTimeout,
                        )
                        return 1
                    }
                } catch {
                    // This legacy mic path remains MainActor-owned while its
                    // physical gate is TCC-blocked. Preserve terminalError
                    // and first-buffer diagnostics from waitForFirstBuffer().
                    capture.stop()
                    throw error
                }
                microphoneCaptureOwner.acquire(capture)
                activeCaptureScope = .microphone
                activeCaptureGeneration = liveGeneration
            }

            // Close the final race between a successful first-buffer wait and
            // publishing `isCapturing`. A stale start never publishes recording.
            try Task.checkCancellation()
            guard activeAttempt == attempt else { throw CancellationError() }
            sourceWAVURL = sourceURL
            self.liveBufferContinuation = liveContinuation
            self.liveBufferTask = liveBufferTask
            keepLiveBufferPump = true
            signalHealth = signalTracker.snapshot(for: attempt)
            isCapturing = true
            startLevelTimer()
            return sourceURL
        } catch {
            // A legacy mic may have been published immediately before the
            // final cancellation/generation gate failed. Stop it on MainActor
            // before awaiting any other teardown, and clear ownership first.
            microphoneCaptureOwner.release()
            startCancellation.cancel()
            let lastHealth = signalTracker.snapshot(for: attempt)
            signalTracker.invalidate(attempt)
            signalHealth = lastHealth
            sourceGenerationGate.invalidate(attempt)
            rebindCoordinator.cancel(attempt)
            systemOutputAuthorizationAuthority.invalidate(attempt)
            onlineProbeTask?.cancel()
            onlineProbeTask = nil
            onlineRebindCancellation?.cancel()
            onlineRebindCancellation = nil
            onlineRebindTask?.cancel()
            onlineRebindTask = nil
            onlineRebindToken = nil
            if let currentTracker = signalHealthTracker, currentTracker === signalTracker {
                signalHealthTracker = nil
            }
            if activeAttempt == attempt {
                activeAttempt = nil
                attemptGate.invalidate(attempt)
                activeCaptureGeneration = nil
                activeCaptureScope = nil
                activeSourceGeneration = nil
                onlineRootPID = nil
                onlineSelectedIdentity = nil
                onlineTargetPIDs = []
                onlineSourceAvailable = false
            }
            let nativeStop = requestNativeStop(for: attempt)
            await nativeStop.waitForCompletion()
            throw error
        }
    }

    /// Invalidates startup synchronously on MainActor. Native work is only
    /// marked stale here; the dedicated executor owns the eventual stop and
    /// resource destruction when a synchronous native call returns.
    func cancelStart(for attempt: SessionAttemptID) {
        guard isStarting, activeAttempt == attempt else { return }
        activeAttempt = nil
        attemptGate.invalidate(attempt)
        sourceGenerationGate.invalidate(attempt)
        rebindCoordinator.cancel(attempt)
        systemOutputAuthorizationAuthority.invalidate(attempt)
        startCancellation?.cancel()
        onlineRebindCancellation?.cancel()
        onlineRebindCancellation = nil
        nativeStartWork?.cancel()
        signalHealthTracker?.invalidate(attempt)
        signalHealth = nil
        signalHealthTracker = nil
        activeCaptureGeneration = nil
        activeCaptureScope = nil
        activeSourceGeneration = nil
        onlineRootPID = nil
        onlineSelectedIdentity = nil
        onlineTargetPIDs = []
        onlineSourceAvailable = false
        onlineProbeTask?.cancel()
        onlineProbeTask = nil
        onlineRebindTask?.cancel()
        onlineRebindTask = nil
        onlineRebindToken = nil
        levelTimer?.invalidate()
        levelTimer = nil
        stopLiveBufferPump()
        _ = requestNativeStop(for: attempt)
        isStarting = false
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
        let stoppedScope = activeCaptureScope
        let stoppedAttempt = activeAttempt
        if let stoppedAttempt {
            if let tracker = signalHealthTracker {
                signalHealth = tracker.snapshot(for: stoppedAttempt)
                tracker.invalidate(stoppedAttempt)
            }
            activeAttempt = nil
            attemptGate.invalidate(stoppedAttempt)
            sourceGenerationGate.invalidate(stoppedAttempt)
            rebindCoordinator.cancel(stoppedAttempt)
            systemOutputAuthorizationAuthority.invalidate(stoppedAttempt)
        }
        onlineRebindCancellation?.cancel()
        onlineRebindCancellation = nil
        signalHealthTracker = nil
        activeCaptureGeneration = nil
        activeCaptureScope = nil
        activeSourceGeneration = nil
        onlineRootPID = nil
        onlineSelectedIdentity = nil
        onlineTargetPIDs = []
        onlineSourceAvailable = false
        onlineProbeTask?.cancel()
        onlineProbeTask = nil
        onlineRebindTask?.cancel()
        onlineRebindTask = nil
        onlineRebindToken = nil
        levelTimer?.invalidate()
        levelTimer = nil
        let rawToWrap = rawOnlineURL
        let manifestToFinalize = audioManifestURL
        stopLiveBufferPump()
        levelDBFS = -120

        // The control-plane state above is committed before awaiting native
        // teardown. The actual stop remains owned by the serial native queue,
        // so a slow AudioDeviceStop/engine.stop cannot freeze MainActor.
        var nativeStopResult: CaptureNativeStopResult?
        if let stoppedAttempt {
            let nativeStop = requestNativeStop(for: stoppedAttempt)
            await nativeStop.waitForCompletion()
            nativeStopResult = try? await nativeStop.value()
        }
        microphoneCaptureOwner.release()

        let finalization = Task.detached(priority: .userInitiated) { () -> Result<CaptureStopResult, CaptureError> in
            do {
                if let rawToWrap, let manifestURL = manifestToFinalize {
                    _ = try WavFile.deriveASRFromMaster(
                        masterURL: rawToWrap,
                        manifestURL: manifestURL,
                        destination: sourceWAVURL,
                    )
                }
                let duration = try WavFile.validate(sourceWAVURL)
                return .success(CaptureStopResult(url: sourceWAVURL, duration: duration))
            } catch let error as CaptureError {
                return .failure(error)
            } catch {
                return .failure(CaptureError.audioFinalization(error.localizedDescription))
            }
        }
        stopTask = finalization
        let finalizedResult = await finalization.value
        let result: Result<CaptureStopResult, CaptureError>
        if let terminalFailure = nativeStopResult?.terminalFailure {
            let category: CaptureTerminalFailureCategory = switch terminalFailure.category {
            case .source: .source
            case .durableMaster: .durableMaster
            }
            result = .failure(.terminalFailure(CaptureTerminalFailure(
                message: terminalFailure.message,
                category: category,
                recoverySuggestion: CaptureRecoveryPolicy.suggestion(
                    for: category,
                    scope: stoppedScope,
                ),
            )))
        } else {
            result = finalizedResult
        }
        stopTask = nil
        completedStop = result
        return try result.get()
    }

    private enum NativeWorkKind {
        case start
        case stop
    }

    private func observeNativeCompletion<Value: Sendable>(
        _ work: CaptureNativeWork<Value>,
        kind: NativeWorkKind,
    ) {
        // This task is a control-plane watcher only. It never calls native
        // APIs; those remain inside CaptureNativeExecutor's serial queue.
        Task { @MainActor [weak self] in
            await work.waitForCompletion()
            guard let self else { return }
            switch kind {
            case .start:
                if let start = self.nativeStartWork,
                   ObjectIdentifier(start) == ObjectIdentifier(work) {
                    self.nativeStartWork = nil
                }
            case .stop:
                if let stop = self.nativeStopWork,
                   ObjectIdentifier(stop) == ObjectIdentifier(work) {
                    self.nativeStopWork = nil
                    self.nativeStopAttempt = nil
                }
            }
        }
    }

    private func requestNativeStop(for attempt: SessionAttemptID) -> CaptureNativeWork<CaptureNativeStopResult> {
        if let nativeStopWork,
           nativeStopAttempt == attempt {
            return nativeStopWork
        }
        let work = nativeExecutor.beginStop(attempt: attempt)
        nativeStopWork = work
        nativeStopAttempt = attempt
        observeNativeCompletion(work, kind: .stop)
        return work
    }

    private func waitForFirstCallbacks(
        after baseline: Int64,
        timeout: TimeInterval,
        cancellation: CaptureStartCancellation,
    ) async throws -> Int64 {
        let liveStore = self.liveStore
        return try await CaptureFirstSampleRace.wait(cancellation: cancellation) {
            try await liveStore.waitForCallbacks(after: baseline, timeout: timeout)
        }
    }

    func abortPreservingAudio() async {
        guard isCapturing else { return }
        _ = try? await stop()
    }

    func takeTerminalFailure() -> CaptureTerminalFailure? {
        defer { terminalCaptureFailure = nil }
        return terminalCaptureFailure
    }

    /// Issues a capability only after the product consent modal has received
    /// an affirmative action. The capability remains bound to this controller
    /// and exactly one attempt.
    func issueSystemOutputAuthorizationAfterExplicitUserConsent(
        for attempt: SessionAttemptID,
    ) -> SystemOutputCaptureAuthorization {
        systemOutputAuthorizationAuthority.issueAfterExplicitUserConsent(for: attempt)
    }

    func invalidateSystemOutputAuthorization(for attempt: SessionAttemptID) {
        systemOutputAuthorizationAuthority.invalidate(attempt)
    }

    // Product lifecycle seam used by focused tests. It prepares the same
    // attempt/source-generation/live-buffer ownership that a successful online
    // start publishes, while leaving native CATap work injectable.
    @MainActor
    func prepareOnlineRebindLifecycleForTest(
        attempt: SessionAttemptID,
        selectedIdentity: ApplicationIdentity,
        rootPID: pid_t,
        targetPIDs: [pid_t],
        sourceAvailable: Bool = true,
        includeLiveContinuation: Bool = true,
    ) async {
        stopLiveBufferPump()
        let liveGeneration = await liveStore.reset()
        activeAttempt = attempt
        attemptGate.begin(attempt)
        let sourceGeneration = sourceGenerationGate.begin(attempt)
        rebindCoordinator.reset(attempt)
        activeCaptureGeneration = liveGeneration
        activeCaptureScope = .application
        activeSourceGeneration = sourceGeneration
        onlineRootPID = rootPID
        onlineSelectedIdentity = selectedIdentity
        onlineTargetPIDs = Set(targetPIDs)
        onlineSourceAvailable = sourceAvailable
        onlineRecoveryDeadline = nil
        onlineRebindFailureCount = 0
        onlineRebindToken = nil
        onlineRebindCancellation = nil
        onlineRebindTask = nil
        terminalCaptureFailure = nil
        isStarting = false
        isCapturing = true
        signalHealthTracker = CaptureSignalHealthTracker(
            attempt: attempt,
            thresholds: .macOSApplication,
        )
        signalHealth = signalHealthTracker?.snapshot(for: attempt)

        guard includeLiveContinuation else { return }
        let (liveStream, liveContinuation) = AsyncStream<LiveAudioBuffer>.makeStream()
        liveBufferContinuation = liveContinuation
        liveBufferTask = Task.detached(priority: .userInitiated) { [liveStore] in
            for await buffer in liveStream {
                guard !Task.isCancelled else { break }
                await liveStore.append(buffer, generation: liveGeneration)
            }
        }
    }

    @MainActor
    @discardableResult
    func beginApplicationRebindForTest(
        plan: MacApplicationStartupPlan,
        attempt: SessionAttemptID,
        signalState: CaptureSignalState = .silent,
    ) -> Bool {
        beginApplicationRebind(plan: plan, attempt: attempt, signalState: signalState)
        return onlineRebindTask != nil
    }

    @MainActor
    func waitForApplicationRebindForTest() async {
        let task = onlineRebindTask
        await task?.value
    }

    @MainActor
    func cancelApplicationRebindForTest(for attempt: SessionAttemptID) {
        guard activeAttempt == attempt else { return }
        sourceGenerationGate.invalidate(attempt)
        rebindCoordinator.cancel(attempt)
        onlineRebindCancellation?.cancel()
        onlineRebindTask?.cancel()
        onlineRebindToken = nil
    }

    @MainActor
    func cleanupOnlineRebindLifecycleForTest(for attempt: SessionAttemptID) {
        cancelApplicationRebindForTest(for: attempt)
        isCapturing = false
        activeAttempt = nil
        attemptGate.invalidate(attempt)
        signalHealthTracker?.invalidate(attempt)
        signalHealthTracker = nil
        signalHealth = nil
        activeCaptureGeneration = nil
        activeCaptureScope = nil
        activeSourceGeneration = nil
        onlineRootPID = nil
        onlineSelectedIdentity = nil
        onlineTargetPIDs = []
        onlineSourceAvailable = false
        stopLiveBufferPump()
    }

    var onlineSourceAvailableForTest: Bool { onlineSourceAvailable }

    var onlineRecoveryPendingForTest: Bool { onlineRecoveryDeadline != nil }

    var onlineRebindFirstCallbackWaitActiveForTest: Bool {
        onlineRebindCancellation?.hasActiveWaiter == true
    }

    var activeSourceGenerationNumberForTest: UInt64? {
        activeSourceGeneration?.number
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCapturing,
                      let attempt = self.activeAttempt
                else { return }
                if let tracker = self.signalHealthTracker,
                   let signal = tracker.snapshot(for: attempt) {
                    self.signalHealth = signal
                }
                if self.activeCaptureScope == .systemOutput, self.onlineSourceAvailable {
                    let snapshot = await self.nativeExecutor.levelSnapshot(for: attempt)
                    guard self.isCapturing,
                          self.activeAttempt == attempt,
                          self.attemptGate.accepts(attempt)
                    else { return }
                    if let terminalFailure = snapshot.terminalFailure {
                        self.reportNativeTerminalFailure(terminalFailure)
                        return
                    }
                    self.levelDBFS = snapshot.levelDBFS
                } else if self.onlineRootPID != nil, self.onlineSourceAvailable {
                    let snapshot = await self.nativeExecutor.levelSnapshot(for: attempt)
                    guard self.isCapturing,
                          self.activeAttempt == attempt,
                          self.attemptGate.accepts(attempt)
                    else { return }
                    if let terminalFailure = snapshot.terminalFailure {
                        self.reportNativeTerminalFailure(terminalFailure)
                        return
                    }
                    self.levelDBFS = snapshot.levelDBFS
                    self.checkOnlineFrameProgress(for: attempt)
                    self.scheduleApplicationProbe(for: attempt)
                } else if self.onlineSelectedIdentity != nil {
                    // The old native source may already have been destroyed
                    // while a bounded post-stop resolution/recovery is in
                    // flight. Do not expose a source-less session as healthy
                    // and do not query a native level snapshot that has no tap.
                    self.scheduleApplicationProbe(
                        for: attempt,
                        forcedSignalState: .noCallbacks,
                    )
                } else if let microphoneCapture = self.microphoneCapture {
                    if let error = microphoneCapture.terminalError {
                        self.terminateMicrophoneCapture(error.localizedDescription)
                        return
                    }
                    self.levelDBFS = microphoneCapture.currentLevelDBFS
                }
            }
        }
    }

    private func checkOnlineFrameProgress(for attempt: SessionAttemptID) {
        guard terminalCaptureFailure == nil,
              activeCaptureGeneration != nil,
              activeAttempt == attempt
        else { return }
        if let onlineRootPID, !Self.processIsRunning(onlineRootPID) {
            scheduleApplicationProbe(for: attempt, forcedSignalState: .noCallbacks)
        }
    }

    private func scheduleApplicationProbe(
        for attempt: SessionAttemptID,
        forcedSignalState: CaptureSignalState? = nil,
    ) {
        guard isCapturing,
              activeAttempt == attempt,
              let selectedIdentity = onlineSelectedIdentity,
              let previousPID = onlineRootPID,
              onlineRebindTask == nil,
              onlineProbeTask == nil
        else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastOnlineProbeUptime < 1.0 {
            return
        }
        lastOnlineProbeUptime = now
        let probeToken = UUID()
        onlineProbeToken = probeToken
        let currentRootPID = previousPID
        let currentTargets = Array(onlineTargetPIDs)
        let signalState = forcedSignalState
            ?? signalHealthTracker?.snapshot(for: attempt)?.state
            ?? .silent
        if signalState == .noCallbacks, onlineRecoveryDeadline == nil {
            onlineRecoveryDeadline = now + 6
        }

        let probeTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.onlineProbeToken == probeToken {
                    self.onlineProbeTask = nil
                    self.onlineProbeToken = nil
                }
            }
            guard let self else { return }
            do {
                let plan = try await self.reconcileApplication(
                    selectedIdentity: selectedIdentity,
                    previousPID: previousPID,
                    attempt: attempt,
                    timeout: 1.0,
                )
                guard self.isCapturing,
                      self.activeAttempt == attempt,
                      self.attemptGate.accepts(attempt),
                      self.onlineProbeToken == probeToken
                else { return }
                let decision = MacApplicationRebindPolicy.decide(
                    selectedIdentity: selectedIdentity,
                    currentRootPID: currentRootPID,
                    currentTargetPIDs: currentTargets,
                    resolution: plan.result,
                    signalState: signalState,
                )
                switch decision {
                case .rebind:
                    self.beginApplicationRebind(
                        plan: plan,
                        attempt: attempt,
                        signalState: signalState,
                    )
                case .preserveCurrent, .noChange, .unsupportedWeakIdentity:
                    if !self.onlineSourceAvailable,
                       selectedIdentity.strength == .strong {
                        // After old-source teardown, even a same-topology
                        // observation is a recovery candidate: the session is
                        // source-less and must build a fresh tap.
                        self.beginApplicationRebind(
                            plan: plan,
                            attempt: attempt,
                            signalState: signalState,
                        )
                    } else if signalState == .noCallbacks,
                              let deadline = self.onlineRecoveryDeadline,
                              ProcessInfo.processInfo.systemUptime >= deadline {
                    self.reportTerminalFailure(
                        CaptureError.captureCallbacksStalled.localizedDescription,
                        recoverySuggestion: .systemOutput,
                    )
                    }
                }
            } catch {
                guard self.isCapturing,
                      self.activeAttempt == attempt,
                      self.onlineProbeToken == probeToken
                else { return }
                if signalState == .noCallbacks,
                   let deadline = self.onlineRecoveryDeadline,
                   ProcessInfo.processInfo.systemUptime >= deadline {
                    self.reportTerminalFailure(
                        CaptureError.applicationAudioStopped.localizedDescription,
                        recoverySuggestion: .systemOutput,
                    )
                }
            }
        }
        if onlineProbeToken == probeToken {
            onlineProbeTask = probeTask
        }
    }

    private func reconcileApplication(
        selectedIdentity: ApplicationIdentity,
        previousPID: pid_t,
        attempt: SessionAttemptID,
        timeout: TimeInterval,
    ) async throws -> MacApplicationStartupPlan {
        if let applicationReconcileOverride {
            return try await applicationReconcileOverride(
                selectedIdentity,
                previousPID,
                attempt,
                timeout,
            )
        }

        let callbackAttemptGate = attemptGate
        let reconciliationTask = Task.detached(priority: .userInitiated) {
            try await MacApplicationStartupReconciler.reconcile(
                selectedIdentity: selectedIdentity,
                previousPID: previousPID,
                attempt: attempt,
                timeout: timeout,
                pollInterval: 0.05,
                candidates: {
                    var observed = MacApplicationIdentityResolver.liveCandidates(excluding: getpid())
                    if selectedIdentity.strength == .weak,
                       Self.processIsRunning(previousPID),
                       !observed.contains(where: { $0.pid == previousPID }) {
                        observed.append(MacApplicationProcessSnapshot(
                            pid: previousPID,
                            identity: selectedIdentity,
                            displayName: "selected-source",
                        ))
                    }
                    return observed
                },
                topology: { candidate in
                    if let bundleURL = candidate.identity.bundleURL {
                        return ProcessTreeEnumerator.pidsRooted(in: bundleURL)
                    }
                    if let executableURL = candidate.identity.executableURL {
                        return ProcessTreeEnumerator.pidsRooted(inExecutableURL: executableURL)
                    }
                    return []
                },
                translatedTargets: { pids in
                    AppAudioCapture.validatedAudioProcessPIDs(in: pids)
                },
                isCurrentAttempt: { callbackAttemptGate.accepts($0) },
            )
        }
        return try await MacApplicationStartupTask.value(of: reconciliationTask)
    }

    private static func isValidStrongApplicationPlan(
        _ plan: MacApplicationStartupPlan,
        selectedIdentity: ApplicationIdentity,
    ) -> Bool {
        selectedIdentity.strength == .strong
            && plan.result.state == .resolved
            && plan.rootPID != nil
            && !plan.topologyPIDs.isEmpty
            && !plan.translatedTargetPIDs.isEmpty
    }

    private func beginApplicationRebind(
        plan: MacApplicationStartupPlan,
        attempt: SessionAttemptID,
        signalState: CaptureSignalState,
    ) {
        guard onlineRebindTask == nil,
              let oldGeneration = activeSourceGeneration,
              let selectedIdentity = onlineSelectedIdentity,
              let liveContinuation = liveBufferContinuation,
              let oldRootPID = onlineRootPID
        else { return }

        let sourceWasAvailable = onlineSourceAvailable
        if sourceWasAvailable {
            guard MacApplicationRebindPolicy.decide(
                selectedIdentity: selectedIdentity,
                currentRootPID: oldRootPID,
                currentTargetPIDs: Array(onlineTargetPIDs),
                resolution: plan.result,
                signalState: signalState,
            ) == .rebind else { return }
        } else {
            // After the destructive point there is no old tap to preserve.
            // A strong identity may recover even when the latest observation
            // is temporarily missing/ambiguous; the task will re-resolve
            // before constructing the next source.
            guard selectedIdentity.strength == .strong else { return }
        }

        guard rebindCoordinator.begin(attempt) else { return }
        let rebindCancellation = CaptureStartCancellation()
        onlineRebindCancellation = rebindCancellation

        let rebindToken = UUID()
        onlineRebindToken = rebindToken
        let oldTargets = Array(onlineTargetPIDs)
        onlineRebindTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.onlineRebindToken == rebindToken {
                    self.rebindCoordinator.end(attempt)
                    self.onlineRebindTask = nil
                    self.onlineRebindToken = nil
                    self.onlineRebindCancellation = nil
                }
            }
            guard let self else { return }
            do {
                // Confirm the observation while the existing tap is still
                // alive. A transient helper row must not destroy a healthy
                // source merely because it disappeared before handoff.
                let confirmed = try await self.reconcileApplication(
                    selectedIdentity: selectedIdentity,
                    previousPID: oldRootPID,
                    attempt: attempt,
                    timeout: 1.0,
                )
                guard self.isCapturing,
                      self.activeAttempt == attempt,
                      self.attemptGate.accepts(attempt),
                      self.rebindCoordinator.canPublish(attempt),
                      self.onlineRebindToken == rebindToken,
                      !rebindCancellation.isCancelled
                else { return }

                if sourceWasAvailable {
                    let confirmedDecision = MacApplicationRebindPolicy.decide(
                        selectedIdentity: selectedIdentity,
                        currentRootPID: oldRootPID,
                        currentTargetPIDs: oldTargets,
                        resolution: confirmed.result,
                        signalState: signalState,
                    )
                    guard confirmedDecision == .rebind else {
                        // The topology returned to the old observation. Keep
                        // the current tap intact and let the next probe retry.
                        return
                    }
                } else {
                    guard Self.isValidStrongApplicationPlan(confirmed, selectedIdentity: selectedIdentity) else {
                        throw CaptureError.applicationAudioUnavailable
                    }
                }

                if sourceWasAvailable {
                    do {
                        try await self.rebindDriver.stopApplicationSource(
                            attempt: attempt,
                            sourceGeneration: oldGeneration,
                        )
                    } catch {
                        // A failed stop is not evidence that the old tap is
                        // still healthy. The generation is already stale, so
                        // keep the control plane source-less and let the
                        // bounded recovery path decide what can be rebuilt.
                        self.onlineSourceAvailable = false
                        if self.onlineRecoveryDeadline == nil {
                            self.onlineRecoveryDeadline = ProcessInfo.processInfo.systemUptime + 6
                        }
                        throw error
                    }
                    guard self.isCapturing,
                          self.activeAttempt == attempt,
                          self.attemptGate.accepts(attempt),
                          self.rebindCoordinator.canPublish(attempt),
                          self.onlineRebindToken == rebindToken,
                          !rebindCancellation.isCancelled
                    else {
                        // The old native source was already stopped. Do not
                        // leave the control plane claiming it is healthy when
                        // cancellation wins after that destructive point.
                        self.onlineSourceAvailable = false
                        if self.onlineRecoveryDeadline == nil {
                            self.onlineRecoveryDeadline = ProcessInfo.processInfo.systemUptime + 6
                        }
                        return
                    }
                    self.onlineSourceAvailable = false
                    if self.onlineRecoveryDeadline == nil {
                        self.onlineRecoveryDeadline = ProcessInfo.processInfo.systemUptime + 6
                    }
                    self.signalHealthTracker?.invalidate(attempt)
                    self.signalHealth = nil
                }

                // The generation remains old until the native stop/drain
                // above has completed. Only then publish the new generation
                // and reset signal health before resolving/building it.
                guard let nextGeneration = self.sourceGenerationGate.advance(attempt) else {
                    throw CancellationError()
                }
                self.activeSourceGeneration = nextGeneration
                let freshTracker = CaptureSignalHealthTracker(
                    attempt: attempt,
                    thresholds: .macOSApplication,
                )
                self.signalHealthTracker = freshTracker
                self.signalHealth = freshTracker.snapshot(for: attempt)

                let refreshed: MacApplicationStartupPlan
                if sourceWasAvailable {
                    // The old tap is gone now. A same-topology result is
                    // valid: it still needs a fresh CATap over the session.
                    refreshed = try await self.reconcileApplication(
                        selectedIdentity: selectedIdentity,
                        previousPID: oldRootPID,
                        attempt: attempt,
                        timeout: Self.onlineProcessRegistrationTimeout,
                    )
                } else {
                    refreshed = confirmed
                }
                guard Self.isValidStrongApplicationPlan(refreshed, selectedIdentity: selectedIdentity) else {
                    throw CaptureError.applicationAudioUnavailable
                }
                guard let rootPID = refreshed.rootPID else {
                    throw CaptureError.applicationAudioUnavailable
                }

                let callbackSourceGate = self.sourceGenerationGate
                let callbackAttemptGate = self.attemptGate
                let sourceCallbackGate: @Sendable () -> Bool = {
                    callbackSourceGate.accepts(attempt, generation: nextGeneration)
                }
                let applicationSink: LiveAudioSink = { buffer in
                    guard callbackAttemptGate.accepts(attempt),
                          callbackSourceGate.accepts(attempt, generation: nextGeneration)
                    else { return }
                    _ = freshTracker.recordCallback(
                        for: attempt,
                        measurement: CaptureSignalMeasurement(
                            samples: buffer.samples,
                            channelCount: buffer.channelCount,
                        ),
                    )
                    _ = liveContinuation.yield(buffer)
                }
                let baseline = await self.liveStore.callbackCount()
                try await self.rebindDriver.startApplicationSource(
                    attempt: attempt,
                    sourceGeneration: nextGeneration,
                    rootPID: rootPID,
                    pids: refreshed.topologyPIDs,
                    registrationTimeout: Self.onlineProcessRegistrationTimeout,
                    liveSink: applicationSink,
                    sourceCallbackGate: sourceCallbackGate,
                )
                _ = try await self.waitForFirstCallbacks(
                    after: baseline,
                    timeout: Self.onlineFirstBufferTimeout,
                    cancellation: rebindCancellation,
                )
                guard self.isCapturing,
                      self.activeAttempt == attempt,
                      self.attemptGate.accepts(attempt),
                      self.sourceGenerationGate.accepts(attempt, generation: nextGeneration),
                      self.rebindCoordinator.canPublish(attempt),
                      self.onlineRebindToken == rebindToken
                else { return }
                self.onlineRootPID = rootPID
                self.onlineTargetPIDs = Set(refreshed.translatedTargetPIDs)
                self.activeSourceGeneration = nextGeneration
                self.onlineSourceAvailable = true
                self.onlineRecoveryDeadline = nil
                self.onlineRebindFailureCount = 0
            } catch {
                guard self.isCapturing,
                      self.activeAttempt == attempt,
                      self.rebindCoordinator.canPublish(attempt),
                      self.onlineRebindToken == rebindToken
                else { return }
                self.onlineRebindFailureCount += 1
                if self.onlineRebindFailureCount >= 2 {
                    self.reportTerminalFailure(
                        CaptureError.applicationAudioUnavailable.localizedDescription,
                        recoverySuggestion: .systemOutput,
                    )
                }
            }
        }
    }

    private func terminateMicrophoneCapture(_ error: String) {
        guard isCapturing else { return }
        microphoneCaptureOwner.release()
        reportTerminalFailure(error)
        MicCaptureDiagnostics.record("CaptureController stopped after terminal microphone error")
    }

    /// Park the failure for the model's recovery path while leaving
    /// `isCapturing` true until `abortPreservingAudio()` performs the same
    /// idempotent stop/finalization used by a normal user stop. Clearing the
    /// recording flag here would strand a valid partial WAV outside that path.
    private func reportTerminalFailure(
        _ message: String,
        category: CaptureTerminalFailureCategory = .source,
        recoverySuggestion: CaptureRecoverySuggestion? = nil,
    ) {
        guard terminalCaptureFailure == nil else { return }
        let allowedSuggestion = CaptureRecoveryPolicy.suggestion(
            for: category,
            scope: activeCaptureScope,
        )
        terminalCaptureFailure = CaptureTerminalFailure(
            message: message,
            category: category,
            recoverySuggestion: recoverySuggestion == allowedSuggestion
                ? recoverySuggestion
                : nil,
        )
        levelTimer?.invalidate()
        levelTimer = nil
        levelDBFS = -120
    }

    private func reportNativeTerminalFailure(
        _ failure: CaptureNativeTerminalFailure,
    ) {
        let category: CaptureTerminalFailureCategory = switch failure.category {
        case .source: .source
        case .durableMaster: .durableMaster
        }
        let suggestion = CaptureRecoveryPolicy.suggestion(
            for: category,
            scope: activeCaptureScope,
        )
        reportTerminalFailure(
            failure.message,
            category: category,
            recoverySuggestion: suggestion,
        )
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
