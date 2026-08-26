import AudioTapLib
@testable import ClassScribe
import Foundation
import Testing

@Test
func invalidWAVFixturesArePreserved() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let empty = folder.appendingPathComponent("empty.wav")
    try Data().write(to: empty)
    let headerOnly = folder.appendingPathComponent("header-only.wav")
    try pcm16WAVHeader(dataBytes: 0).write(to: headerOnly)
    let truncated = folder.appendingPathComponent("truncated.wav")
    try Data("RIFF\0\0\0\0WAVE".utf8).write(to: truncated)

    for url in [empty, headerOnly, truncated] {
        do {
            _ = try WavFile.validate(url)
            Issue.record("Se esperaba rechazo de \(url.lastPathComponent)")
        } catch {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}

@Test
func silentAndContinuousWAVFixtures() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let silence = folder.appendingPathComponent("silence.wav")
    try WavFile.writeFloat32(Array(repeating: 0, count: 16000), to: silence)
    #expect(try abs(WavFile.validate(silence) - 1) < 0.02)

    let continuous = folder.appendingPathComponent("continuous.wav")
    let samples = (0 ..< 32000).map { index in
        Float(sin(2 * .pi * 220 * Double(index) / 16000) * 0.2)
    }
    try WavFile.writeFloat32(samples, to: continuous)
    #expect(try abs(WavFile.validate(continuous) - 2) < 0.02)
}

@Test
func streamingRawWrapPreservesInput() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let raw = folder.appendingPathComponent("source.raw")
    let samples = Array(repeating: Float(0.1), count: 16000)
    let rawData = samples.withUnsafeBytes { Data($0) }
    try rawData.write(to: raw)
    let destination = folder.appendingPathComponent("source.wav")
    try Data("contenido anterior".utf8).write(to: destination)

    try WavFile.wrapFloat32Raw(raw, destination: destination)
    #expect(try abs(WavFile.validate(destination) - 1) < 0.02)
    #expect(try Data(contentsOf: raw) == rawData)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .allSatisfy { !$0.hasSuffix(".tmp") })
}

@Test
func rawRecoveryPreservesEvidence() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let raw = folder.appendingPathComponent("source.raw")
    let samples = Array(repeating: Float(0.08), count: 16000)
    let rawData = samples.withUnsafeBytes { Data($0) }
    try rawData.write(to: raw)
    let destination = folder.appendingPathComponent("source.wav")
    let invalidWAV = Data("WAV incompleto que debe conservarse".utf8)
    try invalidWAV.write(to: destination)

    #expect(try abs(WavFile.recoverFloat32Raw(raw, destination: destination) - 1) < 0.02)
    #expect(try Data(contentsOf: raw) == rawData)
    #expect(try abs(WavFile.validate(destination) - 1) < 0.02)
    let preserved = try FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: nil,
    ).filter { $0.lastPathComponent.hasPrefix("source-invalid-preserved-") }
    #expect(preserved.count == 1)
    let preservedURL = try #require(preserved.first)
    #expect(try Data(contentsOf: preservedURL) == invalidWAV)
    let permissions = try #require(
        FileManager.default.attributesOfItem(atPath: preservedURL.path)[.posixPermissions] as? NSNumber,
    ).intValue & 0o777
    #expect(permissions == 0o600)
}

@Test
func truncatedRawDoesNotReplaceDestination() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let raw = folder.appendingPathComponent("source.raw")
    try Data([0, 1, 2]).write(to: raw)
    let destination = folder.appendingPathComponent("source.wav")
    let original = Data("evidencia WAV".utf8)
    try original.write(to: destination)

    #expect(throws: CaptureError.self) {
        _ = try WavFile.recoverFloat32Raw(raw, destination: destination)
    }
    #expect(try Data(contentsOf: destination) == original)
}

@Test
func masterRecoveryRegeneratesASRDerivativeAndPreservesMaster() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let master = folder.appendingPathComponent("master.raw")
    let manifest = folder.appendingPathComponent("audio-manifest.json")
    let source = folder.appendingPathComponent("source.wav")
    let samples = (0 ..< 480).flatMap { _ in [Float(0.2), Float(-0.2)] }

    try masterFloat32LEData(samples).write(to: master, options: .atomic)
    try AudioManifestStore.write(
        AudioManifest(
            master: AudioManifestMaster(sampleRate: 48_000, channels: 2),
        ),
        to: manifest,
    )

    #expect(try abs(WavFile.recoverMaster(master, manifestURL: manifest, destination: source) - 0.01) < 0.0001)
    #expect(try abs(WavFile.validateMaster(master, manifestURL: manifest) - 0.01) < 0.0001)
    #expect(try abs(WavFile.validate(source) - 0.01) < 0.0001)
    #expect(FileManager.default.fileExists(atPath: master.path))
    #expect(FileManager.default.fileExists(atPath: manifest.path))
}

@Test
func failedMasterDerivativeLeavesAuthoritativeArtifactsAndDestinationEvidence() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let master = folder.appendingPathComponent("master.raw")
    let manifest = folder.appendingPathComponent("audio-manifest.json")
    let source = folder.appendingPathComponent("source.wav")
    let previousSource = Data("source evidence".utf8)

    try Data([0, 1, 2]).write(to: master)
    try AudioManifestStore.write(
        AudioManifest(
            master: AudioManifestMaster(sampleRate: 48_000, channels: 2),
        ),
        to: manifest,
    )
    try previousSource.write(to: source)

    #expect(throws: CaptureError.self) {
        _ = try WavFile.deriveASRFromMaster(
            masterURL: master,
            manifestURL: manifest,
            destination: source,
        )
    }
    #expect(try Data(contentsOf: master) == Data([0, 1, 2]))
    #expect(try Data(contentsOf: source) == previousSource)
    #expect(FileManager.default.fileExists(atPath: manifest.path))
}

@Test
func symbolicAudioIsRejectedWithoutTouchingItsTarget() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("outside.wav")
    try WavFile.writeFloat32(Array(repeating: Float(0.1), count: 16000), to: target)
    let original = try Data(contentsOf: target)
    let link = folder.appendingPathComponent("source.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(throws: CaptureError.self) {
        _ = try WavFile.validate(link)
    }

    let raw = folder.appendingPathComponent("source.raw")
    let samples = Array(repeating: Float(0.2), count: 16000)
    try samples.withUnsafeBytes { Data($0) }.write(to: raw)
    #expect(throws: CaptureError.self) {
        _ = try WavFile.recoverFloat32Raw(raw, destination: link)
    }
    #expect(try Data(contentsOf: target) == original)
    #expect((try link.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
}

@Test
func liveAudioGenerationRejectsQueuedBuffersFromPreviousSession() async {
    let store = LiveAudioBufferStore()
    let oldGeneration = await store.reset()
    let newGeneration = await store.reset()
    let buffer = LiveAudioBuffer(
        samples: Array(repeating: Float(0.25), count: 1600),
        channelCount: 1,
        sampleRate: 16000,
        hostTime: 0,
    )

    await store.append(buffer, generation: oldGeneration)
    #expect(await store.totalSamples() == 0)
    await store.append(buffer, generation: newGeneration)
    #expect(await store.totalSamples() == 1600)
}

@Test
func liveAudioWaitAcceptsSilentFramesAndTimesOutWithoutCallbacks() async throws {
    let store = LiveAudioBufferStore()
    let generation = await store.reset()
    let silentBuffer = LiveAudioBuffer(
        samples: Array(repeating: 0, count: 320),
        channelCount: 1,
        sampleRate: 16000,
        hostTime: 0,
    )

    await store.append(silentBuffer, generation: generation)
    #expect(try await store.waitForSamples(after: 0, timeout: 0) == 320)

    _ = await store.reset()
    #expect(try await store.waitForSamples(after: 0, timeout: 0) == nil)
}

@Test
func trailingSilenceDurationDistinguishesThinkingPauseFromLongPause() async {
    let store = LiveAudioBufferStore()
    var generation = await store.reset()
    await store.append(
        LiveAudioBuffer(
            samples: Array(repeating: Float(0.2), count: 16_000)
                + Array(repeating: 0, count: 44_800), // 2.8 s
            channelCount: 1,
            sampleRate: 16_000,
            hostTime: 0,
        ),
        generation: generation,
    )
    let thinkingPause = await store.recentSilenceDuration()
    #expect(abs(thinkingPause - 2.8) < 0.01)
    #expect(await store.hasRecentPause())
    #expect(thinkingPause < TranscriptParagraphPolicy.longPause)

    let thinkingPauseBoundary = await store.totalSamples()
    await store.append(
        LiveAudioBuffer(
            samples: Array(repeating: Float(0.2), count: 1_600),
            channelCount: 1,
            sampleRate: 16_000,
            hostTime: 0,
        ),
        generation: generation,
    )
    #expect(await store.recentSilenceDuration() == 0)
    #expect(abs(await store.recentSilenceDuration(endingAt: thinkingPauseBoundary) - 2.8) < 0.01)

    generation = await store.reset()
    await store.append(
        LiveAudioBuffer(
            samples: Array(repeating: Float(0.2), count: 16_000)
                + Array(repeating: 0, count: 67_200), // 4.2 s
            channelCount: 1,
            sampleRate: 16_000,
            hostTime: 0,
        ),
        generation: generation,
    )
    #expect(await store.recentSilenceDuration() >= TranscriptParagraphPolicy.longPause)
}

@Test
func emptyNon16kCallbackIsIgnoredWithoutIndexingAnEmptyBuffer() async {
    let store = LiveAudioBufferStore()
    let generation = await store.reset()
    await store.append(
        LiveAudioBuffer(samples: [], channelCount: 2, sampleRate: 48000, hostTime: 0),
        generation: generation,
    )
    #expect(await store.totalSamples() == 0)
}

@Test
func preciseLiveWindowRejectsHistoryClippedByTheRing() async {
    let store = LiveAudioBufferStore()
    let generation = await store.reset()
    // The store retains 45 seconds (720,000 samples). Rotating even a small
    // prefix out must not let an ASR retry commit a shortened historical range.
    await store.append(
        LiveAudioBuffer(
            samples: Array(repeating: 0, count: 720_100),
            channelCount: 1,
            sampleRate: 16000,
            hostTime: 0,
        ),
        generation: generation,
    )

    #expect(await store.window(seconds: 7, endingAt: 88_000) != nil)
    #expect(await store.window(
        seconds: 7,
        endingAt: 88_000,
        requiresCompleteHistory: true,
    ) == nil)
    #expect(await store.window(
        seconds: 7,
        endingAt: 720_000,
        requiresCompleteHistory: true,
    ) != nil)
}

@Test
func liveAudioWaitPropagatesCancellation() async {
    let store = LiveAudioBufferStore()
    _ = await store.reset()
    let wait = Task {
        try await store.waitForSamples(after: 0, timeout: 30)
    }
    wait.cancel()

    do {
        _ = try await wait.value
        Issue.record("La espera cancelada no debe continuar hasta el timeout")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("Error inesperado: \(error)")
    }
}

@Test
func audioFrameWatchdogTracksFramesRatherThanAudibility() {
    var watchdog = AudioFrameWatchdog(stallTimeout: 5)
    watchdog.reset(sampleCount: 320, now: 10)

    let beforeTimeout = watchdog.observe(sampleCount: 320, now: 14.99)
    #expect(!beforeTimeout)
    let atTimeout = watchdog.observe(sampleCount: 320, now: 15)
    #expect(atTimeout)
    // A silent callback still advances the sample count and restores health.
    let resumed = watchdog.observe(sampleCount: 640, now: 15.1)
    #expect(!resumed)
    let healthyBeforeSecondTimeout = watchdog.observe(sampleCount: 640, now: 20.09)
    #expect(!healthyBeforeSecondTimeout)
    let secondTimeout = watchdog.observe(sampleCount: 640, now: 20.1)
    #expect(secondTimeout)
}

@Test
func captureSourceFailuresGiveActionableRecovery() {
    let noAppFrames = CaptureError.applicationAudioUnavailable.localizedDescription
    #expect(noAppFrames.contains("permiso de Audio"))
    #expect(noAppFrames.contains("siga abierta"))
    #expect(CaptureError.microphoneUnavailable.localizedDescription.contains("elige otro"))
}

@Test
func processLivenessProbeDoesNotSignalTheSource() {
    #expect(CaptureController.processIsRunning(getpid()))
    #expect(!CaptureController.processIsRunning(-1))
    #expect(!CaptureController.processIsRunning(pid_t.max))
}

@Test
func audioProcessStartupWaitRetriesTransientRegistration() async throws {
    let probe = RegistrationProbe(succeedingOnAttempt: 3)
    let ready = try await AudioProcessStartupWaiter.waitUntilRegistered(
        pids: [123],
        // The full suite runs tests concurrently and can starve this task for
        // more than a second on a small Mac. A generous deadline keeps the
        // assertion about retry count rather than scheduler timing.
        timeout: 30,
        pollInterval: 0.001,
        registrationProbe: { _ in probe.poll() },
    )

    #expect(ready)
    #expect(probe.attempts == 3)
}

@Test
func audioProcessStartupWaitTimesOutAndHonorsCancellation() async {
    let timedOut = try? await AudioProcessStartupWaiter.waitUntilRegistered(
        pids: [123],
        timeout: 0,
        registrationProbe: { _ in false },
    )
    #expect(timedOut == false)

    let probe = RegistrationProbe(succeedingOnAttempt: .max)
    let wait = Task {
        try await AudioProcessStartupWaiter.waitUntilRegistered(
            pids: [123],
            timeout: 30,
            pollInterval: 1,
            registrationProbe: { _ in probe.poll() },
        )
    }
    wait.cancel()
    do {
        _ = try await wait.value
        Issue.record("Una espera de registro cancelada no debe iniciar captura más tarde")
    } catch is CancellationError {
        // Expected: the structured wait leaves no autonomous retry behind.
    } catch {
        Issue.record("Error inesperado: \(error)")
    }
}

private func makeAudioValidationFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-audio-validation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

private func masterFloat32LEData(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * MemoryLayout<Float>.size)
    for sample in samples {
        var bits = (sample.isFinite ? sample : 0).bitPattern.littleEndian
        data.append(Data(bytes: &bits, count: MemoryLayout<UInt32>.size))
    }
    return data
}

private func pcm16WAVHeader(dataBytes: UInt32) -> Data {
    var bytes: [UInt8] = [
        0x52, 0x49, 0x46, 0x46,
        0, 0, 0, 0,
        0x57, 0x41, 0x56, 0x45,
        0x66, 0x6D, 0x74, 0x20,
        16, 0, 0, 0,
        1, 0,
        1, 0,
        0x80, 0x3E, 0, 0,
        0, 0x7D, 0, 0,
        2, 0,
        16, 0,
        0x64, 0x61, 0x74, 0x61,
        0, 0, 0, 0,
    ]
    let riffSize = UInt32(36) + dataBytes
    withUnsafeBytes(of: riffSize.littleEndian) { bytes.replaceSubrange(4 ..< 8, with: $0) }
    withUnsafeBytes(of: dataBytes.littleEndian) { bytes.replaceSubrange(40 ..< 44, with: $0) }
    return Data(bytes)
}

private final class RegistrationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let succeedingOnAttempt: Int
    private var pollCount = 0

    init(succeedingOnAttempt: Int) {
        self.succeedingOnAttempt = succeedingOnAttempt
    }

    func poll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pollCount += 1
        return pollCount >= succeedingOnAttempt
    }

    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return pollCount
    }
}
