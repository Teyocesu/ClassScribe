using ClassScribe.Core;

namespace ClassScribe.Windows;

internal enum AudioSourceKind
{
    Process,
    Microphone,
    SystemOutput,
}

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
