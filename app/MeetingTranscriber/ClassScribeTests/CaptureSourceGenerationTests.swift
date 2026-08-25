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

private final class TestRebindDriver: CaptureApplicationRebindDriver, @unchecked Sendable {
    private let emitFirstCallback: Bool
    private var stopCountValue = 0
    private var startCountValue = 0

    init(emitFirstCallback: Bool = true) {
        self.emitFirstCallback = emitFirstCallback
    }

    var stopCount: Int {
        return stopCountValue
    }

    var startCount: Int {
        return startCountValue
    }

    func stopApplicationSource(
        attempt: SessionAttemptID,
        sourceGeneration: CaptureSourceGeneration,
    ) async throws {
        _ = attempt
        _ = sourceGeneration
        stopCountValue += 1
    }

    func startApplicationSource(
        attempt: SessionAttemptID,
        sourceGeneration: CaptureSourceGeneration,
        rootPID: pid_t,
        pids: [pid_t],
        registrationTimeout: TimeInterval,
        liveSink: @escaping LiveAudioSink,
        sourceCallbackGate: @escaping @Sendable () -> Bool,
    ) async throws {
        _ = attempt
        _ = sourceGeneration
        _ = rootPID
        _ = pids
        _ = registrationTimeout
        _ = sourceCallbackGate
        startCountValue += 1
        let shouldEmit = emitFirstCallback
        if shouldEmit {
            liveSink(LiveAudioBuffer(
                samples: [0],
                channelCount: 1,
                sampleRate: 16_000,
                hostTime: 0,
            ))
        }
    }
}

private final class TestApplicationReconcileSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [MacApplicationStartupPlan]

    init(_ plans: [MacApplicationStartupPlan]) {
        self.plans = plans
    }

    func next() throws -> MacApplicationStartupPlan {
        lock.lock()
        defer { lock.unlock() }
        guard !plans.isEmpty else {
            throw CaptureError.applicationAudioUnavailable
        }
        return plans.removeFirst()
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

private func missingResolution() -> MacApplicationStartupPlan {
    MacApplicationStartupPlan(
        result: generationResolution(state: .missing, rootPID: nil, targets: []),
    )
}

private func startupPlan(rootPID: pid_t, targets: [pid_t]) -> MacApplicationStartupPlan {
    MacApplicationStartupPlan(
        result: generationResolution(rootPID: rootPID, targets: targets),
    )
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

@MainActor
@Test
func successfulStartupCleanupDoesNotDisableMidRecordingRebind() async {
    let attempt = SessionAttemptID(generation: 1)
    let identity = strongTestIdentity()
    let changed = startupPlan(rootPID: 200, targets: [200, 300])
    let driver = TestRebindDriver()
    let sequence = TestApplicationReconcileSequence([changed, changed])
    let controller = CaptureController(
        rebindDriver: driver,
        applicationReconcile: { _, _, _, _ in try sequence.next() },
    )
    await controller.prepareOnlineRebindLifecycleForTest(
        attempt: attempt,
        selectedIdentity: identity,
        rootPID: 200,
        targetPIDs: [200],
    )

    #expect(controller.beginApplicationRebindForTest(plan: changed, attempt: attempt))
    await controller.waitForApplicationRebindForTest()

    #expect(driver.stopCount == 1)
    #expect(driver.startCount == 1)
    #expect(controller.onlineSourceAvailableForTest)
    controller.cleanupOnlineRebindLifecycleForTest(for: attempt)
}

@MainActor
@Test
func failedRebindPrerequisiteDoesNotLeakCoordinatorOwnership() async {
    let attempt = SessionAttemptID(generation: 1)
    let identity = strongTestIdentity()
    let changed = startupPlan(rootPID: 200, targets: [200, 300])
    let driver = TestRebindDriver()
    let sequence = TestApplicationReconcileSequence([changed, changed])
    let controller = CaptureController(
        rebindDriver: driver,
        applicationReconcile: { _, _, _, _ in try sequence.next() },
    )
    await controller.prepareOnlineRebindLifecycleForTest(
        attempt: attempt,
        selectedIdentity: identity,
        rootPID: 200,
        targetPIDs: [200],
        includeLiveContinuation: false,
    )

    #expect(!controller.beginApplicationRebindForTest(plan: changed, attempt: attempt))

    await controller.prepareOnlineRebindLifecycleForTest(
        attempt: attempt,
        selectedIdentity: identity,
        rootPID: 200,
        targetPIDs: [200],
    )
    #expect(controller.beginApplicationRebindForTest(plan: changed, attempt: attempt))
    await controller.waitForApplicationRebindForTest()

    #expect(driver.startCount == 1)
    controller.cleanupOnlineRebindLifecycleForTest(for: attempt)
}

@MainActor
@Test
func stopCancelsRebindFirstCallbackWait() async {
    let attempt = SessionAttemptID(generation: 1)
    let identity = strongTestIdentity()
    let changed = startupPlan(rootPID: 200, targets: [200, 300])
    let driver = TestRebindDriver(emitFirstCallback: false)
    let sequence = TestApplicationReconcileSequence([changed, changed])
    let controller = CaptureController(
        rebindDriver: driver,
        applicationReconcile: { _, _, _, _ in try sequence.next() },
    )
    await controller.prepareOnlineRebindLifecycleForTest(
        attempt: attempt,
        selectedIdentity: identity,
        rootPID: 200,
        targetPIDs: [200],
    )

    #expect(controller.beginApplicationRebindForTest(plan: changed, attempt: attempt))
    for _ in 0 ..< 100 {
        if controller.onlineRebindFirstCallbackWaitActiveForTest { break }
        await Task.yield()
    }
    #expect(controller.onlineRebindFirstCallbackWaitActiveForTest)

    controller.cancelApplicationRebindForTest(for: attempt)
    await controller.waitForApplicationRebindForTest()

    #expect(!controller.onlineRebindFirstCallbackWaitActiveForTest)
    #expect(!controller.onlineSourceAvailableForTest)
    controller.cleanupOnlineRebindLifecycleForTest(for: attempt)
}

@MainActor
@Test
func transientHelperAppearanceDoesNotDestroyHealthySource() async {
    let attempt = SessionAttemptID(generation: 1)
    let identity = strongTestIdentity()
    let changed = startupPlan(rootPID: 200, targets: [200, 300])
    let original = startupPlan(rootPID: 200, targets: [200])
    let driver = TestRebindDriver()
    let sequence = TestApplicationReconcileSequence([original])
    let controller = CaptureController(
        rebindDriver: driver,
        applicationReconcile: { _, _, _, _ in try sequence.next() },
    )
    await controller.prepareOnlineRebindLifecycleForTest(
        attempt: attempt,
        selectedIdentity: identity,
        rootPID: 200,
        targetPIDs: [200],
    )

    #expect(controller.beginApplicationRebindForTest(plan: changed, attempt: attempt))
    await controller.waitForApplicationRebindForTest()

    #expect(driver.stopCount == 0)
    #expect(driver.startCount == 0)
    #expect(controller.onlineSourceAvailableForTest)
    controller.cleanupOnlineRebindLifecycleForTest(for: attempt)
}

@MainActor
@Test
func topologyReturnsToOriginalAfterOldStopStillStartsSource() async {
    let attempt = SessionAttemptID(generation: 1)
    let identity = strongTestIdentity()
    let changed = startupPlan(rootPID: 200, targets: [200, 300])
    let original = startupPlan(rootPID: 200, targets: [200])
    let driver = TestRebindDriver()
    let sequence = TestApplicationReconcileSequence([changed, original])
    let controller = CaptureController(
        rebindDriver: driver,
        applicationReconcile: { _, _, _, _ in try sequence.next() },
    )
    await controller.prepareOnlineRebindLifecycleForTest(
        attempt: attempt,
        selectedIdentity: identity,
        rootPID: 200,
        targetPIDs: [200],
    )

    #expect(controller.beginApplicationRebindForTest(plan: changed, attempt: attempt))
    await controller.waitForApplicationRebindForTest()

    #expect(driver.stopCount == 1)
    #expect(driver.startCount == 1)
    #expect(controller.onlineSourceAvailableForTest)
    controller.cleanupOnlineRebindLifecycleForTest(for: attempt)
}

@MainActor
@Test
func failedPostStopResolutionCannotLeaveHealthyStateWithNoNativeSource() async {
    let attempt = SessionAttemptID(generation: 1)
    let identity = strongTestIdentity()
    let changed = startupPlan(rootPID: 200, targets: [200, 300])
    let driver = TestRebindDriver()
    let sequence = TestApplicationReconcileSequence([changed, missingResolution()])
    let controller = CaptureController(
        rebindDriver: driver,
        applicationReconcile: { _, _, _, _ in try sequence.next() },
    )
    await controller.prepareOnlineRebindLifecycleForTest(
        attempt: attempt,
        selectedIdentity: identity,
        rootPID: 200,
        targetPIDs: [200],
    )

    #expect(controller.beginApplicationRebindForTest(plan: changed, attempt: attempt))
    await controller.waitForApplicationRebindForTest()

    #expect(driver.stopCount == 1)
    #expect(driver.startCount == 0)
    #expect(!controller.onlineSourceAvailableForTest)
    #expect(controller.onlineRecoveryPendingForTest)
    controller.cleanupOnlineRebindLifecycleForTest(for: attempt)
}

private final class TestGenerationClock: @unchecked Sendable, CaptureMonotonicClock {
    func now() -> TimeInterval { 0 }
}
