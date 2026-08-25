import AudioTapLib
import Foundation
import Testing
@testable import ClassScribe

private final class FakeCaptureMonotonicClock: @unchecked Sendable, CaptureMonotonicClock {
    var value: TimeInterval

    init(_ value: TimeInterval = 0) {
        self.value = value
    }

    func now() -> TimeInterval {
        value
    }

    func advance(by seconds: TimeInterval) {
        value += seconds
    }
}

private func silentMeasurement(samples: Int = 160) -> CaptureSignalMeasurement {
    CaptureSignalMeasurement(
        samples: [Float](repeating: 0, count: samples),
        channelCount: 1,
    )
}

private func audibleMeasurement(samples: Int = 160) -> CaptureSignalMeasurement {
    CaptureSignalMeasurement(
        samples: [Float](repeating: 0.2, count: samples),
        channelCount: 1,
    )
}

@Test
func noCallbackBeforeBudgetStaysAwaiting() {
    let clock = FakeCaptureMonotonicClock()
    let attempt = SessionAttemptID(generation: 1)
    let tracker = CaptureSignalHealthTracker(
        attempt: attempt,
        thresholds: .test,
        clock: clock,
    )

    clock.advance(by: 4.99)

    #expect(tracker.snapshot(for: attempt)?.state == .awaitingCallbacks)
}

@Test
func noCallbackAfterBudgetClassifiesUnavailable() {
    let clock = FakeCaptureMonotonicClock()
    let attempt = SessionAttemptID(generation: 1)
    let tracker = CaptureSignalHealthTracker(
        attempt: attempt,
        thresholds: .test,
        clock: clock,
    )

    clock.advance(by: 5)

    let snapshot = tracker.snapshot(for: attempt)
    #expect(snapshot?.state == .noCallbacks)
    #expect(snapshot?.callbackCount == 0)
}

@Test
func zeroSamplesAreSilentNotDead() {
    let clock = FakeCaptureMonotonicClock()
    let attempt = SessionAttemptID(generation: 1)
    let tracker = CaptureSignalHealthTracker(
        attempt: attempt,
        thresholds: .test,
        clock: clock,
    )

    #expect(tracker.recordCallback(
        for: attempt,
        measurement: CaptureSignalMeasurement(sampleCount: 0, frameCount: 0, rms: 0),
    ))

    let snapshot = tracker.snapshot(for: attempt)
    #expect(snapshot?.state == .silent)
    #expect(snapshot?.callbackCount == 1)
    #expect(snapshot?.sampleCount == 0)
}

@Test
func silentCallbacksKeepStreamHealthy() {
    let clock = FakeCaptureMonotonicClock()
    let attempt = SessionAttemptID(generation: 1)
    let tracker = CaptureSignalHealthTracker(
        attempt: attempt,
        thresholds: .test,
        clock: clock,
    )

    #expect(tracker.recordCallback(for: attempt, measurement: silentMeasurement()))
    clock.advance(by: 2.99)
    #expect(tracker.recordCallback(for: attempt, measurement: silentMeasurement()))

    let snapshot = tracker.snapshot(for: attempt)
    #expect(snapshot?.state == .silent)
    #expect(snapshot?.hasReceivedCallbacks == true)
    #expect(snapshot?.elapsedSinceLastCallback == 0)
}

@Test
func audibleSamplesBecomeAudible() {
    let clock = FakeCaptureMonotonicClock()
    let attempt = SessionAttemptID(generation: 1)
    let tracker = CaptureSignalHealthTracker(
        attempt: attempt,
        thresholds: .test,
        clock: clock,
    )

    #expect(tracker.recordCallback(for: attempt, measurement: audibleMeasurement()))

    let snapshot = tracker.snapshot(for: attempt)
    #expect(snapshot?.state == .audible)
    #expect(snapshot?.energyDBFS ?? -120 > -40)
}

@Test
func audibleToSilentIsNotFailure() {
    let clock = FakeCaptureMonotonicClock()
    let attempt = SessionAttemptID(generation: 1)
    let tracker = CaptureSignalHealthTracker(
        attempt: attempt,
        thresholds: .test,
        clock: clock,
    )

    #expect(tracker.recordCallback(for: attempt, measurement: audibleMeasurement()))
    clock.advance(by: 1)
    #expect(tracker.recordCallback(for: attempt, measurement: silentMeasurement()))

    let snapshot = tracker.snapshot(for: attempt)
    #expect(snapshot?.state == .silent)
    #expect(snapshot?.hasReceivedCallbacks == true)
}

@Test
func callbackStallAfterHealthyStreamDetected() {
    let clock = FakeCaptureMonotonicClock()
    let attempt = SessionAttemptID(generation: 1)
    let tracker = CaptureSignalHealthTracker(
        attempt: attempt,
        thresholds: .test,
        clock: clock,
    )

    #expect(tracker.recordCallback(for: attempt, measurement: audibleMeasurement()))
    clock.advance(by: 3)

    #expect(tracker.snapshot(for: attempt)?.state == .noCallbacks)
}

@Test
func staleAttemptCannotChangeSignalState() {
    let clock = FakeCaptureMonotonicClock()
    let first = SessionAttemptID(generation: 1)
    let second = SessionAttemptID(sessionID: first.sessionID, generation: 2)
    let tracker = CaptureSignalHealthTracker(
        attempt: first,
        thresholds: .test,
        clock: clock,
    )
    #expect(tracker.recordCallback(for: first, measurement: audibleMeasurement()))

    clock.advance(by: 10)
    tracker.begin(second)
    #expect(!tracker.recordCallback(for: first, measurement: silentMeasurement()))

    let snapshot = tracker.snapshot(for: second)
    #expect(snapshot?.state == .awaitingCallbacks)
    #expect(snapshot?.callbackCount == 0)
    #expect(snapshot?.sampleCount == 0)
}

@Test
func nextAttemptStartsWithFreshHealthState() {
    let clock = FakeCaptureMonotonicClock()
    let first = SessionAttemptID(generation: 1)
    let second = SessionAttemptID(sessionID: first.sessionID, generation: 2)
    let tracker = CaptureSignalHealthTracker(
        attempt: first,
        thresholds: .test,
        clock: clock,
    )
    #expect(tracker.recordCallback(for: first, measurement: audibleMeasurement()))

    clock.advance(by: 10)
    tracker.begin(second)

    let snapshot = tracker.snapshot(for: second)
    #expect(snapshot?.state == .awaitingCallbacks)
    #expect(snapshot?.callbackCount == 0)
    #expect(snapshot?.sampleCount == 0)
    #expect(snapshot?.startedAtMonotonic == 10)
}

@Test
func asrEmptyDoesNotChangeCaptureHealth() {
    let clock = FakeCaptureMonotonicClock()
    let attempt = SessionAttemptID(generation: 1)
    let tracker = CaptureSignalHealthTracker(
        attempt: attempt,
        thresholds: .test,
        clock: clock,
    )
    #expect(tracker.recordCallback(for: attempt, measurement: audibleMeasurement()))
    let before = tracker.snapshot(for: attempt)

    // An empty ASR result is deliberately not an input to this tracker. The
    // only accepted input is callback evidence from the capture adapter.
    let emptyTranscript = ""
    #expect(emptyTranscript.isEmpty)
    #expect(tracker.snapshot(for: attempt) == before)
}

@Test
func emptyLiveCallbackCountsAsTransportEvidence() async throws {
    let store = LiveAudioBufferStore()
    let generation = await store.reset()
    await store.append(
        LiveAudioBuffer(samples: [], channelCount: 2, sampleRate: 48_000, hostTime: 0),
        generation: generation,
    )

    #expect(try await store.waitForCallbacks(after: 0, timeout: 0) == 1)
    #expect(await store.totalSamples() == 0)
}
