import Foundation

/// An ephemeral proof that an explicit system-output consent action happened
/// for exactly one capture attempt. It deliberately has no Codable surface and
/// cannot be reconstructed from session metadata.
final class SystemOutputCaptureAuthorization: @unchecked Sendable {
    fileprivate let attempt: SessionAttemptID
    fileprivate let nonce: UUID

    fileprivate init(attempt: SessionAttemptID, nonce: UUID) {
        self.attempt = attempt
        self.nonce = nonce
    }
}

/// In-memory authority for system-output consent. The only issuer is the
/// explicit consent action in the product control-plane (and its deterministic
/// tests). A new authority is created per capture controller and nothing here
/// is persisted or shared across attempts.
final class SystemOutputCaptureAuthorizationAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var issuedNonces: [SessionAttemptID: UUID] = [:]

    func accepts(
        _ authorization: SystemOutputCaptureAuthorization?,
        for attempt: SessionAttemptID,
    ) -> Bool {
        guard let authorization else { return false }
        lock.lock()
        defer { lock.unlock() }
        return authorization.attempt == attempt
            && issuedNonces[attempt] == authorization.nonce
    }

    func invalidate(_ attempt: SessionAttemptID) {
        lock.lock()
        issuedNonces.removeValue(forKey: attempt)
        lock.unlock()
    }

    /// Issues one in-memory capability only after the caller has completed the
    /// explicit system-output consent action for this exact attempt. There is
    /// intentionally no Bool-based or persisted issuance path.
    func issueAfterExplicitUserConsent(for attempt: SessionAttemptID) -> SystemOutputCaptureAuthorization {
        let nonce = UUID()
        lock.lock()
        issuedNonces[attempt] = nonce
        lock.unlock()
        return SystemOutputCaptureAuthorization(attempt: attempt, nonce: nonce)
    }
}
