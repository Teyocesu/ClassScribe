import Foundation
import Testing
@testable import ClassScribe

@Test
func systemOutputAuthorizationIsBoundToOneAttemptAndInvalidates() {
    let authority = SystemOutputCaptureAuthorizationAuthority()
    let firstAttempt = SessionAttemptID(generation: 1)
    let secondAttempt = SessionAttemptID(generation: 2)
    let authorization = authority.issueAfterExplicitUserConsent(for: firstAttempt)

    #expect(authority.accepts(authorization, for: firstAttempt))
    #expect(!authority.accepts(authorization, for: secondAttempt))

    authority.invalidate(firstAttempt)
    #expect(!authority.accepts(authorization, for: firstAttempt))

    let replacement = authority.issueAfterExplicitUserConsent(for: firstAttempt)
    #expect(!authority.accepts(authorization, for: firstAttempt))
    #expect(authority.accepts(replacement, for: firstAttempt))
}

@MainActor
@Test
func systemOutputStartRequiresExplicitAttemptAuthorization() async throws {
    let controller = CaptureController()
    let attempt = SessionAttemptID(generation: 3)
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClassScribe-system-output-auth-(UUID().uuidString)")

    do {
        _ = try await controller.start(
            attempt: attempt,
            mode: .online,
            captureScope: .systemOutput,
            application: nil,
            microphone: nil,
            folder: folder,
        )
        Issue.record("system-output no debe iniciar sin un capability efímero")
    } catch let error as CaptureError {
        if case .systemOutputAuthorizationRequired = error {
            // Expected: the product boundary rejects before native capture.
        } else {
            Issue.record("Error inesperado: \(error.localizedDescription)")
        }
    }
}
