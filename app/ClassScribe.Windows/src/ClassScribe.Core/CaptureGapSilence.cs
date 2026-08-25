using System.Diagnostics;

namespace ClassScribe.Core;

/// Bounded monotonic-clock gap policy for a source-generation handoff. It
/// returns PCM bytes only for plausible gaps and never attempts an unbounded
/// allocation from a corrupt timestamp.
public static class CaptureGapSilence
{
    public static int ComputeBytes(
        long? previousTimestamp,
        long currentTimestamp,
        int bytesPerSecond,
        int previousPacketBytes = 0,
        TimeSpan maximumGap = default)
    {
        if (previousTimestamp is null || currentTimestamp <= previousTimestamp.Value || bytesPerSecond <= 0)
        {
            return 0;
        }

        var maximum = maximumGap == default ? TimeSpan.FromSeconds(10) : maximumGap;
        var elapsed = (currentTimestamp - previousTimestamp.Value) / (double)Stopwatch.Frequency;
        if (!double.IsFinite(elapsed) || elapsed <= 0 || elapsed > maximum.TotalSeconds)
        {
            return 0;
        }

        var expectedPacketSeconds = Math.Max(0, previousPacketBytes) / (double)bytesPerSecond;
        var gapSeconds = elapsed - expectedPacketSeconds;
        if (!double.IsFinite(gapSeconds) || gapSeconds <= 0 || gapSeconds > maximum.TotalSeconds)
        {
            return 0;
        }

        var bytes = gapSeconds * bytesPerSecond;
        if (bytes < 2)
        {
            return 0;
        }

        var bounded = Math.Min(bytes, maximum.TotalSeconds * bytesPerSecond);
        return checked((int)bounded) & ~1;
    }
}
