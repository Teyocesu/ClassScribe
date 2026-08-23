namespace ClassScribe.Windows;

internal enum AudioSourceKind
{
    Process,
    Microphone,
}

internal sealed record AudioSourceOption(
    AudioSourceKind Kind,
    string Id,
    string Name,
    int? ProcessId = null)
{
    public string DisplayName => Kind == AudioSourceKind.Process && ProcessId is not null
        ? $"{Name}  ·  PID {ProcessId}"
        : Name;
}
