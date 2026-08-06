import Foundation

/// Lock-protected capture facts shared by the audio callback and the main actor.
/// The callback only marks completed writes; it never performs timer or file work.
final class MicFirstBufferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedFrames = 0
    private var callbacks = 0

    func reset() {
        lock.lock()
        receivedFrames = 0
        callbacks = 0
        lock.unlock()
    }

    func recordWrittenFrames(_ frames: Int) -> Bool {
        lock.lock()
        callbacks += 1
        let wasEmpty = receivedFrames == 0
        receivedFrames += max(0, frames)
        lock.unlock()
        return wasEmpty && frames > 0
    }

    var hasWrittenFrames: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedFrames > 0
    }

    var snapshot: (callbacks: Int, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (callbacks, receivedFrames)
    }
}
