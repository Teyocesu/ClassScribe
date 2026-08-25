namespace ClassScribe.Core;

/// Runtime-only identity for one native source incarnation inside an attempt.
/// It is not a persisted application identity and cannot cross attempts.
public sealed record CaptureSourceGeneration(
    SessionAttemptID Attempt,
    long Number)
{
    public string Token => $"{Attempt.Token}:source-{Number}";
}

/// Thread-safe callback/publication gate separate from SessionAttemptID.
public sealed class CaptureSourceGenerationGate
{
    private readonly object sync = new();
    private SessionAttemptID? activeAttempt;
    private long activeNumber;

    public CaptureSourceGeneration Begin(SessionAttemptID attempt)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        lock (sync)
        {
            activeAttempt = attempt;
            activeNumber = 1;
            return new CaptureSourceGeneration(attempt, activeNumber);
        }
    }

    public CaptureSourceGeneration? Advance(SessionAttemptID attempt)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        lock (sync)
        {
            if (activeAttempt != attempt)
            {
                return null;
            }

            checked { activeNumber++; }
            return new CaptureSourceGeneration(attempt, activeNumber);
        }
    }

    public bool Accepts(SessionAttemptID attempt, CaptureSourceGeneration generation)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        ArgumentNullException.ThrowIfNull(generation);
        lock (sync)
        {
            return activeAttempt == attempt
                && generation.Attempt == attempt
                && generation.Number == activeNumber;
        }
    }

    public void Invalidate(SessionAttemptID attempt)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        lock (sync)
        {
            if (activeAttempt == attempt)
            {
                activeAttempt = null;
                activeNumber = 0;
            }
        }
    }

    public CaptureSourceGeneration? Current
    {
        get
        {
            lock (sync)
            {
                return activeAttempt is null
                    ? null
                    : new CaptureSourceGeneration(activeAttempt, activeNumber);
            }
        }
    }
}

/// Attempt-scoped single-flight ownership. Cancellation and deadline remain
/// owned by the caller; this class only prevents overlapping rebinds and
/// rejects completion publication after Stop/session replacement.
public sealed class CaptureRebindCoordinator
{
    private readonly object sync = new();
    private SessionAttemptID? owner;
    private readonly HashSet<SessionAttemptID> cancelledAttempts = [];

    public bool Begin(SessionAttemptID attempt)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        lock (sync)
        {
            if (owner is not null || cancelledAttempts.Contains(attempt))
            {
                return false;
            }

            owner = attempt;
            return true;
        }
    }

    public void End(SessionAttemptID attempt)
    {
        lock (sync)
        {
            if (owner == attempt)
            {
                owner = null;
            }
        }
    }

    public void Cancel(SessionAttemptID attempt)
    {
        lock (sync)
        {
            cancelledAttempts.Add(attempt);
            if (owner == attempt)
            {
                owner = null;
            }
        }
    }

    public bool CanPublish(SessionAttemptID attempt)
    {
        lock (sync)
        {
            return owner == attempt && !cancelledAttempts.Contains(attempt);
        }
    }

    public void Reset(SessionAttemptID attempt)
    {
        lock (sync)
        {
            cancelledAttempts.Remove(attempt);
        }
    }
}
