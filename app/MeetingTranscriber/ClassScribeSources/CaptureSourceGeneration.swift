import Foundation

/// Identifies one concrete native source incarnation inside one session
/// attempt. It is deliberately runtime-only: it is never persisted as the
/// logical application identity or as part of a recovered session.
struct CaptureSourceGeneration: Equatable, Hashable, Sendable {
    let attempt: SessionAttemptID
    let number: UInt64

    var token: String {
        attempt.token + ":source-" + String(number)
    }
}

/// Thread-safe ownership gate for native source callbacks. The session
/// attempt gate and this gate are separate axes: an old tap/recorder from the
/// same attempt must be rejected after a rebind as well as after Stop.
final class CaptureSourceGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeAttempt: SessionAttemptID?
    private var activeNumber: UInt64 = 0

    @discardableResult
    func begin(_ attempt: SessionAttemptID) -> CaptureSourceGeneration {
        lock.lock()
        activeAttempt = attempt
        activeNumber = 1
        let generation = CaptureSourceGeneration(attempt: attempt, number: activeNumber)
        lock.unlock()
        return generation
    }

    @discardableResult
    func advance(_ attempt: SessionAttemptID) -> CaptureSourceGeneration? {
        lock.lock()
        defer { lock.unlock() }
        guard activeAttempt == attempt else { return nil }
        activeNumber &+= 1
        return CaptureSourceGeneration(attempt: attempt, number: activeNumber)
    }

    func accepts(_ attempt: SessionAttemptID, generation: CaptureSourceGeneration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeAttempt == attempt
            && generation.attempt == attempt
            && generation.number == activeNumber
    }

    func invalidate(_ attempt: SessionAttemptID) {
        lock.lock()
        if activeAttempt == attempt {
            activeAttempt = nil
            activeNumber = 0
        }
        lock.unlock()
    }

    var current: CaptureSourceGeneration? {
        lock.lock()
        defer { lock.unlock() }
        guard let activeAttempt else { return nil }
        return CaptureSourceGeneration(attempt: activeAttempt, number: activeNumber)
    }
}

/// Single-flight ownership for a bounded rebind operation. The owner is
/// attempt-scoped, while the cancellation/deadline remain with the caller;
/// no lifecycle enum is needed to prevent overlapping native operations.
final class CaptureRebindCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: SessionAttemptID?
    private var cancelledAttempts = Set<SessionAttemptID>()

    func begin(_ attempt: SessionAttemptID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owner == nil, !cancelledAttempts.contains(attempt) else { return false }
        owner = attempt
        return true
    }

    func end(_ attempt: SessionAttemptID) {
        lock.lock()
        if owner == attempt { owner = nil }
        lock.unlock()
    }

    func cancel(_ attempt: SessionAttemptID) {
        lock.lock()
        cancelledAttempts.insert(attempt)
        if owner == attempt { owner = nil }
        lock.unlock()
    }

    func canPublish(_ attempt: SessionAttemptID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return owner == attempt && !cancelledAttempts.contains(attempt)
    }

    func reset(_ attempt: SessionAttemptID) {
        lock.lock()
        cancelledAttempts.remove(attempt)
        lock.unlock()
    }
}
