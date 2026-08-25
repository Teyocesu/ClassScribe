using System;
using System.Collections.Generic;

namespace ClassScribe.Core;

/// Ephemeral proof that an explicit system-output consent action occurred for
/// one exact capture attempt. It is intentionally not serializable and cannot
/// be rebuilt from session metadata.
public sealed class SystemOutputCaptureAuthorization
{
    internal SessionAttemptID Attempt { get; }

    internal Guid Nonce { get; }

    private SystemOutputCaptureAuthorization(SessionAttemptID attempt, Guid nonce)
    {
        Attempt = attempt;
        Nonce = nonce;
    }

    internal static SystemOutputCaptureAuthorization Create(
        SessionAttemptID attempt,
        Guid nonce) => new(attempt, nonce);
}

/// In-memory authority for system-output consent. 2C.1 exposes only an
/// internal deterministic issuance seam; 2C.2 will call the same authority
/// after its real consent modal. Nothing is persisted or shared across
/// attempts.
public sealed class SystemOutputCaptureAuthorizationAuthority
{
    private readonly object sync = new();
    private readonly Dictionary<SessionAttemptID, Guid> issuedNonces = [];

    public bool Accepts(
        SystemOutputCaptureAuthorization? authorization,
        SessionAttemptID attempt)
    {
        if (authorization is null)
        {
            return false;
        }

        lock (sync)
        {
            return authorization.Attempt == attempt
                && issuedNonces.TryGetValue(attempt, out var nonce)
                && nonce == authorization.Nonce;
        }
    }

    public void Invalidate(SessionAttemptID attempt)
    {
        lock (sync)
        {
            issuedNonces.Remove(attempt);
        }
    }

    /// Internal-only seam for deterministic tests and the 2C.2 consent layer.
    /// There is deliberately no Bool-based or persisted issuance path.
    internal SystemOutputCaptureAuthorization IssueForTesting(SessionAttemptID attempt)
    {
        var nonce = Guid.NewGuid();
        lock (sync)
        {
            issuedNonces[attempt] = nonce;
        }

        return SystemOutputCaptureAuthorization.Create(attempt, nonce);
    }
}
