using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class ProcessLoopbackFormatPolicyTests
{
    [TestMethod]
    public void processLoopbackDoesNotUseImplicit44100Fallback()
    {
        var observed = AudioPcmFormat.Create(48_000, 2, AudioSampleEncoding.Float32LE);

        var requested = ProcessLoopbackFormatPolicy.FromObservedRenderMix(observed);

        Assert.AreEqual(48_000, requested.SampleRate);
        Assert.AreNotEqual(44_100, requested.SampleRate);
    }

    [TestMethod]
    public void processLoopbackRequestedRateComesFromObservedRenderMix()
    {
        var observed = AudioPcmFormat.Create(96_000, 2, AudioSampleEncoding.PcmS16LE);

        var requested = ProcessLoopbackFormatPolicy.FromObservedRenderMix(observed);

        Assert.AreEqual(observed.SampleRate, requested.SampleRate);
        Assert.AreEqual(observed.Encoding, requested.Encoding);
    }

    [TestMethod]
    public void monoRenderMixRemainsMono()
    {
        var observed = AudioPcmFormat.Create(44_100, 1, AudioSampleEncoding.Float32LE);

        var requested = ProcessLoopbackFormatPolicy.FromObservedRenderMix(observed);

        Assert.AreEqual(1, requested.Channels);
    }

    [TestMethod]
    public void multichannelRenderMixIsCappedToStereo()
    {
        var observed = AudioPcmFormat.Create(48_000, 6, AudioSampleEncoding.Float32LE);

        var requested = ProcessLoopbackFormatPolicy.FromObservedRenderMix(observed);

        Assert.AreEqual(2, requested.Channels);
    }

    [TestMethod]
    public void systemOutputStillUsesActualRenderMix()
    {
        var observed = AudioPcmFormat.Create(32_000, 6, AudioSampleEncoding.PcmS16LE);

        var effective = ProcessLoopbackFormatPolicy.PreserveSystemOutputActualFormat(observed);

        Assert.AreEqual(observed, effective);
    }
}
