using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class StreamingMasterResamplerTests
{
    [TestMethod]
    public void resampler44100To48000TracksRationalCountAcrossTenThousandCallbacks()
    {
        var converter = new StreamingMasterResampler(44_100, 1, 48_000, 1);
        long outputFrames = 0;
        double firstPhase = 0;
        double secondPhase = 0;

        for (var callback = 0; callback < 10_000; callback++)
        {
            outputFrames += converter.Process(new float[256]).Length;
            if (callback == 0)
            {
                firstPhase = converter.FractionalPhase;
            }
            else if (callback == 1)
            {
                secondPhase = converter.FractionalPhase;
            }
        }

        outputFrames += converter.Finish().Length;
        var expected = RoundedRatio(10_000L * 256, 44_100, 48_000);

        Assert.AreEqual(outputFrames, converter.TotalOutputFrames);
        Assert.IsTrue(Math.Abs(outputFrames - expected) <= 1);
        Assert.AreNotEqual(0, firstPhase, 0.000000000001);
        Assert.AreNotEqual(firstPhase, secondPhase, 0.000000000001);
    }

    [TestMethod]
    public void resampler48000To44100TracksRationalCountAcrossTenThousandCallbacks()
    {
        var converter = new StreamingMasterResampler(48_000, 1, 44_100, 1);
        long outputFrames = 0;

        for (var callback = 0; callback < 10_000; callback++)
        {
            outputFrames += converter.Process(new float[127]).Length;
        }

        outputFrames += converter.Finish().Length;
        var expected = RoundedRatio(10_000L * 127, 48_000, 44_100);

        Assert.AreEqual(outputFrames, converter.TotalOutputFrames);
        Assert.IsTrue(Math.Abs(outputFrames - expected) <= 1);
    }

    [TestMethod]
    public void alternatingCallbackSizesKeepCumulativeCount()
    {
        var converter = new StreamingMasterResampler(44_100, 1, 48_000, 1);
        var sizes = new[] { 127, 256, 511 };
        long inputFrames = 0;
        long outputFrames = 0;

        for (var callback = 0; callback < 3_000; callback++)
        {
            var size = sizes[callback % sizes.Length];
            inputFrames += size;
            outputFrames += converter.Process(new float[size]).Length;
        }

        outputFrames += converter.Finish().Length;
        var expected = RoundedRatio(inputFrames, 44_100, 48_000);

        Assert.AreEqual(inputFrames, converter.TotalInputFrames);
        Assert.AreEqual(outputFrames, converter.TotalOutputFrames);
        Assert.IsTrue(Math.Abs(outputFrames - expected) <= 1);
    }

    [TestMethod]
    public void rampSplitAcrossCallbacksMatchesOneBlockAndStaysContinuous()
    {
        const int inputRate = 44_100;
        const int outputRate = 48_000;
        var ramp = Enumerable.Range(0, 4_096)
            .Select(index => index / 4_096f)
            .ToArray();

        var oneBlock = Collect(ramp, inputRate, outputRate, [ramp.Length]);
        var split = Collect(ramp, inputRate, outputRate, [127, 256, 511, 89]);

        Assert.AreEqual(oneBlock.Length, split.Length);
        var maximumSplitError = oneBlock
            .Zip(split)
            .Select(pair => Math.Abs(pair.First - pair.Second))
            .DefaultIfEmpty()
            .Max();
        Assert.IsTrue(maximumSplitError < 0.00002f);

        var maximumBoundaryDelta = split
            .Zip(split.Skip(1))
            .Select(pair => Math.Abs(pair.Second - pair.First))
            .DefaultIfEmpty()
            .Max();
        Assert.IsTrue(maximumBoundaryDelta < 0.002f);
    }

    [TestMethod]
    public void captureHandoffTimelineUsesActualStreamingFrameCount()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            $"classscribe-streaming-timeline-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var writer = new MasterAudioWriter(Path.Combine(root, "audio-manifest.json"));
            var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
            var firstGeneration = new CaptureSourceGeneration(attempt, 1);
            var secondGeneration = new CaptureSourceGeneration(attempt, 2);
            var firstFormat = AudioPcmFormat.Create(
                48_000,
                2,
                AudioSampleEncoding.Float32LE);
            var secondFormat = AudioPcmFormat.Create(
                44_100,
                1,
                AudioSampleEncoding.PcmS16LE);
            var first = writer.PreparePacket(
                PcmAudioConverter.EncodeFloat32LE([0.1f, -0.1f, 0.2f, -0.2f]),
                firstFormat,
                firstGeneration);
            var timeline = new CaptureHandoffTimeline();
            timeline.SetFormat(first.Format);
            timeline.BeginGeneration(firstGeneration);
            var firstPlan = timeline.PreparePacket(
                firstGeneration,
                first.Bytes.Length,
                arrivalTimestamp: () => 0);
            timeline.CommitPacket(firstPlan);
            writer.CommitFrames(first.FrameCount);

            var oldTail = writer.FlushPendingPacket();
            writer.CommitFrames(oldTail.FrameCount);
            timeline.AdvanceDurableFrames(oldTail.FrameCount);
            timeline.MarkHandoff(secondGeneration);

            var second = writer.PreparePacket(
                PcmAudioConverter.EncodePcmS16LE([0.3f, -0.3f, 0.4f, -0.4f]),
                secondFormat,
                secondGeneration);
            var arrival = timeline.Snapshot.LastPacketEndTimestamp ?? 0;
            var secondPlan = timeline.PreparePacket(
                secondGeneration,
                second.Bytes.Length,
                arrivalTimestamp: () => arrival);

            Assert.IsFalse(second.IsEmpty);
            Assert.AreEqual(second.FrameCount * second.Format.BytesPerFrame, second.Bytes.Length);
            Assert.AreEqual(second.Bytes.Length, secondPlan.ByteCount);
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    private static float[] Collect(
        float[] samples,
        int inputRate,
        int outputRate,
        int[] callbackSizes)
    {
        var converter = new StreamingMasterResampler(inputRate, 1, outputRate, 1);
        var result = new List<float>();
        var offset = 0;
        var callback = 0;
        while (offset < samples.Length)
        {
            var requested = callbackSizes[callback % callbackSizes.Length];
            var count = Math.Min(requested, samples.Length - offset);
            result.AddRange(converter.Process(samples.AsSpan(offset, count)));
            offset += count;
            callback++;
        }

        result.AddRange(converter.Finish());
        Assert.AreEqual((long)result.Count, converter.TotalOutputFrames);
        return result.ToArray();
    }

    private static long RoundedRatio(long inputFrames, int inputRate, int outputRate)
    {
        var numerator = checked(inputFrames * outputRate);
        var quotient = numerator / inputRate;
        var remainder = numerator % inputRate;
        return quotient + (remainder * 2 >= inputRate ? 1 : 0);
    }
}
