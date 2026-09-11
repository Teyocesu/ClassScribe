@testable import ClassScribe
import Foundation
import Testing

@Test
func emptyLiveAsrResultDoesNotPublishTranscribing() {
    #expect(LiveASRResultGate.acceptedText(" \n\t") == nil)
    #expect(!LiveASRResultGate.shouldPublishTranscribing(" \n\t"))
}

@Test
func acceptedLiveAsrResultPublishesTranscribing() {
    #expect(LiveASRResultGate.acceptedText("  método científico  ") == "método científico")
    #expect(LiveASRResultGate.shouldPublishTranscribing("  método científico  "))
}

@Test
func speechPresenceIsRequiredBeforeAcceptingLiveText() {
    let silence = SpeechPresenceEvidence.none
    let voice = SpeechPresenceEvidence(
        regions: [SpeechPresenceRegion(start: 1, end: 2)],
    )

    #expect(LiveASRResultGate.acceptedText("texto inventado", speechEvidence: silence) == nil)
    #expect(!LiveASRResultGate.shouldPublishTranscribing("texto inventado", speechEvidence: silence))
    #expect(LiveASRResultGate.acceptedText(" texto válido ", speechEvidence: voice) == "texto válido")
}

@Test
func noSpeechRejectsEveryAsrSegment() {
    let segment = TranscriptSegment(
        start: 0,
        end: 1,
        text: "texto inventado",
        speakerID: "Persona desconocida",
        confidence: 0.5,
    )

    #expect(!SpeechPresenceEvidence.none.hasVoice)
    #expect(SpeechPresenceAcceptancePolicy.filterSegments([segment], evidence: .none).isEmpty)
}

@Test
func speechOverlapKeepsSegmentsAtTheConservativeBoundary() {
    let evidence = SpeechPresenceEvidence(
        regions: [SpeechPresenceRegion(start: 1, end: 2)],
    )

    #expect(SpeechPresenceAcceptancePolicy.intersects(
        segmentStart: 1.2,
        segmentEnd: 1.4,
        regions: evidence.regions,
    ))
    #expect(SpeechPresenceAcceptancePolicy.intersects(
        segmentStart: 0.7,
        segmentEnd: 0.8,
        regions: evidence.regions,
    ))
    #expect(SpeechPresenceAcceptancePolicy.intersects(
        segmentStart: 2.3,
        segmentEnd: 2.4,
        regions: evidence.regions,
    ))
}

@Test
func speechFilterRejectsSegmentsOutsideThePaddedRegions() {
    let segment = TranscriptSegment(
        start: 2.31,
        end: 2.6,
        text: "ruido",
        speakerID: "Persona desconocida",
        confidence: 0.5,
    )
    let evidence = SpeechPresenceEvidence(
        regions: [SpeechPresenceRegion(start: 1, end: 2)],
    )

    #expect(!SpeechPresenceAcceptancePolicy.intersects(
        segmentStart: segment.start,
        segmentEnd: segment.end,
        regions: evidence.regions,
    ))
    #expect(SpeechPresenceAcceptancePolicy.filterSegments([segment], evidence: evidence).isEmpty)
}

@Test
func vadFailurePreservesTheOriginalAsrSegments() {
    let original = [TranscriptSegment(
        start: 4,
        end: 5,
        text: "texto ASR",
        speakerID: "Persona desconocida",
        confidence: 0.8,
    )]

    #expect(SpeechPresenceAcceptancePolicy.filterSegments(original, evidence: nil) == original)
}

private actor SingleFlightProbe {
    private(set) var calls = 0
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    func load(after delay: Duration = .milliseconds(180)) async throws -> Int {
        calls += 1
        let waiters = callWaiters
        callWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await Task.sleep(for: delay)
        return 42
    }

    func waitUntilCalled() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }
}

private actor SerialExecutionProbe {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0

    func perform(for duration: Duration) async throws -> Int {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: duration)
        return calls
    }
}

@Test
func concurrentModelLoadsShareOneOperation() async throws {
    let flight = AsyncSingleFlight<Int>()
    let probe = SingleFlightProbe()

    async let first = flight.value { try await probe.load() }
    async let second = flight.value { try await probe.load() }

    #expect(try await (first, second) == (42, 42))
    #expect(await probe.calls == 1)
    #expect(try await flight.value { try await probe.load() } == 42)
    #expect(await probe.calls == 1)
}

@Test
func cancelledModelWaiterDoesNotCancelSharedLoad() async throws {
    let flight = AsyncSingleFlight<Int>()
    let probe = SingleFlightProbe()
    let first = Task { try await flight.value { try await probe.load(after: .milliseconds(300)) } }

    await probe.waitUntilCalled()
    #expect(await probe.calls == 1)
    let second = Task { try await flight.value { try await probe.load() } }
    let cancelledAt = Date()
    first.cancel()

    do {
        _ = try await first.value
        Issue.record("Se esperaba CancellationError")
    } catch is CancellationError {
        // Expected: only this waiter leaves; the shared operation survives.
    }
    #expect(Date().timeIntervalSince(cancelledAt) < 0.2)
    #expect(try await second.value == 42)
    #expect(await probe.calls == 1)
}

@Test
func inferenceExecutorPreventsOverlappingPredictions() async throws {
    let executor = AsyncSerialExecutor()
    let probe = SerialExecutionProbe()

    async let first = executor.run { try await probe.perform(for: .milliseconds(80)) }
    async let second = executor.run { try await probe.perform(for: .milliseconds(20)) }
    _ = try await (first, second)

    #expect(await probe.calls == 2)
    #expect(await probe.maximumActive == 1)
}

@Test
func cancelledQueuedPredictionNeverStarts() async throws {
    let executor = AsyncSerialExecutor()
    let probe = SerialExecutionProbe()
    let first = Task { try await executor.run { try await probe.perform(for: .milliseconds(180)) } }
    for _ in 0 ..< 200 {
        if await probe.active == 1 { break }
        await Task.yield()
    }
    #expect(await probe.active == 1)

    let queued = Task { try await executor.run { try await probe.perform(for: .milliseconds(10)) } }
    queued.cancel()
    do {
        _ = try await queued.value
        Issue.record("Se esperaba CancellationError")
    } catch is CancellationError {
        // Expected: it leaves promptly but retains its place until predecessor ends.
    }
    _ = try await first.value
    try await Task.sleep(for: .milliseconds(20))
    #expect(await probe.calls == 1)
    #expect(await probe.maximumActive == 1)
}

@Test
func liveCursorCommitsOnlySuccessfulWindows() {
    var cursor = LiveTranscriptionCursor(hopSamples: 10)
    #expect(cursor.nextWindowEnd(totalSamples: 35) == 10)
    // No commit represents an ASR failure: the exact range remains pending.
    #expect(cursor.nextWindowEnd(totalSamples: 70) == 10)
    cursor.commit(windowEndingAt: 10)
    #expect(cursor.nextWindowEnd(totalSamples: 70) == 20)
    cursor.commit(windowEndingAt: 20)
    #expect(cursor.nextWindowEnd(totalSamples: 57, preferLatest: true) == 50)
}

@Test
func liveCursorRecoversWhenPendingWindowExpiredFromRing() {
    var cursor = LiveTranscriptionCursor(hopSamples: 10)
    #expect(cursor.nextWindowEnd(totalSamples: 10) == 10)

    // Simulate enough failed/backed-off time that end=10 is no longer in a
    // bounded ring whose newest sample is 100.
    let recovery = cursor.recoverFromExpiredWindow(totalSamples: 107)
    #expect(recovery?.end == 100)
    #expect(recovery?.skippedSamples == 90)
    #expect(cursor.nextWindowEnd(totalSamples: 107) == 100)
    cursor.commit(windowEndingAt: 100)
    #expect(cursor.nextWindowEnd(totalSamples: 110) == 110)
}

@Test
func liveRetryBackoffIsBoundedAndResetsAfterSuccess() {
    var policy = LiveTranscriptionRetryPolicy()
    var now: TimeInterval = 100
    for expected in [2.0, 4, 8, 15, 30] {
        let delay = policy.recordFailure(atUptime: now)
        #expect(delay == expected)
        #expect(!policy.canAttempt(atUptime: now + delay - 0.01))
        now += delay
        #expect(policy.canAttempt(atUptime: now))
    }
    #expect(policy.recordFailure(atUptime: now) == 0)
    #expect(policy.isUnavailableForSession)
    #expect(!policy.canAttempt(atUptime: now))
    policy.recordSuccess()
    #expect(policy.consecutiveFailures == 0)
    #expect(!policy.isUnavailableForSession)
    #expect(policy.canAttempt(atUptime: now))
}

@Test
func liveTaskGracePeriodDoesNotWaitForever() async {
    let slow = Task<Void, Never> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                continuation.resume()
            }
        }
    }
    slow.cancel() // The continuation intentionally ignores cancellation.
    // Returning false proves that the timeout won. Do not assert elapsed wall
    // time: the parallel test runner can suspend both racers under heavy load.
    #expect(await TaskCompletionGracePeriod.wait(for: slow, timeout: 0.02) == false)
    await slow.value

    let finished = Task<Void, Never> {}
    #expect(await TaskCompletionGracePeriod.wait(for: finished, timeout: 0.2))
}
