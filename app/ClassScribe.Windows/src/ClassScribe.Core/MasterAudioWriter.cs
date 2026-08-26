namespace ClassScribe.Core;

/// Selects and converts the durable online-session master format. It does not
/// own the file stream: WindowsAudioCapture keeps the callback lease and
/// writer channel as the single durable boundary. This object owns the format
/// decision and the manifest ordering invariant.
public sealed class MasterAudioWriter
{
    private readonly string manifestPath;
    private AudioManifest? manifest;
    private StreamingMasterResampler? resampler;
    private ConverterKey? converterKey;

    public MasterAudioWriter(string manifestPath)
    {
        this.manifestPath = Path.GetFullPath(manifestPath);
    }

    public AudioPcmFormat? Format { get; private set; }

    public AudioManifest? Manifest => manifest;

    public long FramesWritten { get; private set; }

    public double DurationSeconds => Format is { } format && format.SampleRate > 0
        ? FramesWritten / (double)format.SampleRate
        : 0;

    public MasterAudioPacket PreparePacket(
        ReadOnlySpan<byte> input,
        AudioPcmFormat inputFormat,
        CaptureSourceGeneration generation)
    {
        ArgumentNullException.ThrowIfNull(generation);
        inputFormat.EnsureValid();
        if (input.Length == 0)
        {
            return MasterAudioPacket.Empty;
        }

        if (input.Length % inputFormat.BytesPerFrame != 0)
        {
            throw new InvalidDataException("El callback PCM no contiene frames completos.");
        }

        var outputFormat = Format ?? AudioPcmFormat.Create(
            inputFormat.SampleRate,
            Math.Min(inputFormat.Channels, 2),
            AudioSampleEncoding.Float32LE);
        var key = new ConverterKey(
            generation.Number,
            inputFormat.SampleRate,
            inputFormat.Channels,
            inputFormat.Encoding);
        if (converterKey is not null && converterKey != key)
        {
            throw new InvalidOperationException(
                "El conversor master anterior debe drenarse antes de cambiar de formato o generación.");
        }

        var conversion = inputFormat.SampleRate != outputFormat.SampleRate
            || inputFormat.Channels != outputFormat.Channels;
        if (Format is null)
        {
            var candidateManifest = new AudioManifest
            {
                Master = new AudioManifestMaster
                {
                    SampleRate = outputFormat.SampleRate,
                    Channels = outputFormat.Channels,
                },
                Conversions = conversion
                    ? [CreateConversion(generation.Number, inputFormat, outputFormat)]
                    : [],
            };
            // This write must complete before the first master bytes are
            // returned to the durable channel. A crash can then interpret the
            // file without guessing its format.
            AudioManifestFile.WriteAtomic(manifestPath, candidateManifest);
            Format = outputFormat;
            manifest = candidateManifest;
        }
        else if (conversion)
        {
            var conversionAlreadyRecorded = manifest!.Conversions.Any(existing =>
                existing.SourceGeneration == generation.Number
                && existing.InputSampleRate == inputFormat.SampleRate
                && existing.InputChannels == inputFormat.Channels);
            if (!conversionAlreadyRecorded)
            {
                manifest = manifest with
                {
                    Conversions = manifest.Conversions
                        .Append(CreateConversion(generation.Number, inputFormat, outputFormat))
                        .ToArray(),
                };
                AudioManifestFile.WriteAtomic(manifestPath, manifest);
            }
        }

        if (resampler is null)
        {
            resampler = new StreamingMasterResampler(
                inputFormat.SampleRate,
                inputFormat.Channels,
                outputFormat.SampleRate,
                outputFormat.Channels);
            converterKey = key;
        }

        var samples = resampler.Process(PcmAudioConverter.Decode(input, inputFormat));
        return new MasterAudioPacket(
            PcmAudioConverter.EncodeFloat32LE(samples),
            samples.Length / outputFormat.Channels,
            outputFormat);
    }

    public bool RequiresConverterReset(
        AudioPcmFormat inputFormat,
        CaptureSourceGeneration generation)
    {
        ArgumentNullException.ThrowIfNull(generation);
        inputFormat.EnsureValid();
        return resampler is not null
            && converterKey != new ConverterKey(
                generation.Number,
                inputFormat.SampleRate,
                inputFormat.Channels,
                inputFormat.Encoding);
    }

    /// Returns the old stream's deterministic look-ahead tail and resets the
    /// converter. The caller must enqueue and commit this packet before
    /// planning a new generation's wall-clock gap.
    public MasterAudioPacket FlushPendingPacket()
    {
        if (resampler is null || Format is not { } format)
        {
            return MasterAudioPacket.Empty;
        }

        var pending = resampler.Finish();
        resampler = null;
        converterKey = null;
        return new MasterAudioPacket(
            PcmAudioConverter.EncodeFloat32LE(pending),
            pending.Length / format.Channels,
            format);
    }

    public byte[] CreateSilence(int frames)
    {
        if (frames <= 0 || Format is not { } format)
        {
            return [];
        }

        return PcmAudioConverter.EncodeFloat32LE(
            new float[checked(frames * format.Channels)]);
    }

    public void CommitFrames(int frames)
    {
        if (frames < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(frames));
        }

        FramesWritten = checked(FramesWritten + frames);
    }

    public void ValidateManifest()
    {
        if (manifest is null || Format is null)
        {
            throw new InvalidDataException("La sesión online no recibió PCM master.");
        }

        AudioManifestFile.Validate(manifest);
    }

    private static AudioManifestConversion CreateConversion(
        long sourceGeneration,
        AudioPcmFormat input,
        AudioPcmFormat output) => new()
    {
        SourceGeneration = Math.Max(1, sourceGeneration),
        InputSampleRate = input.SampleRate,
        InputChannels = input.Channels,
        OutputSampleRate = output.SampleRate,
        OutputChannels = output.Channels,
    };

    private readonly record struct ConverterKey(
        long SourceGeneration,
        int InputRate,
        int InputChannels,
        AudioSampleEncoding Encoding);
}

public readonly record struct MasterAudioPacket(
    byte[] Bytes,
    int FrameCount,
    AudioPcmFormat Format)
{
    public static MasterAudioPacket Empty => new([], 0, AudioPcmFormat.Create(1, 1, AudioSampleEncoding.Float32LE));

    public bool IsEmpty => FrameCount == 0 || Bytes.Length == 0;
}
