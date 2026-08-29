namespace ClassScribe.Core;

public enum ApplicationSourceLivenessState
{
    Ignored,
    ResolvedCurrentRoot,
    ResolvedVerifiedReplacement,
    Unresolved,
    SourceFailure,
}

public readonly record struct ApplicationSourceLivenessObservation(
    ApplicationSourceLivenessState State,
    ApplicationResolutionState? ResolutionState,
    double UnresolvedDurationSeconds,
    bool ShouldPublishSourceFailure)
{
    public bool IsCurrent => State != ApplicationSourceLivenessState.Ignored;
}

/// Tracks application identity availability independently from PCM energy.
/// The observation belongs to one session attempt, source generation, and
/// selected logical identity. A terminal source failure is sticky until the
/// attempt is invalidated or a new attempt begins.
public sealed class ApplicationSourceLivenessTracker
{
    private readonly object sync = new();
    private readonly TimeSpan sourceLossBudget;
    private readonly IMonotonicClock clock;
    private SessionAttemptID? activeAttempt;
    private CaptureSourceGeneration? activeGeneration;
    private string? activeIdentity;
    private double? unresolvedSinceMonotonic;
    private ApplicationResolutionState? unresolvedState;
    private bool sourceFailurePublished;

    public ApplicationSourceLivenessTracker(
        TimeSpan sourceLossBudget,
        IMonotonicClock? clock = null)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(
            sourceLossBudget,
            TimeSpan.Zero);

        this.sourceLossBudget = sourceLossBudget;
        this.clock = clock ?? new StopwatchMonotonicClock();
    }

    public void Begin(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        string selectedIdentity,
        double? nowSeconds = null)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        ArgumentNullException.ThrowIfNull(generation);
        ValidateIdentity(selectedIdentity);
        if (generation.Attempt != attempt)
        {
            throw new ArgumentException(
                "La generación de captura no pertenece al intento indicado.",
                nameof(generation));
        }

        _ = ReadNowSeconds(nowSeconds);
        lock (sync)
        {
            activeAttempt = attempt;
            activeGeneration = generation;
            activeIdentity = selectedIdentity;
            unresolvedSinceMonotonic = null;
            unresolvedState = null;
            sourceFailurePublished = false;
        }
    }

    public void Invalidate(SessionAttemptID attempt)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        lock (sync)
        {
            if (activeAttempt == attempt)
            {
                ClearLocked();
            }
        }
    }

    /// Keeps the unresolved observation attached to the new generation while
    /// a rebind is being attempted. A successful replacement must call
    /// ObserveVerifiedReplacement to clear the budget.
    public bool AdvanceGeneration(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        string selectedIdentity)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        ArgumentNullException.ThrowIfNull(generation);
        ValidateIdentity(selectedIdentity);
        if (generation.Attempt != attempt)
        {
            return false;
        }

        lock (sync)
        {
            if (!MatchesAttemptAndIdentityLocked(attempt, selectedIdentity)
                || activeGeneration is null
                || generation.Number < activeGeneration.Number)
            {
                return false;
            }

            activeGeneration = generation;
            return true;
        }
    }

    public bool CanContinue(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        string selectedIdentity)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        ArgumentNullException.ThrowIfNull(generation);
        ValidateIdentity(selectedIdentity);
        lock (sync)
        {
            return !sourceFailurePublished
                && IsCurrentLocked(attempt, generation, selectedIdentity);
        }
    }

    public ApplicationSourceLivenessObservation ObserveResolvedCurrentRoot(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        string selectedIdentity,
        double? nowSeconds = null)
    {
        var now = ReadNowSeconds(nowSeconds);
        lock (sync)
        {
            if (!IsCurrentLocked(attempt, generation, selectedIdentity))
            {
                return Ignored();
            }

            if (sourceFailurePublished)
            {
                return SourceFailureObservationLocked(now, shouldPublish: false);
            }

            unresolvedSinceMonotonic = null;
            unresolvedState = null;
            return new ApplicationSourceLivenessObservation(
                ApplicationSourceLivenessState.ResolvedCurrentRoot,
                ApplicationResolutionState.Resolved,
                0,
                false);
        }
    }

    public ApplicationSourceLivenessObservation ObserveVerifiedReplacement(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        string selectedIdentity,
        double? nowSeconds = null)
    {
        var now = ReadNowSeconds(nowSeconds);
        ArgumentNullException.ThrowIfNull(attempt);
        ArgumentNullException.ThrowIfNull(generation);
        ValidateIdentity(selectedIdentity);
        if (generation.Attempt != attempt)
        {
            return Ignored();
        }

        lock (sync)
        {
            if (!MatchesAttemptAndIdentityLocked(attempt, selectedIdentity)
                || activeGeneration is null
                || generation.Number < activeGeneration.Number)
            {
                return Ignored();
            }

            activeGeneration = generation;
            if (sourceFailurePublished)
            {
                return SourceFailureObservationLocked(now, shouldPublish: false);
            }

            unresolvedSinceMonotonic = null;
            unresolvedState = null;
            return new ApplicationSourceLivenessObservation(
                ApplicationSourceLivenessState.ResolvedVerifiedReplacement,
                ApplicationResolutionState.Resolved,
                0,
                false);
        }
    }

    public ApplicationSourceLivenessObservation ObserveUnresolved(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        string selectedIdentity,
        ApplicationResolutionState resolutionState,
        double? nowSeconds = null)
    {
        if (resolutionState is not (ApplicationResolutionState.Missing
            or ApplicationResolutionState.Ambiguous
            or ApplicationResolutionState.UnsupportedWeakIdentity))
        {
            throw new ArgumentOutOfRangeException(nameof(resolutionState));
        }

        var now = ReadNowSeconds(nowSeconds);
        lock (sync)
        {
            if (!IsCurrentLocked(attempt, generation, selectedIdentity))
            {
                return Ignored();
            }

            if (sourceFailurePublished)
            {
                return SourceFailureObservationLocked(now, shouldPublish: false);
            }

            unresolvedSinceMonotonic ??= now;
            unresolvedState = resolutionState;
            var elapsed = Math.Max(0, now - unresolvedSinceMonotonic.Value);
            if (elapsed >= sourceLossBudget.TotalSeconds)
            {
                sourceFailurePublished = true;
                return SourceFailureObservationLocked(now, shouldPublish: true);
            }

            return new ApplicationSourceLivenessObservation(
                ApplicationSourceLivenessState.Unresolved,
                resolutionState,
                elapsed,
                false);
        }
    }

    private bool IsCurrentLocked(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        string selectedIdentity) =>
        MatchesAttemptAndIdentityLocked(attempt, selectedIdentity)
            && activeGeneration == generation;

    private bool MatchesAttemptAndIdentityLocked(
        SessionAttemptID attempt,
        string selectedIdentity) =>
        activeAttempt == attempt
            && string.Equals(activeIdentity, selectedIdentity, StringComparison.Ordinal);

    private ApplicationSourceLivenessObservation SourceFailureObservationLocked(
        double now,
        bool shouldPublish) => new(
            ApplicationSourceLivenessState.SourceFailure,
            unresolvedState,
            unresolvedSinceMonotonic is { } start
                ? Math.Max(0, now - start)
                : 0,
            shouldPublish);

    private static ApplicationSourceLivenessObservation Ignored() => new(
        ApplicationSourceLivenessState.Ignored,
        null,
        0,
        false);

    private double ReadNowSeconds(double? explicitNowSeconds)
    {
        var now = explicitNowSeconds ?? clock.NowSeconds;
        if (!double.IsFinite(now))
        {
            throw new InvalidOperationException("El reloj monotónico devolvió un tiempo no finito.");
        }

        return now;
    }

    private static void ValidateIdentity(string selectedIdentity)
    {
        if (string.IsNullOrWhiteSpace(selectedIdentity))
        {
            throw new ArgumentException("La identidad lógica seleccionada no puede estar vacía.", nameof(selectedIdentity));
        }
    }

    private void ClearLocked()
    {
        activeAttempt = null;
        activeGeneration = null;
        activeIdentity = null;
        unresolvedSinceMonotonic = null;
        unresolvedState = null;
        sourceFailurePublished = false;
    }
}
