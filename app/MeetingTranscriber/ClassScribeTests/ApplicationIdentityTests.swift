import CoreAudio
import Foundation
import Testing
import AudioTapLib
@testable import ClassScribe

private final class IdentityTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private func strongIdentity(
    _ bundleID: String = "com.example.class",
    bundlePath: String = "/Applications/Class.app",
) -> ApplicationIdentity {
    ApplicationIdentity(
        bundleIdentifier: bundleID,
        bundleURL: URL(fileURLWithPath: bundlePath),
    )
}

private func snapshot(
    pid: pid_t,
    identity: ApplicationIdentity,
    name: String = "Class",
) -> MacApplicationProcessSnapshot {
    MacApplicationProcessSnapshot(pid: pid, identity: identity, displayName: name)
}

@Test
func sameIdentitySamePidResolves() {
    let identity = strongIdentity()
    let result = MacApplicationIdentityResolver.resolve(
        selectedIdentity: identity,
        previousPID: 101,
        candidates: [snapshot(pid: 101, identity: identity)],
    )

    #expect(result.state == .resolved)
    #expect(result.resolvedPID == 101)
}

@Test
func sameIdentityReplacementPidResolvesDuringStartup() {
    let identity = strongIdentity()
    let result = MacApplicationIdentityResolver.resolve(
        selectedIdentity: identity,
        previousPID: 101,
        candidates: [snapshot(pid: 202, identity: identity)],
    )

    #expect(result.state == .resolved)
    #expect(result.previousPID == 101)
    #expect(result.resolvedPID == 202)
}

@Test
func helperAppearsAfterInitialEnumerationIsIncluded() async throws {
    let identity = strongIdentity()
    let topologyCalls = IdentityTestCounter()
    let plan = try await MacApplicationStartupReconciler.reconcile(
        selectedIdentity: identity,
        previousPID: 101,
        attempt: SessionAttemptID(generation: 1),
        timeout: 1,
        pollInterval: 0.001,
        candidates: { [snapshot(pid: 101, identity: identity)] },
        topology: { _ in
            topologyCalls.increment() == 1 ? [101] : [101, 202]
        },
        translatedTargets: { pids in
            pids.contains(202) ? [202] : []
        },
        isCurrentAttempt: { _ in true },
        isProcessAlive: { _ in true },
    )

    #expect(plan.result.state == .resolved)
    #expect(plan.topologyPIDs == [101, 202])
    #expect(plan.translatedTargetPIDs == [202])
}

@Test
func deadPidIsRemovedFromTopology() async throws {
    let identity = strongIdentity()
    let plan = try await MacApplicationStartupReconciler.reconcile(
        selectedIdentity: identity,
        previousPID: 101,
        attempt: SessionAttemptID(generation: 1),
        timeout: 1,
        candidates: { [snapshot(pid: 101, identity: identity)] },
        topology: { _ in [101, 303] },
        translatedTargets: { $0 },
        isCurrentAttempt: { _ in true },
        isProcessAlive: { $0 == 101 },
    )

    #expect(plan.topologyPIDs == [101])
    #expect(!plan.topologyPIDs.contains(303))
}

@Test
func unrelatedSameDisplayNameIsNotSelected() {
    let selected = strongIdentity("com.example.selected")
    let unrelated = strongIdentity("com.example.other")
    let result = MacApplicationIdentityResolver.resolve(
        selectedIdentity: selected,
        previousPID: 101,
        candidates: [snapshot(pid: 202, identity: unrelated, name: "Class")],
    )

    #expect(result.state == .missing)
    #expect(result.resolvedPID == nil)
}

@Test
func multipleStrongMatchesAreAmbiguous() {
    let identity = strongIdentity()
    let result = MacApplicationIdentityResolver.resolve(
        selectedIdentity: identity,
        previousPID: 101,
        candidates: [
            snapshot(pid: 101, identity: identity),
            snapshot(pid: 202, identity: identity),
        ],
    )

    #expect(result.state == .ambiguous)
    #expect(result.resolvedPID == nil)
    #expect(result.candidatePIDs == [101, 202])
}

@Test
func missingApplicationIsMissing() {
    let result = MacApplicationIdentityResolver.resolve(
        selectedIdentity: strongIdentity(),
        previousPID: 101,
        candidates: [],
    )

    #expect(result.state == .missing)
    #expect(result.resolvedPID == nil)
}

@Test
func staleAttemptCannotPublishResolvedTopology() async {
    let identity = strongIdentity()
    let attempt = SessionAttemptID(generation: 1)
    await #expect(throws: CancellationError.self) {
        try await MacApplicationStartupReconciler.reconcile(
            selectedIdentity: identity,
            previousPID: 101,
            attempt: attempt,
            timeout: 1,
            candidates: { [snapshot(pid: 202, identity: identity)] },
            topology: { _ in [202] },
            translatedTargets: { $0 },
            isCurrentAttempt: { _ in false },
            isProcessAlive: { _ in true },
        )
    }
}

@Test
func translatedAudioTargetIsValidatedBeforeTapHandoff() {
    let targets = AudioTargetValidation.translateAndValidate(
        [101, 202],
        translate: { pid -> AudioObjectID? in pid == 101 ? AudioObjectID(7) : AudioObjectID(8) },
        roundTrip: { pid, objectID in pid == 101 && objectID == 7 },
    )

    #expect(targets.map(\.pid) == [101])
    #expect(targets.map(\.audioObjectID) == [AudioObjectID(7)])
}

@Test
func noValidAudioObjectsDoesNotCreateTap() {
    let targets = AudioTargetValidation.translateAndValidate(
        [101, 202],
        translate: { _ -> AudioObjectID? in nil },
        roundTrip: { _, _ in true },
    )

    // AppAudioCapture.startCapture throws before CATapDescription when this
    // set is empty; an empty tap target list is never handed to CoreAudio.
    #expect(targets.isEmpty)
}
