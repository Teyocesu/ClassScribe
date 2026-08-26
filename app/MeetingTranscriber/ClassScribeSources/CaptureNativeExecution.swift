import AudioTapLib
import Darwin
import Foundation

/// A wait handle for one native operation. `cancel()` only cancels the caller's
/// wait and marks the operation stale; it never pretends to interrupt a
/// synchronous CoreAudio/AVAudioEngine call. The serial owner remains alive
/// until the operation returns and performs its cleanup.
final class CaptureNativeWork<Value: Sendable>: @unchecked Sendable {
    let attempt: SessionAttemptID

    private let lock = NSLock()
    private var cancellationRequested = false
    private var result: Result<Value, Error>?
    private var valueContinuation: CheckedContinuation<Value, Error>?
    private var completionContinuations: [CheckedContinuation<Void, Never>] = []

    init(attempt: SessionAttemptID) {
        self.attempt = attempt
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    func cancel() {
        let continuation: CheckedContinuation<Value, Error>?
        lock.lock()
        cancellationRequested = true
        continuation = valueContinuation
        valueContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let outcome: Result<Value, Error>?
                let cancelled: Bool
                lock.lock()
                if let result {
                    outcome = result
                    cancelled = false
                } else if cancellationRequested {
                    outcome = nil
                    cancelled = true
                } else {
                    outcome = nil
                    cancelled = false
                    valueContinuation = continuation
                }
                lock.unlock()

                if let outcome {
                    continuation.resume(with: outcome)
                } else if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel()
        }
    }

    /// Teardown callers use this wait, rather than `value()`, so cancellation
    /// of a UI task cannot abandon native cleanup halfway through.
    func waitForCompletion() async {
        await withCheckedContinuation { continuation in
            let completed: Bool
            lock.lock()
            if result != nil {
                completed = true
            } else {
                completed = false
                completionContinuations.append(continuation)
            }
            lock.unlock()
            if completed {
                continuation.resume()
            }
        }
    }

    fileprivate func resolve(_ result: Result<Value, Error>) {
        let value: CheckedContinuation<Value, Error>?
        let completions: [CheckedContinuation<Void, Never>]
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        value = valueContinuation
        valueContinuation = nil
        completions = completionContinuations
        completionContinuations.removeAll(keepingCapacity: false)
        lock.unlock()
        value?.resume(with: result)
        completions.forEach { $0.resume() }
    }
}

/// Thread-safe generation gate used by the audio sink before it enqueues a
/// callback. It is separate from the MainActor model gate because the sink is
/// called by CoreAudio/AVAudioEngine threads.
final class CaptureAttemptGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeAttempt: SessionAttemptID?

    func begin(_ attempt: SessionAttemptID) {
        lock.lock()
        activeAttempt = attempt
        lock.unlock()
    }

    func invalidate(_ attempt: SessionAttemptID) {
        lock.lock()
        if activeAttempt == attempt {
            activeAttempt = nil
        }
        lock.unlock()
    }

    func accepts(_ attempt: SessionAttemptID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeAttempt == attempt
    }
}

/// Cancellation source owned by one startup attempt. It lets the MainActor
/// control plane wake the first-frame wait without cancelling or pretending to
/// interrupt the native operation that is owned by `CaptureNativeExecutor`.
final class CaptureStartCancellation: @unchecked Sendable {
    private final class WaitRegistration: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func install(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func finish() {
            let continuation: CheckedContinuation<Void, Never>?
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private let lock = NSLock()
    private var cancelled = false
    private var waiter: WaitRegistration?

    /// Internal lifecycle visibility for the focused first-sample tests. A
    /// task-cancellation wake removes the waiter without changing `cancelled`.
    var hasActiveWaiter: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiter != nil
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        let waiting: WaitRegistration?
        lock.lock()
        cancelled = true
        waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.finish()
    }

    func wait() async {
        let registration = WaitRegistration()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if !registration.install(continuation) {
                    continuation.resume()
                }

                let registrationWasFinished = registration.isFinished
                let shouldFinish: Bool
                lock.lock()
                if cancelled || registrationWasFinished {
                    shouldFinish = true
                } else {
                    shouldFinish = false
                    waiter = registration
                }
                lock.unlock()
                if shouldFinish {
                    registration.finish()
                } else if registration.isFinished {
                    // Cancellation may have run between the registration
                    // check and storing the waiter. Remove that already
                    // completed registration so the source never retains a
                    // loser that has no continuation left.
                    unregister(registration)
                }
            }
        } onCancel: {
            // This is deliberately a waiter-only wake. A losing task-group
            // child must not mark the attempt's external cancellation source
            // as cancelled merely because another child won the race.
            registration.finish()
            unregister(registration)
        }
        unregister(registration)
    }

    private func unregister(_ registration: WaitRegistration) {
        lock.lock()
        if waiter === registration {
            waiter = nil
        }
        lock.unlock()
    }
}

/// Structured race used by application startup. `sampleWait` owns the bounded
/// first-callback timeout and is required to cooperate with task cancellation;
/// `LiveAudioBufferStore.waitForCallbacks` does so via `Task.checkCancellation`
/// and cancellable `Task.sleep`.
enum CaptureFirstSampleRace {
    static func wait(
        cancellation: CaptureStartCancellation,
        sampleWait: @escaping @Sendable () async throws -> Int64?,
    ) async throws -> Int64 {
        try await withThrowingTaskGroup(of: Int64?.self) { group in
            group.addTask {
                try await sampleWait()
            }
            group.addTask {
                await cancellation.wait()
                try Task.checkCancellation()
                throw CancellationError()
            }
            defer { group.cancelAll() }

            guard let result = try await group.next() ?? nil else {
                throw CaptureError.applicationAudioUnavailable
            }
            return result
        }
    }
}

struct CaptureNativeLevelSnapshot: Sendable {
    let levelDBFS: Double
    let terminalFailure: CaptureNativeTerminalFailure?

    /// Compatibility projection for focused tests and display-only callers.
    var terminalErrorMessage: String? {
        terminalFailure?.message
    }
}

struct CaptureNativeStopResult: Sendable {
    let terminalFailure: CaptureNativeTerminalFailure?

    /// Compatibility projection for focused tests and display-only callers.
    var terminalErrorMessage: String? {
        terminalFailure?.message
    }
}

/// Product seam for the online mid-recording handoff. The default adapter
/// delegates to the serial native executor; lifecycle tests can inject a
/// deterministic implementation without constructing CoreAudio objects.
protocol CaptureApplicationRebindDriver: AnyObject, Sendable {
    func stopApplicationSource(
        attempt: SessionAttemptID,
        sourceGeneration: CaptureSourceGeneration,
    ) async throws

    func startApplicationSource(
        attempt: SessionAttemptID,
        sourceGeneration: CaptureSourceGeneration,
        rootPID: pid_t,
        pids: [pid_t],
        registrationTimeout: TimeInterval,
        liveSink: @escaping LiveAudioSink,
        sourceCallbackGate: @escaping @Sendable () -> Bool,
    ) async throws
}

final class CaptureNativeRebindDriver: CaptureApplicationRebindDriver, @unchecked Sendable {
    private let executor: CaptureNativeExecutor

    init(executor: CaptureNativeExecutor) {
        self.executor = executor
    }

    func stopApplicationSource(
        attempt: SessionAttemptID,
        sourceGeneration: CaptureSourceGeneration,
    ) async throws {
        try await executor.beginApplicationSourceStop(
            attempt: attempt,
            sourceGeneration: sourceGeneration,
        ).value()
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
        try await executor.beginApplicationRebind(
            attempt: attempt,
            sourceGeneration: sourceGeneration,
            rootPID: rootPID,
            pids: pids,
            registrationTimeout: registrationTimeout,
            liveSink: liveSink,
            sourceCallbackGate: sourceCallbackGate,
        ).value()
    }
}

/// Owns native CATap capture objects on one dedicated serial queue. A
/// slow native call can occupy this queue, but it cannot occupy MainActor. A
/// second attempt is intentionally queued behind the first attempt's native
/// cleanup; taps are never overlapped accidentally.
final class CaptureNativeExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "classscribe.capture.native",
        qos: .userInitiated,
    )
    private var captureSessions: [SessionAttemptID: AudioCaptureSession] = [:]
    private let systemOutputAuthorizationAuthority: SystemOutputCaptureAuthorizationAuthority

    init(
        systemOutputAuthorizationAuthority: SystemOutputCaptureAuthorizationAuthority = SystemOutputCaptureAuthorizationAuthority(),
    ) {
        self.systemOutputAuthorizationAuthority = systemOutputAuthorizationAuthority
    }

    /// Small injectable boundary used by deterministic lifecycle tests. The
    /// production closures below use the same queue and ownership contract.
    func submit<Value: Sendable>(
        attempt: SessionAttemptID,
        _ operation: @escaping @Sendable (CaptureNativeWork<Value>) throws -> Value,
    ) -> CaptureNativeWork<Value> {
        let work = CaptureNativeWork<Value>(attempt: attempt)
        queue.async {
            do {
                guard !work.isCancellationRequested else {
                    throw CancellationError()
                }
                let value = try operation(work)
                if work.isCancellationRequested {
                    throw CancellationError()
                }
                work.resolve(.success(value))
            } catch {
                work.resolve(.failure(error))
            }
        }
        return work
    }

    func beginApplicationStart(
        attempt: SessionAttemptID,
        sourceGeneration: CaptureSourceGeneration,
        rootPID: pid_t,
        pids: [pid_t],
        outputURL: URL,
        manifestURL: URL? = nil,
        registrationTimeout: TimeInterval,
        liveSink: @escaping LiveAudioSink,
        sourceCallbackGate: @escaping @Sendable () -> Bool,
    ) -> CaptureNativeWork<Void> {
        submit(attempt: attempt) { [self] work in
            guard sourceGeneration.attempt == attempt else {
                throw CancellationError()
            }
            let deadline = DispatchTime.now().uptimeNanoseconds
                + UInt64(max(0, registrationTimeout) * 1_000_000_000)
            while !work.isCancellationRequested {
                if AppAudioCapture.hasRegisteredAudioProcess(in: pids) {
                    break
                }
                guard Self.processIsRunning(rootPID) else {
                    throw CaptureError.noProcesses
                }
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw CaptureError.applicationAudioUnavailable
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            try Self.checkCancellation(work)

            let session = AudioCaptureSession(
                pids: pids,
                appOutputURL: outputURL,
                appManifestURL: manifestURL,
                micOutputURL: nil,
                appLiveSink: liveSink,
                appCallbackGate: sourceCallbackGate,
            )
            do {
                try session.start()
            } catch {
                throw error
            }
            if work.isCancellationRequested {
                _ = session.stop()
                throw CancellationError()
            }
            captureSessions[attempt] = session
            if work.isCancellationRequested {
                _ = captureSessions.removeValue(forKey: attempt)?.stop()
                throw CancellationError()
            }
        }
    }

    /// Starts a global CATap source only after the attempt-bound capability is
    /// accepted on the native queue. The exclusion list is derived from the
    /// running product process and validated PID↔AudioObjectID round trips;
    /// no application process list is used for the global source.
    func beginSystemOutputStart(
        attempt: SessionAttemptID,
        sourceGeneration: CaptureSourceGeneration,
        authorization: SystemOutputCaptureAuthorization?,
        outputURL: URL,
        manifestURL: URL? = nil,
        liveSink: @escaping LiveAudioSink,
        sourceCallbackGate: @escaping @Sendable () -> Bool,
    ) -> CaptureNativeWork<Void> {
        submit(attempt: attempt) { [self] work in
            guard sourceGeneration.attempt == attempt,
                  systemOutputAuthorizationAuthority.accepts(authorization, for: attempt)
            else {
                throw CaptureError.systemOutputAuthorizationRequired
            }
            try Self.checkCancellation(work)

            let session = AudioCaptureSession(
                source: .systemOutput,
                appOutputURL: outputURL,
                appManifestURL: manifestURL,
                micOutputURL: nil,
                appLiveSink: liveSink,
                appCallbackGate: sourceCallbackGate,
            )
            do {
                try session.start()
            } catch {
                throw error
            }
            guard !work.isCancellationRequested,
                  systemOutputAuthorizationAuthority.accepts(authorization, for: attempt)
            else {
                _ = session.stop()
                throw CancellationError()
            }
            captureSessions[attempt] = session
            guard !work.isCancellationRequested,
                  systemOutputAuthorizationAuthority.accepts(authorization, for: attempt)
            else {
                _ = captureSessions.removeValue(forKey: attempt)?.stop()
                throw CancellationError()
            }
        }
    }

    /// Stops the current CATap generation while retaining the session-owned
    /// `source.raw` descriptor and timeline. The serial queue guarantees that
    /// the old IOProc is fully drained before a rebind build can begin.
    func beginApplicationSourceStop(
        attempt: SessionAttemptID,
        sourceGeneration: CaptureSourceGeneration,
    ) -> CaptureNativeWork<Void> {
        submit(attempt: attempt) { [self] work in
            guard sourceGeneration.attempt == attempt,
                  captureSessions[attempt] != nil else {
                throw CancellationError()
            }
            try Self.checkCancellation(work)
            captureSessions[attempt]?.stopApplicationCapture()
        }
    }

    /// Builds the next CATap generation against the already-open session file.
    /// Registration is revalidated immediately before native construction and
    /// cancellation after construction stops the new generation without
    /// publishing it to the session owner.
    func beginApplicationRebind(
        attempt: SessionAttemptID,
        sourceGeneration: CaptureSourceGeneration,
        rootPID: pid_t,
        pids: [pid_t],
        registrationTimeout: TimeInterval,
        liveSink: @escaping LiveAudioSink,
        sourceCallbackGate: @escaping @Sendable () -> Bool,
    ) -> CaptureNativeWork<Void> {
        submit(attempt: attempt) { [self] work in
            guard sourceGeneration.attempt == attempt,
                  let session = captureSessions[attempt] else {
                throw CancellationError()
            }
            let deadline = DispatchTime.now().uptimeNanoseconds
                + UInt64(max(0, registrationTimeout) * 1_000_000_000)
            while !work.isCancellationRequested {
                if AppAudioCapture.hasRegisteredAudioProcess(in: pids) {
                    break
                }
                guard Self.processIsRunning(rootPID) else {
                    throw CaptureError.noProcesses
                }
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw CaptureError.applicationAudioUnavailable
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            try Self.checkCancellation(work)
            do {
                try session.replaceApplicationCapture(
                    pids: pids,
                    liveSink: liveSink,
                    callbackGate: sourceCallbackGate,
                )
            } catch {
                throw error
            }
            if work.isCancellationRequested {
                session.stopApplicationCapture()
                throw CancellationError()
            }
        }
    }

    func beginStop(attempt: SessionAttemptID) -> CaptureNativeWork<CaptureNativeStopResult> {
        submit(attempt: attempt) { [self] _ in
            guard let session = captureSessions.removeValue(forKey: attempt) else {
                return CaptureNativeStopResult(terminalFailure: nil)
            }
            _ = session.stop()
            return CaptureNativeStopResult(
                terminalFailure: session.appTerminalFailure,
            )
        }
    }

    /// Product-test seam that installs a real session owner on the same serial
    /// executor used by CATap. It avoids constructing CoreAudio objects while
    /// preserving the level-snapshot and stop ownership path.
    func installSessionForTesting(
        _ session: AudioCaptureSession,
        for attempt: SessionAttemptID,
    ) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                captureSessions[attempt] = session
                continuation.resume()
            }
        }
    }

    func levelSnapshot(for attempt: SessionAttemptID) async -> CaptureNativeLevelSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let session = captureSessions[attempt] {
                    continuation.resume(returning: CaptureNativeLevelSnapshot(
                        levelDBFS: session.appLevelDBFS,
                        terminalFailure: session.appTerminalFailure,
                    ))
                    return
                }
                continuation.resume(returning: CaptureNativeLevelSnapshot(
                    levelDBFS: -120,
                    terminalFailure: nil,
                ))
            }
        }
    }

    private static func checkCancellation<Value>(_ work: CaptureNativeWork<Value>) throws {
        if work.isCancellationRequested {
            throw CancellationError()
        }
    }

    private static func processIsRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
