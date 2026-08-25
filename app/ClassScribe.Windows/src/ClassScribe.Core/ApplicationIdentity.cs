namespace ClassScribe.Core;

public enum ApplicationIdentityStrength
{
    Strong,
    Weak,
}

/// Logical Windows application identity. ProcessId is deliberately kept in a
/// separate WindowsProcessIncarnation value and is never part of StableKey.
public sealed record WindowsApplicationIdentity(
    string? ExecutablePath,
    string? PackageIdentity,
    string? ProcessName)
{
    public ApplicationIdentityStrength Strength => HasStrongIdentity
        ? ApplicationIdentityStrength.Strong
        : ApplicationIdentityStrength.Weak;

    public bool HasStrongIdentity =>
        !string.IsNullOrWhiteSpace(ExecutablePath)
        || !string.IsNullOrWhiteSpace(PackageIdentity);

    public string StableKey
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(PackageIdentity))
            {
                return $"package:{PackageIdentity}";
            }

            if (!string.IsNullOrWhiteSpace(ExecutablePath))
            {
                return $"executable:{ExecutablePath}";
            }

            return $"weak-process:{ProcessName ?? "unknown"}";
        }
    }

    public bool StronglyMatches(WindowsApplicationIdentity candidate)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        if (!HasStrongIdentity || !candidate.HasStrongIdentity)
        {
            return false;
        }

        var packageMatches = !string.IsNullOrWhiteSpace(PackageIdentity)
            && string.Equals(PackageIdentity, candidate.PackageIdentity, StringComparison.OrdinalIgnoreCase);
        var pathMatches = !string.IsNullOrWhiteSpace(ExecutablePath)
            && string.Equals(ExecutablePath, candidate.ExecutablePath, StringComparison.OrdinalIgnoreCase);
        return packageMatches || pathMatches;
    }

    public bool MatchesSameWeakIncarnation(WindowsApplicationIdentity candidate)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        if (HasStrongIdentity || candidate.HasStrongIdentity)
        {
            return false;
        }

        return string.IsNullOrWhiteSpace(ProcessName)
            || string.IsNullOrWhiteSpace(candidate.ProcessName)
            || string.Equals(ProcessName, candidate.ProcessName, StringComparison.OrdinalIgnoreCase);
    }

    public static WindowsApplicationIdentity FromObservation(
        string? executablePath,
        string? processName,
        string? packageIdentity = null) => new(
            NormalizePath(executablePath),
            Normalize(packageIdentity),
            Normalize(processName));

    private static string? Normalize(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrWhiteSpace(trimmed) ? null : trimmed;
    }

    private static string? NormalizePath(string? value)
    {
        var trimmed = Normalize(value);
        if (trimmed is null)
        {
            return null;
        }

        try
        {
            return Path.GetFullPath(trimmed)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }
        catch (ArgumentException)
        {
            return trimmed;
        }
    }
}

public sealed record WindowsProcessIncarnation(
    int ProcessId,
    WindowsApplicationIdentity Identity);

public enum ApplicationResolutionState
{
    Resolved,
    Missing,
    Ambiguous,
    UnsupportedWeakIdentity,
}

public sealed record WindowsApplicationResolution(
    ApplicationResolutionState State,
    string SelectedIdentity,
    int? PreviousProcessId,
    int? ResolvedProcessId,
    int CandidateCount,
    IReadOnlyList<int> CandidateProcessIds)
{
    public bool IsResolved => State == ApplicationResolutionState.Resolved
        && ResolvedProcessId is not null;
}

public static class WindowsApplicationResolver
{
    public static WindowsApplicationResolution Resolve(
        WindowsApplicationIdentity selectedIdentity,
        int? previousProcessId,
        IReadOnlyList<WindowsProcessIncarnation> candidates)
    {
        ArgumentNullException.ThrowIfNull(selectedIdentity);
        ArgumentNullException.ThrowIfNull(candidates);

        var strongMatches = candidates
            .Where(candidate => selectedIdentity.StronglyMatches(candidate.Identity))
            .ToArray();
        var matchIds = strongMatches.Select(static candidate => candidate.ProcessId).ToArray();

        if (previousProcessId is not null)
        {
            var previous = candidates.FirstOrDefault(
                candidate => candidate.ProcessId == previousProcessId.Value);
            if (previous is not null
                && (selectedIdentity.StronglyMatches(previous.Identity)
                    || selectedIdentity.MatchesSameWeakIncarnation(previous.Identity)))
            {
                return Resolved(selectedIdentity, previousProcessId, previous, strongMatches.Length, matchIds);
            }
        }

        if (strongMatches.Length > 1)
        {
            return new WindowsApplicationResolution(
                ApplicationResolutionState.Ambiguous,
                selectedIdentity.StableKey,
                previousProcessId,
                null,
                strongMatches.Length,
                matchIds);
        }

        if (!selectedIdentity.HasStrongIdentity)
        {
            return new WindowsApplicationResolution(
                ApplicationResolutionState.UnsupportedWeakIdentity,
                selectedIdentity.StableKey,
                previousProcessId,
                null,
                candidates.Count,
                matchIds);
        }

        return strongMatches.Length switch
        {
            0 => new WindowsApplicationResolution(
                ApplicationResolutionState.Missing,
                selectedIdentity.StableKey,
                previousProcessId,
                null,
                candidates.Count,
                matchIds),
            1 => Resolved(selectedIdentity, previousProcessId, strongMatches[0], 1, matchIds),
            _ => new WindowsApplicationResolution(
                ApplicationResolutionState.Ambiguous,
                selectedIdentity.StableKey,
                previousProcessId,
                null,
                strongMatches.Length,
                matchIds),
        };
    }

    private static WindowsApplicationResolution Resolved(
        WindowsApplicationIdentity selectedIdentity,
        int? previousProcessId,
        WindowsProcessIncarnation candidate,
        int candidateCount,
        IReadOnlyList<int> candidateProcessIds) => new(
            ApplicationResolutionState.Resolved,
            selectedIdentity.StableKey,
            previousProcessId,
            candidate.ProcessId,
            candidateCount,
            candidateProcessIds);
}

public sealed class WindowsApplicationResolutionException : InvalidOperationException
{
    public WindowsApplicationResolutionException(WindowsApplicationResolution resolution)
        : base($"Application startup resolution failed: {resolution.State}.")
    {
        Resolution = resolution;
    }

    public WindowsApplicationResolution Resolution { get; }
}

/// Startup-only boundary. There is intentionally no API that swaps the PID of
/// an already-running recorder; 2B.2 owns that future lifecycle work.
public static class WindowsApplicationStartup
{
    public static async Task<int> ResolveBeforeBuildAsync(
        WindowsApplicationIdentity selectedIdentity,
        int? previousProcessId,
        Func<IReadOnlyList<WindowsProcessIncarnation>> enumerateCandidates,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(selectedIdentity);
        ArgumentNullException.ThrowIfNull(enumerateCandidates);
        var candidates = await Task.Run(enumerateCandidates, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        var resolution = WindowsApplicationResolver.Resolve(
            selectedIdentity,
            previousProcessId,
            candidates);
        if (!resolution.IsResolved || resolution.ResolvedProcessId is null)
        {
            throw new WindowsApplicationResolutionException(resolution);
        }

        return resolution.ResolvedProcessId.Value;
    }

    /// The final ownership gate for process-loopback construction. The
    /// delegate is invoked synchronously after the attempt and cancellation
    /// checks, so a stale startup cannot reach WithProcessLoopback/BuildAsync.
    /// The Windows capture product calls this at the actual recorder-build
    /// boundary; it is not a publication-only helper.
    public static async Task<T> BuildProcessLoopbackIfCurrentAttemptAsync<T>(
        SessionAttemptID attempt,
        Func<SessionAttemptID, bool> isCurrentAttempt,
        Func<Task<T>> buildAsync,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        ArgumentNullException.ThrowIfNull(isCurrentAttempt);
        ArgumentNullException.ThrowIfNull(buildAsync);

        cancellationToken.ThrowIfCancellationRequested();
        if (!isCurrentAttempt(attempt))
        {
            throw new OperationCanceledException(cancellationToken);
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (!isCurrentAttempt(attempt))
        {
            throw new OperationCanceledException(cancellationToken);
        }

        return await buildAsync().ConfigureAwait(false);
    }

    public static bool TryPublishResolution(
        SessionAttemptID attempt,
        SessionAttemptID? currentAttempt,
        WindowsApplicationResolution resolution,
        out int processId)
    {
        if (currentAttempt is not null
            && attempt == currentAttempt
            && resolution.IsResolved
            && resolution.ResolvedProcessId is not null)
        {
            processId = resolution.ResolvedProcessId.Value;
            return true;
        }

        processId = 0;
        return false;
    }
}
