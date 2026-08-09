import Foundation

/// Invalidates delayed capture work when the owning session stops.
///
/// CoreAudio route changes schedule retries on the main queue. Cancelling a
/// recording does not cancel blocks already enqueued there, so each retry must
/// carry the generation that requested it. A stale generation can never
/// restart hardware after `cancel()` or after a later reuse of the object.
final class CaptureLifecycleGate: @unchecked Sendable {
    private struct State {
        var generation: UInt64 = 0
        var active = false
    }

    private let lock = NSLock()
    private var state = State()

    /// Starts a new lifecycle, or returns nil when this instance is already in
    /// use. Capture objects are intentionally single-flight.
    func begin() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !state.active else { return nil }
        state.generation &+= 1
        state.active = true
        return state.generation
    }

    /// Ends `generation` only if it is still current. A late failure from an
    /// old generation therefore cannot cancel a newer start.
    func end(_ generation: UInt64) {
        lock.lock()
        if state.active, state.generation == generation {
            state.active = false
        }
        lock.unlock()
    }

    /// Invalidates the current generation and every delayed block carrying it.
    func cancel() {
        lock.lock()
        state.generation &+= 1
        state.active = false
        lock.unlock()
    }

    func isActive(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.active && state.generation == generation
    }

    var activeGeneration: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return state.active ? state.generation : nil
    }
}
