import CoreAudio
import Foundation
import Testing
@_spi(ClassScribeTests) import AudioTapLib

@available(macOS 14.2, *)
@Test
func outputDeviceRestartAndUserStopAreSerialized() async {
    let capture = AppAudioCapture(pids: [], outputFileDescriptor: -1)
    let probe = LifecycleProbe()
    let entered = AsyncSignal()
    let release = DispatchSemaphore(value: 0)

    let restart = Task {
        await capture.performLifecycleOperationForTesting {
            probe.enter("restart")
            entered.signal()
            release.wait()
            probe.leave()
        }
    }
    await entered.wait()

    let stop = Task {
        await capture.performLifecycleOperationForTesting {
            probe.enter("stop")
            probe.leave()
        }
    }

    try? await Task.sleep(for: .milliseconds(50))
    #expect(probe.events == ["restart-enter"])
    #expect(!probe.overlapped)

    release.signal()
    await restart.value
    await stop.value

    #expect(probe.events == ["restart-enter", "restart-exit", "stop-enter", "stop-exit"])
    #expect(!probe.overlapped)
}

@available(macOS 14.2, *)
@Test
func globalTapRevalidatesSelfExclusionsOnRestart() {
    let beforeRestart = AppAudioCapture.validatedSystemOutputObjectIDs(
        in: [101, 202],
        translate: { pid in [101: AudioObjectID(7), 202: AudioObjectID(9)][pid] },
        roundTrip: { _, _ in true },
    )
    let afterHelperAppeared = AppAudioCapture.validatedSystemOutputObjectIDs(
        in: [101, 202, 303],
        translate: { pid in
            [101: AudioObjectID(7), 202: AudioObjectID(9), 303: AudioObjectID(11)][pid]
        },
        roundTrip: { _, _ in true },
    )

    #expect(beforeRestart == [7, 9])
    #expect(afterHelperAppeared == [7, 9, 11])
    #expect(!beforeRestart.contains(11))
}

@available(macOS 14.2, *)
@Test
func invalidSelfTranslationProducesNoSyntheticObject() {
    let exclusions = AppAudioCapture.validatedSystemOutputObjectIDs(
        in: [101, 202],
        translate: { pid in pid == 101 ? AudioObjectID(kAudioObjectUnknown) : nil },
        roundTrip: { _, _ in true },
    )

    #expect(exclusions.isEmpty)
}

private final class LifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []
    private(set) var overlapped = false
    private var active = false

    func enter(_ operation: String) {
        lock.lock()
        if active {
            overlapped = true
        }
        active = true
        events.append("\(operation)-enter")
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active = false
        events.append("\(events.last?.split(separator: "-").first ?? "operation")-exit")
        lock.unlock()
    }
}

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        signaled = true
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
