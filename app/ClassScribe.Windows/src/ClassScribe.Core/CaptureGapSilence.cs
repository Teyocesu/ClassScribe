using System.Diagnostics;

namespace ClassScribe.Core;

public enum CaptureGapDisposition
{
    NoGap,
    Silence,
    ExceedsSafetyBound,
}

public readonly record struct CaptureGapAssessment(
    CaptureGapDisposition Disposition,
    int SilenceBytes,
    double GapSeconds)
{
    public bool IsExplicitFailure => Disposition == CaptureGapDisposition.ExceedsSafetyBound;
}

public sealed class CaptureGapExceededSafetyBoundException : InvalidOperationException
{
    public CaptureGapExceededSafetyBoundException(double gapSeconds, TimeSpan maximumGap)
        : base($"The capture handoff gap ({gapSeconds:F3}s) exceeds the safety bound ({maximumGap.TotalSeconds:F3}s).")
    {
        GapSeconds = gapSeconds;
        MaximumGap = maximumGap;
    }

    public double GapSeconds { get; }

    public TimeSpan MaximumGap { get; }
}

/// Bounded monotonic-clock gap policy for a source-generation handoff. Normal
/// callbacks do not call this policy; the Windows adapter invokes it only for
/// the first non-empty callback of a newly published generation.
public static class CaptureGapSilence
{
    public static TimeSpan DefaultMaximumGap => TimeSpan.FromSeconds(30);

    public static CaptureGapAssessment Assess(
        long? previousTimestamp,
        long currentTimestamp,
        int bytesPerSecond,
        int previousPacketBytes = 0,
        TimeSpan maximumGap = default)
    {
        var maximum = maximumGap == default ? DefaultMaximumGap : maximumGap;
        if (previousTimestamp is null || currentTimestamp <= previousTimestamp.Value || bytesPerSecond <= 0)
        {
            return new(CaptureGapDisposition.NoGap, 0, 0);
        }

        var elapsed = ((double)currentTimestamp - previousTimestamp.Value) / Stopwatch.Frequency;
        if (!double.IsFinite(elapsed) || elapsed <= 0)
        {
            return new(CaptureGapDisposition.NoGap, 0, 0);
        }

        var expectedPacketSeconds = Math.Max(0, previousPacketBytes) / (double)bytesPerSecond;
        var gapSeconds = elapsed - expectedPacketSeconds;
        if (!double.IsFinite(gapSeconds) || gapSeconds <= 0)
        {
            return new(CaptureGapDisposition.NoGap, 0, 0);
        }

        if (gapSeconds > maximum.TotalSeconds)
        {
            return new(CaptureGapDisposition.ExceedsSafetyBound, 0, gapSeconds);
        }

        var bytes = gapSeconds * bytesPerSecond;
        if (!double.IsFinite(bytes) || bytes < 2)
        {
            return new(CaptureGapDisposition.NoGap, 0, gapSeconds);
        }

        var bounded = checked((int)Math.Min(bytes, maximum.TotalSeconds * bytesPerSecond)) & ~1;
        return bounded > 0
            ? new(CaptureGapDisposition.Silence, bounded, gapSeconds)
            : new(CaptureGapDisposition.NoGap, 0, gapSeconds);
    }

    public static int ComputeBytes(
        long? previousTimestamp,
        long currentTimestamp,
        int bytesPerSecond,
        int previousPacketBytes = 0,
        TimeSpan maximumGap = default)
    {
        var assessment = Assess(
            previousTimestamp,
            currentTimestamp,
            bytesPerSecond,
            previousPacketBytes,
            maximumGap);
        if (assessment.IsExplicitFailure)
        {
            var maximum = maximumGap == default ? DefaultMaximumGap : maximumGap;
            throw new CaptureGapExceededSafetyBoundException(assessment.GapSeconds, maximum);
        }

        return assessment.SilenceBytes;
    }
}
