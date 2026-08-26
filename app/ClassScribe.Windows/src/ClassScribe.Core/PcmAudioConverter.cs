using System.Buffers.Binary;

namespace ClassScribe.Core;

/// Small deterministic converter used at the product boundary. The durable
/// writer and the ASR derivative call it separately, so changing the ASR
/// representation cannot change the bytes or duration of the master.
public static class PcmAudioConverter
{
    public static float[] Decode(ReadOnlySpan<byte> bytes, AudioPcmFormat format)
    {
        format.EnsureValid();
        if (bytes.Length % format.BytesPerFrame != 0)
        {
            throw new InvalidDataException("El callback PCM no contiene frames completos.");
        }

        var sampleCount = checked(bytes.Length / AudioPcmFormat.BytesPerSample(format.Encoding));
        var samples = new float[sampleCount];
        for (var index = 0; index < sampleCount; index++)
        {
            var offset = index * AudioPcmFormat.BytesPerSample(format.Encoding);
            samples[index] = format.Encoding switch
            {
                AudioSampleEncoding.PcmS16LE =>
                    BinaryPrimitives.ReadInt16LittleEndian(bytes.Slice(offset, sizeof(short))) / 32768f,
                AudioSampleEncoding.Float32LE =>
                    BitConverter.Int32BitsToSingle(
                        BinaryPrimitives.ReadInt32LittleEndian(bytes.Slice(offset, sizeof(float)))),
                _ => throw new ArgumentOutOfRangeException(),
            };
        }

        return samples;
    }

    public static float[] Convert(
        ReadOnlySpan<byte> bytes,
        AudioPcmFormat input,
        int outputSampleRate,
        int outputChannels)
    {
        var decoded = Decode(bytes, input);
        return ConvertSamples(decoded, input.SampleRate, input.Channels, outputSampleRate, outputChannels);
    }

    public static float[] ConvertSamples(
        ReadOnlySpan<float> samples,
        int inputSampleRate,
        int inputChannels,
        int outputSampleRate,
        int outputChannels)
    {
        if (inputSampleRate <= 0 || inputChannels <= 0 || outputSampleRate <= 0
            || outputChannels is < 1 or > 2)
        {
            throw new ArgumentOutOfRangeException();
        }

        var inputFrameCount = samples.Length / inputChannels;
        if (inputFrameCount <= 0)
        {
            return [];
        }

        var normalized = NormalizeChannels(samples[..(inputFrameCount * inputChannels)], inputChannels, outputChannels);
        if (inputSampleRate == outputSampleRate)
        {
            return normalized;
        }

        var outputFrameCount = Math.Max(
            1,
            (int)Math.Round(
                inputFrameCount * (double)outputSampleRate / inputSampleRate,
                MidpointRounding.AwayFromZero));
        var output = new float[checked(outputFrameCount * outputChannels)];
        var sourceStep = inputSampleRate / (double)outputSampleRate;
        for (var outputFrame = 0; outputFrame < outputFrameCount; outputFrame++)
        {
            var sourcePosition = outputFrame * sourceStep;
            var lower = Math.Min(inputFrameCount - 1, (int)Math.Floor(sourcePosition));
            var upper = Math.Min(inputFrameCount - 1, lower + 1);
            var fraction = (float)(sourcePosition - lower);
            for (var channel = 0; channel < outputChannels; channel++)
            {
                var first = normalized[lower * outputChannels + channel];
                var second = normalized[upper * outputChannels + channel];
                output[outputFrame * outputChannels + channel] =
                    Sanitize(first + ((second - first) * fraction));
            }
        }

        return output;
    }

    public static byte[] EncodeFloat32LE(ReadOnlySpan<float> samples)
    {
        var bytes = new byte[checked(samples.Length * sizeof(float))];
        for (var index = 0; index < samples.Length; index++)
        {
            BinaryPrimitives.WriteInt32LittleEndian(
                bytes.AsSpan(index * sizeof(float), sizeof(float)),
                BitConverter.SingleToInt32Bits(Sanitize(samples[index])));
        }

        return bytes;
    }

    public static byte[] EncodePcmS16LE(ReadOnlySpan<float> samples)
    {
        var bytes = new byte[checked(samples.Length * sizeof(short))];
        for (var index = 0; index < samples.Length; index++)
        {
            var value = Math.Clamp(Sanitize(samples[index]), -1f, 1f);
            var pcm = value <= -1f
                ? short.MinValue
                : checked((short)Math.Round(value * short.MaxValue, MidpointRounding.AwayFromZero));
            BinaryPrimitives.WriteInt16LittleEndian(
                bytes.AsSpan(index * sizeof(short), sizeof(short)), pcm);
        }

        return bytes;
    }

    private static float[] NormalizeChannels(
        ReadOnlySpan<float> samples,
        int inputChannels,
        int outputChannels)
    {
        var frameCount = samples.Length / inputChannels;
        var normalized = new float[checked(frameCount * outputChannels)];
        for (var frame = 0; frame < frameCount; frame++)
        {
            var input = samples.Slice(frame * inputChannels, inputChannels);
            if (outputChannels == 1)
            {
                var sum = 0f;
                for (var channel = 0; channel < input.Length; channel++)
                {
                    sum += Sanitize(input[channel]);
                }

                normalized[frame] = sum / input.Length;
                continue;
            }

            if (inputChannels == 1)
            {
                normalized[frame * 2] = Sanitize(input[0]);
                normalized[(frame * 2) + 1] = normalized[frame * 2];
                continue;
            }

            if (inputChannels == 2)
            {
                normalized[frame * 2] = Sanitize(input[0]);
                normalized[(frame * 2) + 1] = Sanitize(input[1]);
                continue;
            }

            // A multichannel endpoint is reduced to stereo by averaging even
            // channels into left and odd channels into right. This keeps both
            // durable channels explicit without silently collapsing the master
            // to mono.
            var left = 0f;
            var right = 0f;
            var leftCount = 0;
            var rightCount = 0;
            for (var channel = 0; channel < input.Length; channel++)
            {
                if ((channel & 1) == 0)
                {
                    left += Sanitize(input[channel]);
                    leftCount++;
                }
                else
                {
                    right += Sanitize(input[channel]);
                    rightCount++;
                }
            }

            normalized[frame * 2] = left / Math.Max(leftCount, 1);
            normalized[(frame * 2) + 1] = right / Math.Max(rightCount, 1);
        }

        return normalized;
    }

    private static float Sanitize(float value) => float.IsFinite(value) ? value : 0;
}
