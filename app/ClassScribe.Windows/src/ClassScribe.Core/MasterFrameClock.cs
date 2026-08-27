namespace ClassScribe.Core;

/// Session-owned duration budget for the durable master. Converter instances
/// may reset interpolation state at a generation or format handoff, but this
/// accumulator continues rounding the complete source duration only once.
public sealed class MasterFrameClock
{
    public MasterFrameClock(int masterRate)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(masterRate);

        MasterRate = masterRate;
    }

    public int MasterRate { get; }

    public long TotalInputFrames { get; private set; }

    public double ExactMasterFrames { get; private set; }

    public long TargetSourceFrames { get; private set; }

    public double FractionalRemainder { get; private set; }

    public MasterFrameBudget ReserveSourceFrames(int inputFrameCount, int inputRate)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(inputFrameCount);

        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(inputRate);

        var start = TargetSourceFrames;
        TotalInputFrames = checked(TotalInputFrames + inputFrameCount);
        ExactMasterFrames += (double)inputFrameCount * MasterRate / inputRate;
        if (ExactMasterFrames >= long.MaxValue)
        {
            throw new OverflowException("La duración master excede el límite representable.");
        }

        var rounded = checked((long)Math.Round(
            ExactMasterFrames,
            MidpointRounding.AwayFromZero));
        TargetSourceFrames = Math.Max(start, rounded);
        FractionalRemainder = ExactMasterFrames - Math.Floor(ExactMasterFrames);
        return new MasterFrameBudget(start, TargetSourceFrames);
    }
}

public readonly record struct MasterFrameBudget(long StartFrame, long EndFrame)
{
    public long FrameCount => EndFrame - StartFrame;
}
