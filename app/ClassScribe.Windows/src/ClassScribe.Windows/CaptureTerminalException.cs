namespace ClassScribe.Windows;

/// A stop result that carries the durable failure category without changing
/// the existing single-flight `Task<string>` contract. The optional wave path
/// identifies evidence that was safely materialized before the failure was
/// returned to the control plane.
internal sealed class CaptureTerminalException : IOException
{
    public CaptureTerminalException(
        CaptureFailureCategory category,
        Exception cause,
        string? preservedWavePath = null)
        : base(cause.Message, cause)
    {
        Category = category;
        PreservedWavePath = preservedWavePath;
    }

    public CaptureFailureCategory Category { get; }

    public string? PreservedWavePath { get; }
}
