using System.Diagnostics;
using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class MasterFrameClockTests
{
    [TestMethod]
    public void tenZeroGapGenerationsKeepGlobalDurationWithinOneMasterFrame()
    {
        var root = CreateRoot();
        try
        {
            var writer = new MasterAudioWriter(Path.Combine(root, "audio-manifest.json"));
            var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
            var firstGeneration = new CaptureSourceGeneration(attempt, 1);
            var first = writer.PreparePacket(
                PcmAudioConverter.EncodeFloat32LE([0.1f]),
                AudioPcmFormat.Create(48_000, 1, AudioSampleEncoding.Float32LE),
                firstGeneration);
            writer.CommitFrames(first.FrameCount);

            for (var generationNumber = 0; generationNumber < 10; generationNumber++)
            {
                var generation = new CaptureSourceGeneration(attempt, generationNumber + 2);
                var format = AudioPcmFormat.Create(44_100, 1, AudioSampleEncoding.PcmS16LE);
                if (writer.RequiresConverterReset(format, generation))
                {
                    var drained = writer.FlushPendingPacket();
                    writer.CommitFrames(drained.FrameCount);
                }

                var packet = writer.PreparePacket(
                    PcmAudioConverter.EncodePcmS16LE(
                        Enumerable.Repeat(0.1f, 256).ToArray()),
                    format,
                    generation);
                writer.CommitFrames(packet.FrameCount);
                var tail = writer.FlushPendingPacket();
                writer.CommitFrames(tail.FrameCount);
            }

            var ideal = 1 + 2_560d * 48_000 / 44_100;
            Assert.IsNotNull(writer.FrameClock);
            Assert.IsTrue(Math.Abs(writer.FramesWritten - ideal) <= 1);
            Assert.AreEqual(writer.FrameClock!.TargetSourceFrames, writer.FramesWritten);
            Assert.AreNotEqual(1 + 279 * 10, writer.FramesWritten);
        }
        finally
        {
            DeleteRoot(root);
        }
    }

    [TestMethod]
    public void formatChangesKeepGlobalRoundingRemainder()
    {
        var root = CreateRoot();
        try
        {
            var writer = new MasterAudioWriter(Path.Combine(root, "audio-manifest.json"));
            var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
            var first = writer.PreparePacket(
                PcmAudioConverter.EncodeFloat32LE([0.1f]),
                AudioPcmFormat.Create(48_000, 1, AudioSampleEncoding.Float32LE),
                new CaptureSourceGeneration(attempt, 1));
            writer.CommitFrames(first.FrameCount);

            for (var generationNumber = 0; generationNumber < 10; generationNumber++)
            {
                var generation = new CaptureSourceGeneration(attempt, generationNumber + 2);
                var rate = generationNumber % 2 == 0 ? 44_100 : 48_000;
                var format = AudioPcmFormat.Create(rate, 1, AudioSampleEncoding.PcmS16LE);
                if (writer.RequiresConverterReset(format, generation))
                {
                    var drained = writer.FlushPendingPacket();
                    writer.CommitFrames(drained.FrameCount);
                }

                var packet = writer.PreparePacket(
                    PcmAudioConverter.EncodePcmS16LE(
                        Enumerable.Repeat(0.1f, 256).ToArray()),
                    format,
                    generation);
                writer.CommitFrames(packet.FrameCount);
                var tail = writer.FlushPendingPacket();
                writer.CommitFrames(tail.FrameCount);
            }

            var ideal = 1 + 5 * 256d * 48_000 / 44_100 + 5 * 256d;
            Assert.IsNotNull(writer.FrameClock);
            Assert.IsTrue(Math.Abs(writer.FramesWritten - ideal) <= 1);
            Assert.AreEqual(writer.FrameClock!.TargetSourceFrames, writer.FramesWritten);
        }
        finally
        {
            DeleteRoot(root);
        }
    }

    [TestMethod]
    public void drainedTailAccountedExactlyOnce()
    {
        var root = CreateRoot();
        try
        {
            var writer = new MasterAudioWriter(Path.Combine(root, "audio-manifest.json"));
            var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
            var firstGeneration = new CaptureSourceGeneration(attempt, 1);
            var secondGeneration = new CaptureSourceGeneration(attempt, 2);
            var first = writer.PreparePacket(
                PcmAudioConverter.EncodeFloat32LE([0.1f]),
                AudioPcmFormat.Create(48_000, 1, AudioSampleEncoding.Float32LE),
                firstGeneration);
            writer.CommitFrames(first.FrameCount);
            var firstTail = writer.FlushPendingPacket();
            writer.CommitFrames(firstTail.FrameCount);

            var inputFormat = AudioPcmFormat.Create(44_100, 1, AudioSampleEncoding.PcmS16LE);
            var second = writer.PreparePacket(
                PcmAudioConverter.EncodePcmS16LE(
                    Enumerable.Repeat(0.3f, 256).ToArray()),
                inputFormat,
                secondGeneration);
            writer.CommitFrames(second.FrameCount);
            var tail = writer.FlushPendingPacket();
            writer.CommitFrames(tail.FrameCount);
            var framesAfterSecondDrain = writer.FramesWritten;
            var secondTail = writer.FlushPendingPacket();
            writer.CommitFrames(secondTail.FrameCount);

            Assert.AreEqual(0, secondTail.FrameCount);
            Assert.AreEqual(framesAfterSecondDrain, writer.FramesWritten);
            Assert.AreEqual(
                first.FrameCount + firstTail.FrameCount + second.FrameCount + tail.FrameCount,
                writer.FramesWritten);
            Assert.AreEqual(writer.FrameClock!.TargetSourceFrames, writer.FramesWritten);
        }
        finally
        {
            DeleteRoot(root);
        }
    }

    [TestMethod]
    public void actualHandoffSilenceUsesLogicalMasterFrames()
    {
        var root = CreateRoot();
        try
        {
            var writer = new MasterAudioWriter(Path.Combine(root, "audio-manifest.json"));
            var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
            var firstGeneration = new CaptureSourceGeneration(attempt, 1);
            var secondGeneration = new CaptureSourceGeneration(attempt, 2);
            var firstFormat = AudioPcmFormat.Create(48_000, 1, AudioSampleEncoding.Float32LE);
            var first = writer.PreparePacket(
                PcmAudioConverter.EncodeFloat32LE(Enumerable.Repeat(0.1f, 256).ToArray()),
                firstFormat,
                firstGeneration);
            writer.CommitFrames(first.FrameCount);

            var timeline = new CaptureHandoffTimeline();
            timeline.SetFormat(first.Format);
            timeline.BeginGeneration(firstGeneration);
            var firstPlan = timeline.PreparePacket(
                firstGeneration,
                first.Bytes.Length,
                arrivalTimestamp: () => 0,
                logicalFrameCount: first.LogicalFrameCount);
            timeline.CommitPacket(firstPlan);
            var tail = writer.FlushPendingPacket();
            writer.CommitFrames(tail.FrameCount);

            timeline.MarkHandoff(secondGeneration);
            var secondFormat = AudioPcmFormat.Create(44_100, 1, AudioSampleEncoding.PcmS16LE);
            var second = writer.PreparePacket(
                PcmAudioConverter.EncodePcmS16LE(Enumerable.Repeat(0.2f, 256).ToArray()),
                secondFormat,
                secondGeneration);
            var secondPlan = timeline.PreparePacket(
                secondGeneration,
                second.Bytes.Length,
                arrivalTimestamp: () => Stopwatch.Frequency,
                logicalFrameCount: second.LogicalFrameCount);

            Assert.AreEqual(CaptureGapDisposition.Silence, secondPlan.HandoffGap.Disposition);
            Assert.IsTrue(secondPlan.HandoffGap.SilenceBytes > 0);
            Assert.AreEqual(second.LogicalFrameCount, secondPlan.LogicalFrameCount);
        }
        finally
        {
            DeleteRoot(root);
        }
    }

    private static string CreateRoot()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            $"classscribe-master-clock-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        return root;
    }

    private static void DeleteRoot(string root)
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
