@_spi(ClassScribeTests) import AudioTapLib
import Foundation
import Testing
@testable import ClassScribe

@MainActor
@Test
func nativeStartRunsOffMainActor() async throws {
    let executor = CaptureNativeExecutor()
    let attempt = SessionAttemptID(generation: 1)
    let work = executor.submit(attempt: attempt) { _ in Thread.isMainThread }

    #expect(work.attempt == attempt)
    #expect(try await work.value() == false)
}

@MainActor
@Test
func cancelReturnsWhileNativeStartStillBlocked() async throws {
    let executor = CaptureNativeExecutor()
    let attempt = SessionAttemptID(generation: 1)
    let entered = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let work = executor.submit(attempt: attempt) { _ in
        entered.signal()
        release.wait()
    }
    await entered.wait()

    work.cancel()
    do {
        _ = try await work.value()
        Issue.record("La espera cancelada no debía esperar el retorno nativo")
    } catch is CancellationError {
        // Expected: the native owner is still blocked, but the control-plane
        // waiter has returned.
    }

    release.signal()
    await work.waitForCompletion()
}

@MainActor
@Test
func cancelledAttemptCannotPublishAfterNativeReturn() async throws {
    let executor = CaptureNativeExecutor()
    let attempt = SessionAttemptID(generation: 1)
    let gate = CaptureAttemptGate()
    gate.begin(attempt)
    let entered = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let published = LockedValue(false)
    let cleaned = LockedValue(false)
    let work = executor.submit(attempt: attempt) { work in
        entered.signal()
        release.wait()
        guard !work.isCancellationRequested, gate.accepts(attempt) else {
            cleaned.set(true)
            throw CancellationError()
        }
        published.set(true)
    }
    await entered.wait()

    gate.invalidate(attempt)
    work.cancel()
    release.signal()
    await work.waitForCompletion()

    #expect(!published.get())
    #expect(cleaned.get())
}

@MainActor
@Test
func staleAResourceIsCleaned() async throws {
    let executor = CaptureNativeExecutor()
    let attempt = SessionAttemptID(generation: 1)
    let destroyed = LockedValue(false)
    let entered = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let work = executor.submit(attempt: attempt) { work in
        entered.signal()
        release.wait()
        if work.isCancellationRequested {
            destroyed.set(true)
            throw CancellationError()
        }
    }
    await entered.wait()
    work.cancel()
    release.signal()
    await work.waitForCompletion()

    #expect(destroyed.get())
}

@MainActor
@Test
func slowNativeStopDoesNotBlockMainActor() async throws {
    let executor = CaptureNativeExecutor()
    let attempt = SessionAttemptID(generation: 1)
    let entered = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let work = executor.submit(attempt: attempt) { _ in
        entered.signal()
        release.wait()
    }
    await entered.wait()

    // This statement is the control-plane continuation while the native owner
    // is still blocked on teardown.
    let controlPlaneContinued = await MainActor.run { true }
    #expect(controlPlaneContinued)

    release.signal()
    await work.waitForCompletion()
}

@MainActor
@Test
func teardownCompletionIsNotReportedEarly() async throws {
    let executor = CaptureNativeExecutor()
    let attempt = SessionAttemptID(generation: 1)
    let entered = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let completed = TestSignal()
    let work = executor.submit(attempt: attempt) { _ in
        entered.signal()
        release.wait()
    }
    await entered.wait()

    Task {
        await work.waitForCompletion()
        completed.signal()
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!completed.isSignaled)

    release.signal()
    await completed.wait()
}

@MainActor
@Test
func AToBGenerationOwnership() async throws {
    let executor = CaptureNativeExecutor()
    let attemptA = SessionAttemptID(generation: 1)
    let attemptB = SessionAttemptID(generation: 2)
    let gate = CaptureAttemptGate()
    let events = LockedValue<[String]>([])
    let entered = TestSignal()
    let release = DispatchSemaphore(value: 0)
    gate.begin(attemptA)

    let a = executor.submit(attempt: attemptA) { work in
        events.append("A setup")
        entered.signal()
        release.wait()
        guard !work.isCancellationRequested, gate.accepts(attemptA) else {
            events.append("A resource destroyed")
            throw CancellationError()
        }
        events.append("A published")
    }
    await entered.wait()

    gate.invalidate(attemptA)
    a.cancel()
    let b = executor.submit(attempt: attemptB) { work in
        guard !work.isCancellationRequested else { throw CancellationError() }
        events.append("B setup")
        guard gate.accepts(attemptB) else { throw CancellationError() }
        events.append("B published")
    }
    gate.begin(attemptB)
    release.signal()

    await a.waitForCompletion()
    await b.waitForCompletion()
    #expect(events.get() == ["A setup", "A resource destroyed", "B setup", "B published"])
}

@MainActor
@Test
func firstSampleWinsAndCancellationWaiterIsReleased() async throws {
    let cancellation = CaptureStartCancellation()

    let sampleCount = try await CaptureFirstSampleRace.wait(cancellation: cancellation) {
        1_600
    }

    #expect(sampleCount == 1_600)
    // The success path must release the losing waiter through task
    // cancellation; it must not require a later cancellation.cancel().
    #expect(!cancellation.hasActiveWaiter)
    #expect(!cancellation.isCancelled)
}

@MainActor
@Test
func cancellationWinsAndNoChildRemains() async throws {
    let cancellation = CaptureStartCancellation()
    let sampleStarted = TestSignal()
    let sampleCancelled = TestSignal()
    let raceTask = Task {
        try await CaptureFirstSampleRace.wait(cancellation: cancellation) {
            sampleStarted.signal()
            do {
                try await Task.sleep(for: .seconds(30))
                return 1
            } catch {
                sampleCancelled.signal()
                throw error
            }
        }
    }

    await sampleStarted.wait()
    cancellation.cancel()

    do {
        _ = try await raceTask.value
        Issue.record("La cancelación debía ganar la carrera")
    } catch is CancellationError {
        // Expected.
    }
    await sampleCancelled.wait()
    #expect(!cancellation.hasActiveWaiter)
    #expect(cancellation.isCancelled)
}

@MainActor
@Test
func timeoutWinsAndNoCancellationWaiterRemains() async throws {
    let cancellation = CaptureStartCancellation()
    let liveStore = LiveAudioBufferStore()

    do {
        _ = try await CaptureFirstSampleRace.wait(cancellation: cancellation) {
            try await liveStore.waitForSamples(after: 0, timeout: 0)
        }
        Issue.record("El timeout debía producir un error de audio no disponible")
    } catch {
        switch error {
        case CaptureError.applicationAudioUnavailable:
            break
        default:
            Issue.record("Error inesperado: \(error)")
        }
    }

    #expect(!cancellation.hasActiveWaiter)
    #expect(!cancellation.isCancelled)
}

@MainActor
@Test
func staleMicStartupResourceIsStoppedAndReleased() {
    let attempt = SessionAttemptID(generation: 1)
    let gate = CaptureAttemptGate()
    gate.begin(attempt)
    let resource = TestStoppableResource()
    let stopCount = LockedValue(0)
    let owner = CaptureStartupResourceOwner<TestStoppableResource> { resource in
        resource.stop()
        stopCount.set(stopCount.get() + 1)
    }

    owner.acquire(resource)
    gate.invalidate(attempt)
    #expect(!gate.accepts(attempt))
    owner.release()
    owner.release()

    #expect(owner.ownedResource == nil)
    #expect(resource.stopCount == 1)
    #expect(stopCount.get() == 1)
}

@MainActor
@Test
@available(macOS 14.2, *)
func durableMasterFailureReachesProductStopBoundaryAndPreservesEvidence() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-master-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }

    let masterURL = folder.appendingPathComponent("master.raw")
    let manifestURL = folder.appendingPathComponent("audio-manifest.json")
    guard FileManager.default.createFile(
        atPath: masterURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600],
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: masterURL)
    let writer = MasterAudioWriter(
        outputFileDescriptor: handle.fileDescriptor,
        masterURL: masterURL,
        manifestURL: manifestURL,
    )
    let session = AudioCaptureSession(
        pids: [],
        appOutputURL: masterURL,
        appManifestURL: manifestURL,
    )
    session.installMasterWriterForTesting(writer, fileHandle: handle)

    try writer.append(
        [0.1, -0.1, 0.2, -0.2],
        inputRate: 48_000,
        inputChannels: 2,
        hostTicks: 0,
        sourceGeneration: 1,
    )
    try writer.finish()
    let validMasterSize = try Data(contentsOf: masterURL).count
    let validManifest = try Data(contentsOf: manifestURL)
    try AudioManifestStore.validate(try AudioManifestStore.read(from: manifestURL))

    let injectedFailure = NSError(
        domain: "classscribe.tests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "synthetic durable master failure"],
    )
    writer.recordFailure(injectedFailure)
    let attempt = SessionAttemptID(generation: 1)
    let executor = CaptureNativeExecutor()
    await executor.installSessionForTesting(session, for: attempt)

    let snapshot = await executor.levelSnapshot(for: attempt)
    #expect(snapshot.terminalErrorMessage == "synthetic durable master failure")

    do {
        _ = try writer.append(
            [0.3, -0.3, 0.4, -0.4],
            inputRate: 48_000,
            inputChannels: 2,
            hostTicks: 0,
            sourceGeneration: 1,
        )
        Issue.record("Los callbacks posteriores no debían escribir el master")
    } catch {
        // The first durable error turns the writer into a terminal boundary.
    }
    #expect(try Data(contentsOf: masterURL).count == validMasterSize)

    let stop = executor.beginStop(attempt: attempt)
    let stopResult = try await stop.value()
    #expect(stopResult.terminalErrorMessage == "synthetic durable master failure")
    #expect(try Data(contentsOf: manifestURL) == validManifest)
    try AudioManifestStore.validate(try AudioManifestStore.read(from: manifestURL))

    let nextFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-master-failure-next-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: nextFolder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: nextFolder) }
    let nextMasterURL = nextFolder.appendingPathComponent("master.raw")
    let nextManifestURL = nextFolder.appendingPathComponent("audio-manifest.json")
    guard FileManager.default.createFile(
        atPath: nextMasterURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600],
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let nextHandle = try FileHandle(forWritingTo: nextMasterURL)
    let nextSession = AudioCaptureSession(
        pids: [],
        appOutputURL: nextMasterURL,
        appManifestURL: nextManifestURL,
    )
    nextSession.installMasterWriterForTesting(
        MasterAudioWriter(
            outputFileDescriptor: nextHandle.fileDescriptor,
            masterURL: nextMasterURL,
            manifestURL: nextManifestURL,
        ),
        fileHandle: nextHandle,
    )
    let nextAttempt = SessionAttemptID(generation: 2)
    await executor.installSessionForTesting(nextSession, for: nextAttempt)
    let nextSnapshot = await executor.levelSnapshot(for: nextAttempt)
    #expect(nextSnapshot.terminalErrorMessage == nil)
    let nextStop = executor.beginStop(attempt: nextAttempt)
    _ = try await nextStop.value()
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func append(_ element: Value.Element) where Value: RangeReplaceableCollection {
        lock.lock()
        value.append(element)
        lock.unlock()
    }
}

private final class TestStoppableResource {
    private(set) var stopCount = 0

    func stop() {
        stopCount += 1
    }
}

/// Async test-only signal. It keeps the simulated native block on the
/// executor queue while the @MainActor test remains schedulable.
private final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }

    func signal() {
        let pending: [CheckedContinuation<Void, Never>]
        lock.lock()
        signaled = true
        pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadySignaled: Bool
            lock.lock()
            if signaled {
                alreadySignaled = true
            } else {
                alreadySignaled = false
                waiters.append(continuation)
            }
            lock.unlock()
            if alreadySignaled {
                continuation.resume()
            }
        }
    }
}
