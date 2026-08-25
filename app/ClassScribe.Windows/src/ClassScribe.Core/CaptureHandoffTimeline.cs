using System.Diagnostics;

namespace ClassScribe.Core;

/// The durable packet writer's handoff state. It deliberately has no wall-clock
/// sampling on ordinary callbacks: only the first non-empty callback of the
/// initial or a newly handed-off generation samples its monotonic arrival
/// boundary. Later callbacks advance only by durable PCM duration.
public sealed class CaptureHandoffTimeline
{
    private readonly object sync = new();
    private readonly int bytesPerSecond;
    private CaptureSourceGeneration? activeGeneration;
    private long? lastPacketEndTimestamp;
    private PendingHandoff? pendingHandoff;

    public CaptureHandoffTimeline(int bytesPerSecond)
    {
        if (bytesPerSecond <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(bytesPerSecond));
        }

        this.bytesPerSecond = bytesPerSecond;
    }

    public void Reset()
    {
        lock (sync)
        {
            activeGeneration = null;
            lastPacketEndTimestamp = null;
            pendingHandoff = null;
        }
    }

    public void BeginGeneration(CaptureSourceGeneration generation)
    {
        ArgumentNullException.ThrowIfNull(generation);
        lock (sync)
        {
            activeGeneration = generation;
            pendingHandoff = null;
        }
    }

    public void MarkHandoff(CaptureSourceGeneration generation)
    {
        ArgumentNullException.ThrowIfNull(generation);
        lock (sync)
        {
            activeGeneration = generation;
            pendingHandoff = new PendingHandoff(generation);
        }
    }

    public CapturePacketWritePlan PreparePacket(
        CaptureSourceGeneration generation,
        int byteCount,
        Func<long>? arrivalTimestamp = null,
        TimeSpan maximumGap = default)
    {
        ArgumentNullException.ThrowIfNull(generation);
        if (byteCount < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(byteCount));
        }

        lock (sync)
        {
            if (activeGeneration != generation)
            {
                return CapturePacketWritePlan.Rejected(generation, byteCount);
            }

            if (byteCount == 0)
            {
                return CapturePacketWritePlan.Empty(generation);
            }

            var handoff = pendingHandoff;
            if (handoff is not null && handoff.Generation != generation)
            {
                return CapturePacketWritePlan.Rejected(generation, byteCount);
            }
            var needsArrivalTimestamp = lastPacketEndTimestamp is null || handoff is not null;
            var arrival = needsArrivalTimestamp
                ? arrivalTimestamp?.Invoke()
                    ?? throw new InvalidOperationException(
                        "El primer PCM aceptado necesita su timestamp de llegada.")
                : null;
            var assessment = handoff is null
                ? new CaptureGapAssessment(CaptureGapDisposition.NoGap, 0, 0)
                : CaptureGapSilence.Assess(
                    lastPacketEndTimestamp,
                    arrival!.Value,
                    bytesPerSecond,
                    maximumGap: maximumGap);
            var baseTimestamp = arrival ?? lastPacketEndTimestamp;
            var packetEndTimestamp = baseTimestamp is null
                ? null
                : checked(baseTimestamp.Value + DurationTicks(byteCount));

            // Claim at the writer boundary. A zero-length callback never gets
            // here, so it cannot consume a pending handoff gap.
            pendingHandoff = null;
            return new CapturePacketWritePlan(
                Generation: generation,
                ByteCount: byteCount,
                IsAccepted: true,
                IsEmpty: false,
                HandoffGap: assessment,
                PacketEndTimestamp: packetEndTimestamp,
            );
        }
    }

    public void CommitPacket(CapturePacketWritePlan plan)
    {
        if (!plan.IsAccepted || plan.IsEmpty || plan.PacketEndTimestamp is null)
        {
            return;
        }

        lock (sync)
        {
            if (activeGeneration == plan.Generation)
            {
                lastPacketEndTimestamp = plan.PacketEndTimestamp;
            }
        }
    }

    public (long? LastPacketEndTimestamp, bool HasPendingHandoff) Snapshot
    {
        get
        {
            lock (sync)
            {
                return (lastPacketEndTimestamp, pendingHandoff is not null);
            }
        }
    }

    private long DurationTicks(int byteCount) =>
        checked((long)Math.Round(
            byteCount / (double)bytesPerSecond * Stopwatch.Frequency,
            MidpointRounding.AwayFromZero));

    private sealed record PendingHandoff(CaptureSourceGeneration Generation);
}

public readonly record struct CapturePacketWritePlan(
    CaptureSourceGeneration Generation,
    int ByteCount,
    bool IsAccepted,
    bool IsEmpty,
    CaptureGapAssessment HandoffGap,
    long? PacketEndTimestamp)
{
    public bool IsRejected => !IsAccepted;

    public bool RequiresExplicitFailure =>
        IsAccepted && HandoffGap.IsExplicitFailure;

    internal static CapturePacketWritePlan Rejected(
        CaptureSourceGeneration generation,
        int byteCount) => new(
            Generation: generation,
            ByteCount: byteCount,
            IsAccepted: false,
            IsEmpty: byteCount == 0,
            HandoffGap: new CaptureGapAssessment(CaptureGapDisposition.NoGap, 0, 0),
            PacketEndTimestamp: null);

    internal static CapturePacketWritePlan Empty(
        CaptureSourceGeneration generation) => new(
            Generation: generation,
            ByteCount: 0,
            IsAccepted: true,
            IsEmpty: true,
            HandoffGap: new CaptureGapAssessment(CaptureGapDisposition.NoGap, 0, 0),
            PacketEndTimestamp: null);
}
