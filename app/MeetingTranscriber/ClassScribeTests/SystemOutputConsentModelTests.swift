import Foundation
import Testing
@testable import ClassScribe

@MainActor
@Test
func systemOutputCanStartWithoutAnApplicationAndShowsConsentState() async throws {
    let model = makeConsentModel { request in
        throw ConsentModelTestError.rejected(request.captureScope)
    }
    defer { removeConsentRoot(model.storeRoot) }

    model.subject = "Álgebra"
    model.onlineCaptureSource = .systemOutput
    #expect(model.canStart)

    await model.startClass()

    let request = try #require(model.pendingSystemOutputConsent)
    #expect(request.source == .systemOutput)
    #expect(request.attempt.generation == 1)
    #expect(!model.capture.isCapturing)
}

@MainActor
@Test
func cancellingSystemOutputConsentNeverStartsCapture() async throws {
    var starts = 0
    let model = makeConsentModel { _ in
        starts += 1
        throw ConsentModelTestError.rejected(.systemOutput)
    }
    defer { removeConsentRoot(model.storeRoot) }

    model.subject = "Álgebra"
    model.onlineCaptureSource = .systemOutput
    await model.startClass()
    let request = try #require(model.pendingSystemOutputConsent)

    model.cancelSystemOutputConsent(request)
    await model.confirmSystemOutputConsent(request)

    #expect(starts == 0)
    #expect(model.pendingSystemOutputConsent == nil)
    #expect(!model.capture.isCapturing)
    #expect(model.storeSessionCount == 0)
}

@MainActor
@Test
func confirmedSystemOutputConsentPassesCapabilityForExactAttemptAndMetadata() async throws {
    var requests: [CaptureStartRequest] = []
    let model = makeConsentModel { request in
        requests.append(request)
        throw ConsentModelTestError.rejected(request.captureScope)
    }
    defer { removeConsentRoot(model.storeRoot) }

    model.subject = "Álgebra"
    model.onlineCaptureSource = .systemOutput
    await model.startClass()
    let request = try #require(model.pendingSystemOutputConsent)
    await model.confirmSystemOutputConsent(request)

    let start = try #require(requests.first)
    #expect(start.attempt == request.attempt)
    #expect(start.mode == .online)
    #expect(start.captureScope == .systemOutput)
    #expect(start.application == nil)
    #expect(start.microphone == nil)
    #expect(start.systemOutputAuthorization != nil)
    #expect(model.pendingSystemOutputConsent == nil)
    let summary = try #require(model.storeHistory.first)
    #expect(summary.metadata.mode == .online)
    #expect(summary.metadata.captureScope == .systemOutput)
    #expect(summary.metadata.source == "Audio del equipo")
}

@MainActor
@Test
func changingSourceWhileConsentIsVisibleInvalidatesTheStaleConfirmation() async throws {
    var starts = 0
    let model = makeConsentModel { _ in
        starts += 1
        throw ConsentModelTestError.rejected(.systemOutput)
    }
    defer { removeConsentRoot(model.storeRoot) }

    model.subject = "Álgebra"
    model.onlineCaptureSource = .systemOutput
    await model.startClass()
    let request = try #require(model.pendingSystemOutputConsent)

    model.onlineCaptureSource = .application
    await model.confirmSystemOutputConsent(request)

    #expect(starts == 0)
    #expect(model.pendingSystemOutputConsent == nil)
    #expect(!model.capture.isCapturing)
}

@MainActor
@Test
func changingModeWhileConsentIsVisibleInvalidatesTheStaleConfirmation() async throws {
    var starts = 0
    let model = makeConsentModel { _ in
        starts += 1
        throw ConsentModelTestError.rejected(.systemOutput)
    }
    defer { removeConsentRoot(model.storeRoot) }

    model.subject = "Álgebra"
    model.onlineCaptureSource = .systemOutput
    await model.startClass()
    let request = try #require(model.pendingSystemOutputConsent)

    model.mode = .inPerson
    await model.confirmSystemOutputConsent(request)

    #expect(starts == 0)
    #expect(model.pendingSystemOutputConsent == nil)
    #expect(!model.capture.isCapturing)
}

@MainActor
@Test
func applicationFailureDoesNotAutoSwitchAndCtaOnlyChangesNextSource() async throws {
    let model = makeConsentModel { _ in
        throw CaptureError.applicationAudioUnavailable
    }
    defer { removeConsentRoot(model.storeRoot) }

    model.subject = "Álgebra"
    model.mode = .online
    model.onlineCaptureSource = .application
    let application = RunningApplication(
        identity: ApplicationIdentity(bundleIdentifier: "com.example.application"),
        name: "Synthetic app",
        processID: 1234,
    )
    model.capture.setSourcesForTesting(applications: [application], microphones: [])
    model.selectedApplicationIdentityID = application.logicalIdentityID
    await model.startClass()

    #expect(model.onlineCaptureSource == .application)
    #expect(model.captureRecoverySuggestion == .systemOutput)
    #expect(model.canSelectSystemOutputAfterApplicationFailure)
    #expect(!model.capture.isCapturing)

    model.selectSystemOutputAfterApplicationFailure()

    #expect(model.onlineCaptureSource == .systemOutput)
    #expect(!model.canSelectSystemOutputAfterApplicationFailure)
    #expect(!model.capture.isCapturing)
}

@MainActor
private func makeConsentModel(
    captureStart: @escaping CaptureStartOverride,
) -> ConsentModelFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClassScribe-system-output-consent-\(UUID().uuidString)", isDirectory: true)
    let store = SessionStore(root: root)
    let model = ClassScribeModel(
        store: store,
        captureStartOverride: captureStart,
    )
    return ConsentModelFixture(model: model, store: store, root: root)
}

@MainActor
private final class ConsentModelFixture {
    let model: ClassScribeModel
    let store: SessionStore
    let storeRoot: URL

    init(model: ClassScribeModel, store: SessionStore, root: URL) {
        self.model = model
        self.store = store
        storeRoot = root
    }

    var storeHistory: [SessionSummary] { store.history() }

    var storeSessionCount: Int { store.history().count }
}

@MainActor
private extension ConsentModelFixture {
    var canStart: Bool { model.canStart }
    var pendingSystemOutputConsent: SystemOutputConsentRequest? { model.pendingSystemOutputConsent }
    var capture: CaptureController { model.capture }
    var subject: String {
        get { model.subject }
        set { model.subject = newValue }
    }
    var onlineCaptureSource: OnlineCaptureSource {
        get { model.onlineCaptureSource }
        set { model.onlineCaptureSource = newValue }
    }
    var mode: CaptureMode {
        get { model.mode }
        set { model.mode = newValue }
    }
    var selectedApplicationIdentityID: String? {
        get { model.selectedApplicationIdentityID }
        set { model.selectedApplicationIdentityID = newValue }
    }
    var captureRecoverySuggestion: CaptureRecoverySuggestion? { model.captureRecoverySuggestion }
    var canSelectSystemOutputAfterApplicationFailure: Bool {
        model.canSelectSystemOutputAfterApplicationFailure
    }
    func startClass() async { await model.startClass() }
    func cancelSystemOutputConsent(_ request: SystemOutputConsentRequest) {
        model.cancelSystemOutputConsent(request)
    }
    func confirmSystemOutputConsent(_ request: SystemOutputConsentRequest) async {
        await model.confirmSystemOutputConsent(request)
    }
    func selectSystemOutputAfterApplicationFailure() {
        model.selectSystemOutputAfterApplicationFailure()
    }
}

private enum ConsentModelTestError: Error {
    case rejected(CaptureScope)
}

private func removeConsentRoot(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
}
