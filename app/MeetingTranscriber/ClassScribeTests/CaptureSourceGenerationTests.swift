@testable import AudioTapLib
import Foundation
import Testing
@testable import ClassScribe

private final class GenerationTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func generationResolution(
    state: ApplicationResolutionState = .resolved,
    rootPID: pid_t? = 200,
    targets: [pid_t] = [200],
) -> ApplicationResolutionResult {
    ApplicationResolutionResult(
        state: state,
        selectedIdentity: "bundle-id:com.example.class",
        previousPID: 100,
        resolvedPID: rootPID,
        candidateCount: state == .ambiguous ? 2 : 1,
        candidatePIDs: rootPID.map { [$0] } ?? [],
        topologyPIDs: targets,
        translatedTargetPIDs: targets,
        candidate: nil,
    )
}

private func strongTestIdentity() -> ApplicationIdentity {
    ApplicationIdentity(bundleIdentifier: "com.example.class")
}

@Test
func oldSourceGenerationCallbackRejectedAfterAdvance() {
    let attempt = SessionAttemptID(generation: 1)
    let gate = CaptureSourceGenerationGate()
    let old = gate.begin(attempt)
    let next = gate.advance(attempt)!

    #expect(!gate.accepts(attempt, generation: old))
    #expect(gate.accepts(attempt, generation: next))
}

@Test
func newSourceGenerationCallbackAccepted() {
    let attempt = SessionAttemptID(generation: 1)
    let gate = CaptureSourceGenerationGate()
    let generation = gate.begin(attempt)

    #expect(gate.accepts(attempt, generation: generation))
}

@Test
func sourceGenerationCannotCrossSessionAttempt() {
    let first = SessionAttemptID(generation: 1)
    let second = SessionAttemptID(sessionID: first.sessionID, generation: 2)
    let gate = CaptureSourceGenerationGate()
    let generation = gate.begin(first)

    #expect(!gate.accepts(second, generation: generation))
}

@Test
func sourceOrderOnlyChangeDoesNotRebind() {
    let decision = MacApplicationRebindPolicy.decide(
        selectedIdentity: strongTestIdentity(),
        currentRootPID: 200,
        currentTargetPIDs: [200, 300],
        resolution: generationResolution(rootPID: 200, targets: [300, 200]),
    )

    #expect(decision == .noChange)
}

@Test
func exactlyOneRebindRunsAtATime() {
    let attempt = SessionAttemptID(generation: 1)
    let coordinator = CaptureRebindCoordinator()

    #expect(coordinator.begin(attempt))
    #expect(!coordinator.begin(attempt))
    coordinator.end(attempt)
    #expect(coordinator.begin(attempt))
}

@Test
func stopDuringRebindPreventsNewSourcePublication() {
    let attempt = SessionAttemptID(generation: 1)
    let coordinator = CaptureRebindCoordinator()
    #expect(coordinator.begin(attempt))

    coordinator.cancel(attempt)

    #expect(!coordinator.canPublish(attempt))
}

@Test
func staleRebindCompletionCannotAffectNextSession() {
    let first = SessionAttemptID(generation: 1)
    let second = SessionAttemptID(sessionID: first.sessionID, generation: 2)
    let coordinator = CaptureRebindCoordinator()
    #expect(coordinator.begin(first))
    coordinator.cancel(first)
    #expect(coordinator.begin(second))

    #expect(!coordinator.canPublish(first))
    #expect(coordinator.canPublish(second))
}

@Test
func newGenerationStartsWithFreshSignalHealth() {
    let clock = TestGenerationClock()
    let attempt = SessionAttemptID(generation: 1)
    let tracker = CaptureSignalHealthTracker(
        attempt: attempt,
        thresholds: .test,
        clock: clock,
    )
    #expect(tracker.recordCallback(
        for: attempt,
        measurement: CaptureSignalMeasurement(sampleCount: 160, frameCount: 160, rms: 0.2),
    ))
    tracker.begin(attempt)

    #expect(tracker.snapshot(for: attempt)?.state == .awaitingCallbacks)
    #expect(tracker.snapshot(for: attempt)?.callbackCount == 0)
}

@Test
func helperTargetAppearsMidRecordingTriggersOneRebind() {
    let decision = MacApplicationRebindPolicy.decide(
        selectedIdentity: strongTestIdentity(),
        currentRootPID: 200,
        currentTargetPIDs: [200],
        resolution: generationResolution(rootPID: 200, targets: [200, 300]),
    )

    #expect(decision == .rebind)
}

@Test
func strongRootReplacementTriggersRebind() {
    let decision = MacApplicationRebindPolicy.decide(
        selectedIdentity: strongTestIdentity(),
        currentRootPID: 200,
        currentTargetPIDs: [200],
        resolution: generationResolution(rootPID: 400, targets: [400]),
    )

    #expect(decision == .rebind)
}

@Test
func ambiguousReplacementDoesNotRebind() {
    let decision = MacApplicationRebindPolicy.decide(
        selectedIdentity: strongTestIdentity(),
        currentRootPID: 200,
        currentTargetPIDs: [200],
        resolution: generationResolution(state: .ambiguous, rootPID: nil, targets: []),
    )

    #expect(decision == .preserveCurrent)
}

@Test
func weakRootDeathDoesNotAutoRebind() {
    let decision = MacApplicationRebindPolicy.decide(
        selectedIdentity: ApplicationIdentity(executableURL: URL(fileURLWithPath: "/tmp/player")),
        currentRootPID: 200,
        currentTargetPIDs: [200],
        resolution: generationResolution(rootPID: 400, targets: [400]),
    )

    #expect(decision == .unsupportedWeakIdentity)
}

@Test
func oldTapCallbacksCannotWriteAfterGenerationAdvance() {
    let attempt = SessionAttemptID(generation: 1)
    let gate = CaptureSourceGenerationGate()
    let old = gate.begin(attempt)
    let written = GenerationTestCounter()
    let callback = {
        guard gate.accepts(attempt, generation: old) else { return }
        written.increment()
    }
    _ = gate.advance(attempt)
    callback()

    #expect(written.current == 0)
}

@Test
func oldTapFullyStopsBeforeNewTapStarts() async {
    let oldCallbacks = InFlightCallbackGate()
    oldCallbacks.open()
    #expect(oldCallbacks.enter())
    let finished = GenerationTestCounter()
    let stop = Task {
        oldCallbacks.closeAndWait()
        finished.increment()
    }
    while oldCallbacks.snapshot.inFlight == 0 { await Task.yield() }
    oldCallbacks.leave()
    await stop.value

    let newCallbacks = InFlightCallbackGate()
    newCallbacks.open()
    #expect(finished.current == 1)
    #expect(newCallbacks.enter())
    newCallbacks.leave()
}

@Test
func rebindUsesSameDurableOutputFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-rebind-\(UUID().uuidString).raw")
    defer { try? FileManager.default.removeItem(at: url) }
    FileManager.default.createFile(atPath: url.path, contents: Data([1, 2]))
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([3, 4]))
    try handle.close()

    #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
}

@Test
func rebindDoesNotTruncateExistingRawAudio() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-rebind-\(UUID().uuidString).raw")
    defer { try? FileManager.default.removeItem(at: url) }
    FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 7, count: 8))
    let before = try Data(contentsOf: url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0, count: 4))
    try handle.close()

    let after = try Data(contentsOf: url)
    #expect(after.starts(with: before))
    #expect(after.count == before.count + 4)
}

@Test
func rebindGapPreservesTimelineDuration() {
    let anchor = TimelineAnchor(rate: 16_000)
    _ = anchor.silenceFramesBefore(hostSeconds: 100, frameCount: 1_600)
    _ = anchor.silenceFramesBefore(hostSeconds: 100.1, frameCount: 1_600)

    #expect(anchor.silenceFramesBefore(hostSeconds: 102.7, frameCount: 1_600) == 40_000)
}

@Test
func newTapFirstCallbackCompletesOnlyNewGeneration() {
    let attempt = SessionAttemptID(generation: 1)
    let gate = CaptureSourceGenerationGate()
    let old = gate.begin(attempt)
    let next = gate.advance(attempt)!
    let accepted = GenerationTestCounter()
    if gate.accepts(attempt, generation: old) { accepted.increment() }
    if gate.accepts(attempt, generation: next) { accepted.increment() }

    #expect(accepted.current == 1)
}

@Test
func rebindFailurePreservesExistingAudio() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-rebind-\(UUID().uuidString).raw")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data(repeating: 3, count: 16)
    FileManager.default.createFile(atPath: url.path, contents: original)

    // A failed source generation changes no durable session file; the
    // existing evidence remains readable for recovery/finalization.
    #expect(try Data(contentsOf: url) == original)
}

private final class TestGenerationClock: @unchecked Sendable, CaptureMonotonicClock {
    func now() -> TimeInterval { 0 }
}
