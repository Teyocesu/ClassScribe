using System.Buffers.Binary;
using System.Diagnostics;

namespace ClassScribe.Core;

/// Transport/content health is separate from CapturePhase, AsrPhase, and
/// SessionPhase. Audible only means material energy; it is never a voice/VAD
/// claim.
public enum CaptureSignalState
{
    AwaitingCallbacks,
    NoCallbacks,
    Silent,
    Audible,
}

public sealed record CaptureSignalThresholds(
    double InitialCallbackBudgetSeconds,
    double StallBudgetSeconds,
    double SilenceEnergyDbfs)
{
    public static CaptureSignalThresholds Windows { get; } = new(10, 12, -43);

    public static CaptureSignalThresholds Test { get; } = new(5, 3, -40);
}

public interface IMonotonicClock
{
    double NowSeconds { get; }
}

public sealed class StopwatchMonotonicClock : IMonotonicClock
{
    public double NowSeconds => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
}

public readonly record struct CaptureSignalMeasurement(
    long SampleCount,
    long FrameCount,
    double Rms,
    double EnergyDbfs)
{
    public static CaptureSignalMeasurement FromPcm16(ReadOnlySpan<byte> pcm, int channels)
    {
        var sampleCount = pcm.Length / sizeof(short);
        if (sampleCount == 0)
        {
            return new CaptureSignalMeasurement(0, 0, 0, -120);
        }

        if (channels <= 0)
        {
            return new CaptureSignalMeasurement(sampleCount, 0, 0, -120);
        }

        double sumOfSquares = 0;
        for (var index = 0; index < sampleCount; index++)
        {
            var sample = BinaryPrimitives.ReadInt16LittleEndian(pcm.Slice(index * sizeof(short), sizeof(short)));
            var normalized = sample / 32768d;
            sumOfSquares += normalized * normalized;
        }

        var rms = Math.Sqrt(sumOfSquares / sampleCount);
        return FromRms(sampleCount, sampleCount / channels, rms);
    }

    public static CaptureSignalMeasurement FromPcm(
        ReadOnlySpan<byte> pcm,
        AudioPcmFormat format)
    {
        format.EnsureValid();
        var samples = PcmAudioConverter.Decode(pcm, format);
        if (samples.Length == 0)
        {
            return new CaptureSignalMeasurement(0, 0, 0, -120);
        }

        double sumOfSquares = 0;
        foreach (var sample in samples)
        {
            var normalized = float.IsFinite(sample) ? sample : 0;
            sumOfSquares += normalized * normalized;
        }

        return FromRms(
            samples.Length,
            samples.Length / format.Channels,
            Math.Sqrt(sumOfSquares / samples.Length));
    }

    public static CaptureSignalMeasurement FromRms(long sampleCount, long frameCount, double rms)
    {
        var safeRms = double.IsFinite(rms) ? Math.Max(0, rms) : 0;
        var energyDbfs = safeRms > 0
            ? Math.Max(-120, 20 * Math.Log10(safeRms))
            : -120;
        return new CaptureSignalMeasurement(
            Math.Max(0, sampleCount),
            Math.Max(0, frameCount),
            safeRms,
            energyDbfs);
    }
}

public sealed record CaptureSignalHealthSnapshot(
    SessionAttemptID Attempt,
    CaptureSignalState State,
    double StartedAtMonotonic,
    double? LastCallbackAtMonotonic,
    long CallbackCount,
    long SampleCount,
    long FrameCount,
    double Rms,
    double EnergyDbfs,
    double ElapsedSinceStart,
    double? ElapsedSinceLastCallback)
{
    public bool HasReceivedCallbacks => CallbackCount > 0;
}

/// Separates observing a structured signal state from presenting its status.
/// A state observed during startup is still presentable once recording begins.
public static class CaptureSignalPresentationPolicy
{
    public static bool ShouldPresent(
        CaptureSignalState state,
        CaptureSignalState? lastPresentedState,
        bool isRecording) => isRecording && state != lastPresentedState;
}

/// Thread-safe per-attempt classifier used by the WASAPI callback adapter.
/// Ownership and state update share one lock so stale A cannot update B.
public sealed class CaptureSignalHealthTracker
{
    private readonly object sync = new();
    private readonly CaptureSignalThresholds thresholds;
    private readonly IMonotonicClock clock;
    private SessionAttemptID? activeAttempt;
    private double startedAtMonotonic;
    private double? lastCallbackAtMonotonic;
    private long callbackCount;
    private long sampleCount;
    private long frameCount;
    private double lastRms;
    private double lastEnergyDbfs = -120;

    public CaptureSignalHealthTracker(
        CaptureSignalThresholds thresholds,
        IMonotonicClock? clock = null)
    {
        this.thresholds = thresholds ?? throw new ArgumentNullException(nameof(thresholds));
        this.clock = clock ?? new StopwatchMonotonicClock();
    }

    public void Begin(SessionAttemptID attempt, double? nowSeconds = null)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        var start = nowSeconds ?? clock.NowSeconds;
        lock (sync)
        {
            activeAttempt = attempt;
            startedAtMonotonic = start;
            lastCallbackAtMonotonic = null;
            callbackCount = 0;
            sampleCount = 0;
            frameCount = 0;
            lastRms = 0;
            lastEnergyDbfs = -120;
        }
    }

    public void Invalidate(SessionAttemptID attempt)
    {
        lock (sync)
        {
            if (Equals(activeAttempt, attempt))
            {
                activeAttempt = null;
            }
        }
    }

    public bool TryRecordCallback(
        SessionAttemptID attempt,
        CaptureSignalMeasurement measurement,
        double? nowSeconds = null)
    {
        var callbackTime = nowSeconds ?? clock.NowSeconds;
        lock (sync)
        {
            if (!Equals(activeAttempt, attempt))
            {
                return false;
            }

            callbackCount++;
            sampleCount += Math.Max(0, measurement.SampleCount);
            frameCount += Math.Max(0, measurement.FrameCount);
            lastCallbackAtMonotonic = callbackTime;
            lastRms = measurement.Rms;
            lastEnergyDbfs = measurement.EnergyDbfs;
            return true;
        }
    }

    public CaptureSignalHealthSnapshot? Snapshot(
        SessionAttemptID? expectedAttempt = null,
        double? nowSeconds = null)
    {
        var currentTime = nowSeconds ?? clock.NowSeconds;
        lock (sync)
        {
            var currentAttempt = activeAttempt;
            if (currentAttempt is null
                || (expectedAttempt is not null && !Equals(expectedAttempt, currentAttempt)))
            {
                return null;
            }

            var elapsedSinceStart = Math.Max(0, currentTime - startedAtMonotonic);
            double? elapsedSinceLastCallback = lastCallbackAtMonotonic is { } callbackTime
                ? Math.Max(0, currentTime - callbackTime)
                : null;
            var state = callbackCount == 0
                ? elapsedSinceStart >= thresholds.InitialCallbackBudgetSeconds
                    ? CaptureSignalState.NoCallbacks
                    : CaptureSignalState.AwaitingCallbacks
                : elapsedSinceLastCallback >= thresholds.StallBudgetSeconds
                    ? CaptureSignalState.NoCallbacks
                    : lastEnergyDbfs <= thresholds.SilenceEnergyDbfs
                        ? CaptureSignalState.Silent
                        : CaptureSignalState.Audible;

            return new CaptureSignalHealthSnapshot(
                currentAttempt,
                state,
                startedAtMonotonic,
                lastCallbackAtMonotonic,
                callbackCount,
                sampleCount,
                frameCount,
                lastRms,
                lastEnergyDbfs,
                elapsedSinceStart,
                elapsedSinceLastCallback);
        }
    }
}
