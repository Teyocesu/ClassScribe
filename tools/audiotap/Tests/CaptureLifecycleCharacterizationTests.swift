@testable import AudioTapLib
import Foundation
import XCTest

/// Deterministic lifecycle characterization at the boundary where production
/// calls CATap/AVAudioEngine. It deliberately does not call CoreAudio: the
/// physical gate is exercised by the local probe, while these tests make the
/// cancellation and next-attempt ordering reproducible without hardware.
final class CaptureLifecycleCharacterizationTests: XCTestCase {
    func testNormalStartStopThenNextAttemptRejectsStaleCallback() throws {
        let harness = IsolatedCaptureHarness()
        let attemptA = try XCTUnwrap(harness.start())
        XCTAssertEqual(harness.waitForSetup(), .success)

        XCTAssertTrue(harness.emitFrame(for: attemptA))
        harness.stop(attemptA)
        XCTAssertFalse(
            harness.emitFrame(for: attemptA),
            "callbacks from A must be rejected after A teardown begins",
        )

        let attemptB = try XCTUnwrap(harness.start())
        XCTAssertEqual(harness.waitForSetup(), .success)
        XCTAssertTrue(harness.emitFrame(for: attemptB))

        let events = harness.events()
        XCTAssertEqual(
            events.filter { $0.kind == .acceptedFrame && $0.attempt == attemptA.id }.count,
            1,
        )
        XCTAssertEqual(
            events.filter { $0.kind == .acceptedFrame && $0.attempt == attemptB.id }.count,
            1,
        )
        XCTAssertEqual(
            events.filter { $0.kind == .nativeResourceDestroyed && $0.attempt == attemptA.id }.count,
            1,
        )
        XCTAssertEqual(
            events.filter { $0.kind == .callbackStopped && $0.attempt == attemptA.id }.count,
            1,
        )
        XCTAssertEqual(
            events.filter { $0.kind == .staleFrameRejected && $0.attempt == attemptA.id }.count,
            1,
        )

        let bSetupIndex = try XCTUnwrap(events.firstIndex { $0.kind == .setupReturned && $0.attempt == attemptB.id })
        let aDestroyedIndex = try XCTUnwrap(events.firstIndex { $0.kind == .nativeResourceDestroyed && $0.attempt == attemptA.id })
        let aCancelIndex = try XCTUnwrap(events.firstIndex { $0.kind == .cancelRequested && $0.attempt == attemptA.id })
        let aCallbackStoppedIndex = try XCTUnwrap(events.firstIndex { $0.kind == .callbackStopped && $0.attempt == attemptA.id })
        XCTAssertLessThan(aCancelIndex, aCallbackStoppedIndex)
        XCTAssertLessThan(aCallbackStoppedIndex, aDestroyedIndex)
        XCTAssertLessThan(aDestroyedIndex, bSetupIndex, "B cannot start before A's native resource is destroyed")
        XCTAssertEqual(events.filter { $0.kind == .acceptedFrame }.map(\.attempt), [attemptA.id, attemptB.id])

        print(
            "capture-characterization route=isolated-seam "
                + "setup=\(harness.setupDurationSeconds) "
                + "stop=\(harness.stopDurationSeconds) "
                + "teardown=\(harness.teardownDurationSeconds) "
                + "next_attempt=PASS",
        )
    }

    func testNonCooperativeNativeSetupBlocksOwnerQueueUntilNativeReturns() throws {
        let probe = OwnerQueueFaultProbe()
        probe.startAttemptA()
        XCTAssertEqual(probe.nativeEntered.wait(timeout: .now() + .seconds(1)), .success)

        let cancellationRequestedAt = monotonicSeconds()
        probe.requestCancel()
        probe.enqueueAttemptB()

        XCTAssertEqual(
            probe.cancelHandled.wait(timeout: .now() + .milliseconds(100)),
            .timedOut,
            "a non-cooperative synchronous native call blocks cancellation on the owning executor",
        )
        XCTAssertEqual(
            probe.attemptBStarted.wait(timeout: .now() + .milliseconds(100)),
            .timedOut,
            "the next attempt cannot run while the owning executor is blocked",
        )

        probe.releaseNativeOperation()
        XCTAssertEqual(probe.cancelHandled.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertEqual(probe.attemptBStarted.wait(timeout: .now() + .seconds(1)), .success)

        let events = probe.events()
        let nativeReturn = try XCTUnwrap(events.firstIndex { $0.kind == .nativeReturned })
        let cancelHandled = try XCTUnwrap(events.firstIndex { $0.kind == .cancelHandled })
        XCTAssertLessThan(nativeReturn, cancelHandled)
        XCTAssertGreaterThanOrEqual(probe.cancelHandledAt, cancellationRequestedAt)

        print(
            "capture-characterization route=owner-queue-fault "
                + "cancel_requested=PASS "
                + "cancel_handled_after_native_return=PASS "
                + "attempt_b_delayed=PASS",
        )
    }
}

private struct CharacterizationAttempt: Equatable {
    let id: Int
    let generation: UInt64
}

private enum CharacterizationEventKind: Equatable {
    case setupReturned
    case acceptedFrame
    case staleFrameRejected
    case cancelRequested
    case callbackStopped
    case nativeResourceDestroyed
    case nativeEntered
    case nativeReturned
    case cancelHandled
    case attemptBStarted
}

private struct CharacterizationEvent {
    let kind: CharacterizationEventKind
    let attempt: Int
    let ticks: UInt64
}

/// Small in-process lifecycle seam. The native queue is separate from the
/// caller, so the gate can invalidate A before a late setup/callback returns.
private final class IsolatedCaptureHarness: @unchecked Sendable {
    private let lifecycle = CaptureLifecycleGate()
    private let nativeQueue = DispatchQueue(label: "classscribe.capture-characterization.native")
    private let lock = NSLock()
    private var nextID = 0
    private var resources = Set<Int>()
    private var timeline: [CharacterizationEvent] = []
    private let setupSignal = DispatchSemaphore(value: 0)

    private(set) var setupDurationSeconds = 0.0
    private(set) var stopDurationSeconds = 0.0
    private(set) var teardownDurationSeconds = 0.0

    func start() -> CharacterizationAttempt? {
        guard let generation = lifecycle.begin() else { return nil }
        let attempt = CharacterizationAttempt(id: nextID, generation: generation)
        nextID += 1
        let startedAt = monotonicSeconds()
        nativeQueue.async {
            self.lock.lock()
            self.resources.insert(attempt.id)
            self.lock.unlock()
            self.record(.setupReturned, attempt: attempt.id)
            self.setupDurationSeconds = monotonicSeconds() - startedAt
            self.setupSignal.signal()

            if !self.lifecycle.isActive(attempt.generation) {
                self.destroyNativeResource(for: attempt)
            }
        }
        return attempt
    }

    func waitForSetup() -> DispatchTimeoutResult {
        setupSignal.wait(timeout: .now() + .seconds(1))
    }

    func emitFrame(for attempt: CharacterizationAttempt) -> Bool {
        guard lifecycle.isActive(attempt.generation) else {
            record(.staleFrameRejected, attempt: attempt.id)
            return false
        }
        record(.acceptedFrame, attempt: attempt.id)
        return true
    }

    func stop(_ attempt: CharacterizationAttempt) {
        let stopStartedAt = monotonicSeconds()
        record(.cancelRequested, attempt: attempt.id)
        lifecycle.cancel()
        record(.callbackStopped, attempt: attempt.id)
        stopDurationSeconds = monotonicSeconds() - stopStartedAt

        let teardownStartedAt = monotonicSeconds()
        nativeQueue.sync {
            self.destroyNativeResource(for: attempt)
        }
        teardownDurationSeconds = monotonicSeconds() - teardownStartedAt
    }

    func events() -> [CharacterizationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return timeline
    }

    private func destroyNativeResource(for attempt: CharacterizationAttempt) {
        lock.lock()
        let owned = resources.remove(attempt.id) != nil
        lock.unlock()
        if owned {
            record(.nativeResourceDestroyed, attempt: attempt.id)
        }
        lifecycle.end(attempt.generation)
    }

    private func record(_ kind: CharacterizationEventKind, attempt: Int) {
        lock.lock()
        timeline.append(CharacterizationEvent(kind: kind, attempt: attempt, ticks: DispatchTime.now().uptimeNanoseconds))
        lock.unlock()
    }
}

/// Mirrors the current MainActor ownership problem without sleeping around
/// ClassScribe code: the injected native boundary itself never returns until
/// the test explicitly releases it. Cancel and B are queued on the same owner
/// executor, making the blocking relationship observable and bounded.
private final class OwnerQueueFaultProbe: @unchecked Sendable {
    let nativeEntered = DispatchSemaphore(value: 0)
    let cancelHandled = DispatchSemaphore(value: 0)
    let attemptBStarted = DispatchSemaphore(value: 0)
    private let ownerQueue = DispatchQueue(label: "classscribe.capture-characterization.owner")
    private let nativeRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timeline: [CharacterizationEvent] = []
    private(set) var cancelHandledAt = 0.0

    func startAttemptA() {
        ownerQueue.async {
            self.record(.nativeEntered, attempt: 0)
            self.nativeEntered.signal()
            self.nativeRelease.wait()
            self.record(.nativeReturned, attempt: 0)
        }
    }

    func requestCancel() {
        record(.cancelRequested, attempt: 0)
        ownerQueue.async {
            self.cancelHandledAt = monotonicSeconds()
            self.record(.cancelHandled, attempt: 0)
            self.cancelHandled.signal()
        }
    }

    func enqueueAttemptB() {
        ownerQueue.async {
            self.record(.attemptBStarted, attempt: 1)
            self.attemptBStarted.signal()
        }
    }

    func releaseNativeOperation() {
        nativeRelease.signal()
    }

    func events() -> [CharacterizationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return timeline
    }

    private func record(_ kind: CharacterizationEventKind, attempt: Int) {
        lock.lock()
        timeline.append(CharacterizationEvent(kind: kind, attempt: attempt, ticks: DispatchTime.now().uptimeNanoseconds))
        lock.unlock()
    }
}

private func monotonicSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
