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

internal sealed record OnlineCaptureSourceChoice(OnlineCaptureSource Value, string Name);

internal enum CaptureRecoverySuggestion
{
    SystemOutput,
}

internal enum CaptureFailureCategory
{
    Source,
    Storage,
    Other,
}

internal sealed record CaptureFault(Exception Error, CaptureFailureCategory Category);

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
