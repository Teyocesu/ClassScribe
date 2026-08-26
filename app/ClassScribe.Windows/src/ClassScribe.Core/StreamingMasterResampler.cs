namespace ClassScribe.Core;

/// Stateful linear converter for one durable master source stream. It keeps
/// cumulative frame accounting and one source frame of look-ahead across
/// callbacks; a new instance is required for a new source generation or input
/// format so interpolation never crosses a handoff gap.
public sealed class StreamingMasterResampler
{
    private readonly List<float> buffer = [];
    private readonly float[] previousFrame;
    private readonly float[] lastInputFrame;
    private long bufferStartFrame;
    private bool hasInput;
    private bool finished;

    public StreamingMasterResampler(
        int inputRate,
        int inputChannels,
        int outputRate,
        int outputChannels)
    {
        if (inputRate <= 0 || inputChannels <= 0 || outputRate <= 0
            || outputChannels is < 1 or > 2)
        {
            throw new ArgumentOutOfRangeException();
        }

        InputRate = inputRate;
        InputChannels = inputChannels;
        OutputRate = outputRate;
        OutputChannels = outputChannels;
        previousFrame = new float[outputChannels];
        lastInputFrame = new float[outputChannels];
        buffer.Capacity = outputChannels * 512;
    }

    public int InputRate { get; }

    public int InputChannels { get; }

    public int OutputRate { get; }

    public int OutputChannels { get; }

    public long TotalInputFrames { get; private set; }

    public long TotalOutputFrames { get; private set; }

    /// Fractional source-frame position of the next output frame.
    public double FractionalPhase { get; private set; }

    /// <param name="targetOutputFrames">
    /// Cumulative output budget assigned by the session-owned master clock.
    /// Null retains the converter-local budget for isolated callers.
    /// </param>
    public float[] Process(ReadOnlySpan<float> samples, long? targetOutputFrames = null)
    {
        if (finished || samples.Length == 0)
        {
            return [];
        }

        var inputFrameCount = samples.Length / InputChannels;
        if (inputFrameCount <= 0)
        {
            return [];
        }

        for (var frame = 0; frame < inputFrameCount; frame++)
        {
            AppendNormalizedFrame(samples, frame);
        }

        TotalInputFrames = checked(TotalInputFrames + inputFrameCount);

        // Equal-rate input has no temporal interpolation to prime. Copy every
        // normalized frame immediately so converter look-ahead cannot become a
        // false handoff gap in the durable timeline.
        if (InputRate == OutputRate)
        {
            var output = buffer.ToArray();
            buffer.Clear();
            bufferStartFrame = TotalInputFrames;
            Array.Copy(lastInputFrame, previousFrame, OutputChannels);
            TotalOutputFrames = checked(TotalOutputFrames + inputFrameCount);
            FractionalPhase = 0;
            return output;
        }

        return EmitAvailable(final: false, targetOutputFrames: targetOutputFrames);
    }

    public float[] Finish(long? targetOutputFrames = null)
    {
        if (finished)
        {
            return [];
        }

        finished = true;
        if (InputRate == OutputRate)
        {
            return [];
        }

        return EmitAvailable(final: true, targetOutputFrames: targetOutputFrames);
    }

    private void AppendNormalizedFrame(ReadOnlySpan<float> samples, int frame)
    {
        var source = checked(frame * InputChannels);
        if (OutputChannels == 1)
        {
            var sum = 0f;
            for (var channel = 0; channel < InputChannels; channel++)
            {
                sum += Sanitize(samples[source + channel]);
            }

            var value = sum / InputChannels;
            buffer.Add(value);
            lastInputFrame[0] = value;
            hasInput = true;
            return;
        }

        if (InputChannels == 1)
        {
            var value = Sanitize(samples[source]);
            buffer.Add(value);
            buffer.Add(value);
            lastInputFrame[0] = value;
            lastInputFrame[1] = value;
            hasInput = true;
            return;
        }

        if (InputChannels == 2)
        {
            var left = Sanitize(samples[source]);
            var right = Sanitize(samples[source + 1]);
            buffer.Add(left);
            buffer.Add(right);
            lastInputFrame[0] = left;
            lastInputFrame[1] = right;
            hasInput = true;
            return;
        }

        var evenSum = 0f;
        var oddSum = 0f;
        var evenCount = 0;
        var oddCount = 0;
        for (var channel = 0; channel < InputChannels; channel++)
        {
            if ((channel & 1) == 0)
            {
                evenSum += Sanitize(samples[source + channel]);
                evenCount++;
            }
            else
            {
                oddSum += Sanitize(samples[source + channel]);
                oddCount++;
            }
        }

        var normalizedLeft = evenSum / Math.Max(evenCount, 1);
        var normalizedRight = oddSum / Math.Max(oddCount, 1);
        buffer.Add(normalizedLeft);
        buffer.Add(normalizedRight);
        lastInputFrame[0] = normalizedLeft;
        lastInputFrame[1] = normalizedRight;
        hasInput = true;
    }

    private float[] EmitAvailable(bool final, long? targetOutputFrames)
    {
        if (!hasInput)
        {
            return [];
        }

        var targetFrames = targetOutputFrames ?? RoundedRatio(TotalInputFrames);
        if (targetFrames < TotalOutputFrames)
        {
            UpdatePhase();
            CompactBuffer();
            return [];
        }

        if (TotalOutputFrames >= targetFrames)
        {
            UpdatePhase();
            CompactBuffer();
            return [];
        }

        var output = new List<float>(checked((int)Math.Min(
            int.MaxValue / OutputChannels,
            targetFrames - TotalOutputFrames) * OutputChannels));
        while (TotalOutputFrames < targetFrames)
        {
            var positionNumerator = checked(TotalOutputFrames * InputRate);
            var lower = positionNumerator / OutputRate;
            if (lower >= TotalInputFrames)
            {
                break;
            }

            var upper = lower + 1;
            if (!final && upper >= TotalInputFrames)
            {
                break;
            }

            var fraction = (float)(positionNumerator % OutputRate) / OutputRate;
            for (var channel = 0; channel < OutputChannels; channel++)
            {
                var first = SampleAt(lower, channel);
                var second = upper < TotalInputFrames
                    ? SampleAt(upper, channel)
                    : lastInputFrame[channel];
                output.Add(Sanitize(first + ((second - first) * fraction)));
            }

            TotalOutputFrames++;
        }

        UpdatePhase();
        CompactBuffer();
        return output.ToArray();
    }

    private float SampleAt(long frame, int channel)
    {
        if (frame < bufferStartFrame)
        {
            return previousFrame[channel];
        }

        var offset = checked((int)(frame - bufferStartFrame) * OutputChannels + channel);
        return offset >= 0 && offset < buffer.Count
            ? buffer[offset]
            : lastInputFrame[channel];
    }

    private void CompactBuffer()
    {
        if (!hasInput || buffer.Count == 0)
        {
            return;
        }

        var nextPositionNumerator = checked(TotalOutputFrames * InputRate);
        var nextLower = nextPositionNumerator / OutputRate;
        var lastFrame = Math.Max(0, TotalInputFrames - 1);
        var keepFrom = Math.Min(Math.Max(0, nextLower), lastFrame);
        var framesToDrop = keepFrom - bufferStartFrame;
        if (framesToDrop <= 0)
        {
            return;
        }

        var samplesToDrop = checked((int)framesToDrop * OutputChannels);
        for (var channel = 0; channel < OutputChannels; channel++)
        {
            previousFrame[channel] = buffer[samplesToDrop - OutputChannels + channel];
        }
        buffer.RemoveRange(0, samplesToDrop);
        bufferStartFrame = keepFrom;
    }

    private void UpdatePhase()
    {
        var remainder = checked((TotalOutputFrames * InputRate) % OutputRate);
        FractionalPhase = remainder / (double)OutputRate;
    }

    private long RoundedRatio(long inputFrames)
    {
        var numerator = checked(inputFrames * (long)OutputRate);
        var denominator = (long)InputRate;
        var quotient = numerator / denominator;
        var remainder = numerator % denominator;
        return quotient + (remainder * 2 >= denominator ? 1 : 0);
    }

    private static float Sanitize(float value) => float.IsFinite(value) ? value : 0;
}
