using ClassScribe.Core;

namespace ClassScribe.Windows;

internal enum AudioSourceKind
{
    Process,
    Microphone,
    SystemOutput,
}

internal enum OnlineCaptureSource
{
    Application,
    SystemOutput,
}

internal enum CaptureRecoverySuggestion
{
    SystemOutput,
}

internal enum CaptureFailureCategory
{
    Source,
    DurableMaster,
    Storage,
    Other,
}

internal sealed record CaptureFault(Exception Error, CaptureFailureCategory Category);

internal static class CaptureRecoveryPolicy
{
    public static bool CanSuggestSystemOutput(
        CaptureFailureCategory category,
        CaptureScope? scope) =>
        category == CaptureFailureCategory.Source
            && scope == CaptureScope.Application;
}

internal sealed record SystemOutputConsentRequest(
    Guid Id,
    SessionAttemptID Attempt,
    string Subject);

internal sealed record AudioSourceOption(
    AudioSourceKind Kind,
    string Id,
    string Name,
    int? ProcessId = null,
    WindowsApplicationIdentity? Identity = null)
{
    public string DisplayName => Kind == AudioSourceKind.Process && ProcessId is not null
        ? $"{Name}  ·  PID {ProcessId}"
        : Name;
}
