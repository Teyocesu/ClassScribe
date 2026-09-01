@testable import ClassScribe
import Foundation
import Testing

private actor StartupEventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor StartupPreflightGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func wait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum StartupPreflightTestError: Error {
    case preflightFailed
    case captureFailed
}

@MainActor
@Test
func asrPreflightCompletesBeforeCaptureStartIsInvoked() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-startup-preflight-order-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let events = StartupEventRecorder()
    let model = ClassScribeModel(
        store: SessionStore(root: root),
        captureStartOverride: { _ in
            await events.append("capture")
            throw StartupPreflightTestError.captureFailed
        },
        asrPreflight: {
            await events.append("preflight")
        },
    )
    configureApplicationSource(for: model)

    model.subject = "Álgebra"
    await model.startClass()

    #expect(await events.snapshot() == ["preflight", "capture"])
    #expect(!model.capture.isCapturing)
    #expect(model.state == .failed)
    #expect(!model.isStarting)
}

@MainActor
@Test
func failedAsrPreflightDoesNotStartCapture() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-startup-preflight-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var captureStarts = 0
    let model = ClassScribeModel(
        store: SessionStore(root: root),
        captureStartOverride: { _ in
            captureStarts += 1
            throw StartupPreflightTestError.captureFailed
        },
        asrPreflight: {
            throw StartupPreflightTestError.preflightFailed
        },
    )
    configureApplicationSource(for: model)

    model.subject = "Álgebra"
    await model.startClass()

    #expect(captureStarts == 0)
    #expect(!model.capture.isCapturing)
    #expect(model.state == .failed)
    #expect(model.sessionPhase == .failed)
    #expect(model.asrPhase == .failedRecoverable)
    #expect(model.statusDetail.contains("No se pudo preparar la transcripción antes de grabar"))
    #expect(!model.isStarting)
}

@MainActor
@Test
func cancellingDuringAsrPreflightDoesNotStartCapture() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-startup-preflight-cancel-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let gate = StartupPreflightGate()
    var captureStarts = 0
    let model = ClassScribeModel(
        store: SessionStore(root: root),
        captureStartOverride: { request in
            captureStarts += 1
            return request.folder.appendingPathComponent("source.wav")
        },
        asrPreflight: {
            await gate.wait()
        },
    )
    configureApplicationSource(for: model)

    model.subject = "Álgebra"
    let startTask = Task { @MainActor in
        await model.startClass()
    }
    await gate.waitUntilEntered()
    #expect(model.isStarting)

    model.cancelStart()
    #expect(model.state == .cancelled)
    await gate.release()
    await startTask.value

    #expect(captureStarts == 0)
    #expect(!model.capture.isCapturing)
    #expect(model.capturePhase == .idle)
    #expect(!model.isStarting)
}

@MainActor
private func configureApplicationSource(for model: ClassScribeModel) {
    let application = RunningApplication(
        identity: ApplicationIdentity(bundleIdentifier: "com.example.source"),
        name: "Synthetic source",
        processID: 1234,
    )
    model.capture.setSourcesForTesting(applications: [application], microphones: [])
    model.selectedApplicationIdentityID = application.logicalIdentityID
}
