namespace ClassScribe.Core;

/// The sample representation delivered by a native recorder. This is a
/// transport contract, not a localized display value and not an ASR format.
public enum AudioSampleEncoding
{
    PcmS16LE,
    Float32LE,
}

/// A concrete interleaved PCM format observed at a recorder boundary.
public sealed record AudioPcmFormat(
    int SampleRate,
    int Channels,
    AudioSampleEncoding Encoding,
    int BytesPerFrame)
{
    public int BytesPerSecond => checked(SampleRate * BytesPerFrame);

    public static AudioPcmFormat Create(
        int sampleRate,
        int channels,
        AudioSampleEncoding encoding) =>
        new(sampleRate, channels, encoding, checked(channels * BytesPerSample(encoding)));

    public bool IsValid =>
        SampleRate > 0
        && Channels > 0
        && Channels <= 32
        && BytesPerFrame == Channels * BytesPerSample(Encoding);

    public static int BytesPerSample(AudioSampleEncoding encoding) => encoding switch
    {
        AudioSampleEncoding.PcmS16LE => sizeof(short),
        AudioSampleEncoding.Float32LE => sizeof(float),
        _ => throw new ArgumentOutOfRangeException(nameof(encoding)),
    };

    public void EnsureValid()
    {
        if (!IsValid)
        {
            throw new InvalidDataException(
                $"El formato PCM no es válido: {SampleRate} Hz, {Channels} canales, {Encoding}, {BytesPerFrame} bytes/frame.");
        }
    }
}
