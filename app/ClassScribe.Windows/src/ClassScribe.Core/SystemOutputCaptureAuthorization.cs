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

/// In-memory authority for system-output consent. The only issuer is the
/// explicit consent action in the product control-plane (and its deterministic
/// tests). Nothing is persisted or shared across attempts.
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

    /// Issues one in-memory capability only after the caller has completed the
    /// explicit system-output consent action for this exact attempt. There is
    /// deliberately no Bool-based or persisted issuance path.
    internal SystemOutputCaptureAuthorization IssueAfterExplicitUserConsent(SessionAttemptID attempt)
    {
        var nonce = Guid.NewGuid();
        lock (sync)
        {
            issuedNonces[attempt] = nonce;
        }

        return SystemOutputCaptureAuthorization.Create(attempt, nonce);
    }
}
