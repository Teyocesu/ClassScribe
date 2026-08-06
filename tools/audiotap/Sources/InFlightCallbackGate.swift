import Foundation

/// Coordinates a real-time callback with lifecycle teardown.
///
/// `closeAndWait()` first rejects new callback work and then waits for callbacks
/// that already entered to leave. The writer/file can therefore be released
/// immediately after it returns without a timing delay or use-after-close race.
final class InFlightCallbackGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var accepting = false
    private var inFlight = 0

    func open() {
        condition.lock()
        accepting = true
        condition.unlock()
    }

    func enter() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard accepting else { return false }
        inFlight += 1
        return true
    }

    func leave() {
        condition.lock()
        precondition(inFlight > 0, "Unbalanced callback gate leave")
        inFlight -= 1
        if inFlight == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    func closeAndWait() {
        condition.lock()
        accepting = false
        while inFlight > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    var snapshot: (accepting: Bool, inFlight: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (accepting, inFlight)
    }
}
