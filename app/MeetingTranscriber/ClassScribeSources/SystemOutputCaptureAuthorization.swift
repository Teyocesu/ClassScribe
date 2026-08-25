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

/// In-memory authority for system-output consent. The only issuer in 2C.1 is
/// the focused/test seam; 2C.2 will replace that seam with the real consent
/// modal. A new authority is created per capture controller and nothing here
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

    /// Internal-only seam for deterministic tests and the 2C.2 consent layer.
    /// There is intentionally no Bool-based or persisted issuance path.
    func issueForTesting(for attempt: SessionAttemptID) -> SystemOutputCaptureAuthorization {
        let nonce = UUID()
        lock.lock()
        issuedNonces[attempt] = nonce
        lock.unlock()
        return SystemOutputCaptureAuthorization(attempt: attempt, nonce: nonce)
    }
}
