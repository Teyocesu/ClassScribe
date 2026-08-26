using System.Buffers.Binary;

namespace ClassScribe.Core;

public static class PcmWaveFile
{
    public const int SampleRate = 16_000;
    public const short Channels = 1;
    public const short BitsPerSample = 16;
    public const string AudioFormatName = "pcm_s16le_16000_mono";
    public const string MasterAudioFormatName = "float32le_master_manifest_v1";
    private const int HeaderSize = 44;
    private const int MaximumDataLength = int.MaxValue - HeaderSize;

    public static async Task<double> WrapRawAsync(
        string rawPath,
        string destinationPath,
        CancellationToken cancellationToken = default)
    {
        ValidateRegularFile(rawPath);
        var rawLength = new FileInfo(rawPath).Length;
        if (rawLength <= 0 || rawLength > MaximumDataLength || rawLength % 2 != 0)
        {
            throw new InvalidDataException("El audio crudo está vacío, truncado o supera el tamaño WAV compatible.");
        }

        var directory = Path.GetDirectoryName(destinationPath)
            ?? throw new InvalidOperationException("El WAV necesita una carpeta de destino.");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".classscribe-wave-{Guid.NewGuid():N}.tmp");

        try
        {
            await using (var output = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                128 * 1_024,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await output.WriteAsync(CreateHeader((int)rawLength), cancellationToken).ConfigureAwait(false);
                await using var input = new FileStream(
                    rawPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    128 * 1_024,
                    FileOptions.Asynchronous | FileOptions.SequentialScan);
                await input.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
                await output.FlushAsync(cancellationToken).ConfigureAwait(false);
                output.Flush(flushToDisk: true);
            }

            File.Move(temporary, destinationPath, overwrite: true);
        }
        finally
        {
            File.Delete(temporary);
        }

        return Validate(destinationPath);
    }

    public static MemoryStream CreateWaveStream(ReadOnlySpan<byte> pcmBytes)
    {
        if (pcmBytes.Length == 0 || pcmBytes.Length > MaximumDataLength || pcmBytes.Length % 2 != 0)
        {
            throw new ArgumentException("Los datos PCM deben contener muestras Int16 completas.", nameof(pcmBytes));
        }

        var stream = new MemoryStream(HeaderSize + pcmBytes.Length);
        stream.Write(CreateHeader(pcmBytes.Length));
        stream.Write(pcmBytes);
        stream.Position = 0;
        return stream;
    }

    public static double Validate(string path)
    {
        ValidateRegularFile(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length < HeaderSize)
        {
            throw new InvalidDataException("El WAV está vacío o contiene solamente un encabezado incompleto.");
        }

        Span<byte> root = stackalloc byte[12];
        stream.ReadExactly(root);
        if (!root[..4].SequenceEqual("RIFF"u8) || !root[8..].SequenceEqual("WAVE"u8))
        {
            throw new InvalidDataException("El archivo no es un WAV RIFF válido.");
        }

        var formatFound = false;
        long dataLength = -1;
        Span<byte> chunkHeader = stackalloc byte[8];
        Span<byte> format = stackalloc byte[16];
        while (stream.Position + chunkHeader.Length <= stream.Length)
        {
            stream.ReadExactly(chunkHeader);
            var chunkLength = BinaryPrimitives.ReadUInt32LittleEndian(chunkHeader[4..]);
            var available = stream.Length - stream.Position;
            if (chunkLength > available)
            {
                throw new InvalidDataException("El WAV declara un bloque que excede el archivo.");
            }

            if (chunkHeader[..4].SequenceEqual("fmt "u8))
            {
                if (chunkLength < 16)
                {
                    throw new InvalidDataException("El formato WAV está truncado.");
                }

                stream.ReadExactly(format);
                var encoding = BinaryPrimitives.ReadUInt16LittleEndian(format);
                var channels = BinaryPrimitives.ReadUInt16LittleEndian(format[2..]);
                var sampleRate = BinaryPrimitives.ReadUInt32LittleEndian(format[4..]);
                var bits = BinaryPrimitives.ReadUInt16LittleEndian(format[14..]);
                if (encoding != 1 || channels != Channels || sampleRate != SampleRate || bits != BitsPerSample)
                {
                    throw new InvalidDataException("ClassScribe requiere WAV PCM mono de 16 kHz y 16 bits.");
                }

                stream.Position += chunkLength - 16;
                formatFound = true;
            }
            else if (chunkHeader[..4].SequenceEqual("data"u8))
            {
                dataLength = chunkLength;
                stream.Position += chunkLength;
            }
            else
            {
                stream.Position += chunkLength;
            }

            if ((chunkLength & 1) == 1 && stream.Position < stream.Length)
            {
                stream.Position++;
            }
        }

        if (!formatFound || dataLength <= 0 || dataLength % 2 != 0)
        {
            throw new InvalidDataException("El WAV no contiene audio PCM completo.");
        }

        return dataLength / (double)(SampleRate * Channels * (BitsPerSample / 8));
    }

    public static void ValidateRaw(string path)
    {
        ValidateRegularFile(path);
        var length = new FileInfo(path).Length;
        if (length <= 0 || length > MaximumDataLength || length % 2 != 0)
        {
            throw new InvalidDataException("El audio crudo no contiene muestras Int16 completas.");
        }
    }

    /// Validates the new online-session master without imposing a RIFF/WAV
    /// size limit. The manifest is the only authority for interpreting the
    /// Float32 stream; a legacy source.raw never reaches this method.
    public static double ValidateMaster(string masterPath, string manifestPath)
    {
        var manifest = AudioManifestFile.ReadValidated(manifestPath);
        var expectedMasterPath = AudioManifestFile.ResolveWithinSession(
            manifestPath,
            manifest.Master.RelativePath);
        var actualMasterPath = Path.GetFullPath(masterPath);
        if (!string.Equals(actualMasterPath, expectedMasterPath, GetPathComparison()))
        {
            throw new InvalidDataException("El master no coincide con la ruta declarada por el manifest.");
        }

        ValidateRegularFile(masterPath);
        var length = new FileInfo(masterPath).Length;
        var bytesPerFrame = checked(manifest.Master.Channels * sizeof(float));
        if (length <= 0 || length % bytesPerFrame != 0)
        {
            throw new InvalidDataException("El master Float32 está vacío o truncado.");
        }

        return length / (double)(bytesPerFrame * manifest.Master.SampleRate);
    }

    /// Materializes the fixed ASR WAV from the authoritative master. The
    /// master and manifest are never removed, even when this operation fails.
    public static async Task<double> DeriveFromMasterAsync(
        string masterPath,
        string manifestPath,
        string destinationPath,
        CancellationToken cancellationToken = default)
    {
        var manifest = AudioManifestFile.ReadValidated(manifestPath);
        _ = ValidateMaster(masterPath, manifestPath);
        var bytesPerFrame = checked(manifest.Master.Channels * sizeof(float));
        var masterLength = new FileInfo(masterPath).Length;
        var inputFrames = masterLength / bytesPerFrame;
        var outputFrames = Math.Max(
            1,
            checked((long)Math.Round(
                inputFrames * (double)SampleRate / manifest.Master.SampleRate,
                MidpointRounding.AwayFromZero)));
        var outputBytes = checked(outputFrames * (BitsPerSample / 8));
        if (outputBytes > MaximumDataLength)
        {
            throw new InvalidDataException("El WAV derivado supera el tamaño RIFF compatible.");
        }
        var outputFramesWritten = 0L;

        var directory = Path.GetDirectoryName(destinationPath)
            ?? throw new InvalidOperationException("El WAV necesita una carpeta de destino.");
        Directory.CreateDirectory(directory);
        PreserveInvalidWaveIfPresent(destinationPath);

        var temporaryRaw = Path.Combine(directory, $".classscribe-asr-{Guid.NewGuid():N}.raw");
        try
        {
            await using (var input = new FileStream(
                       masterPath,
                       FileMode.Open,
                       FileAccess.Read,
                       FileShare.Read,
                       128 * 1_024,
                       FileOptions.Asynchronous | FileOptions.SequentialScan))
            await using (var output = new FileStream(
                       temporaryRaw,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       128 * 1_024,
                       FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                var readBuffer = new byte[1 * 1_024 * 1_024];
                var carry = Array.Empty<byte>();
                var inputFramesRead = 0L;
                var previousFrame = 0f;
                var hasPreviousFrame = false;
                while (true)
                {
                    var read = await input.ReadAsync(readBuffer, cancellationToken).ConfigureAwait(false);
                    if (read == 0)
                    {
                        break;
                    }

                    var combined = new byte[checked(carry.Length + read)];
                    carry.CopyTo(combined, 0);
                    readBuffer.AsSpan(0, read).CopyTo(combined.AsSpan(carry.Length));
                    var completeLength = combined.Length - (combined.Length % bytesPerFrame);
                    if (completeLength > 0)
                    {
                        var masterSamples = DecodeMasterMono(
                            combined.AsSpan(0, completeLength),
                            manifest.Master.Channels);
                        var blockStart = inputFramesRead;
                        var blockEnd = checked(blockStart + masterSamples.Length);
                        var asrSamples = new List<float>();
                        while (outputFramesWritten < outputFrames)
                        {
                            var sourcePosition = outputFramesWritten
                                * (double)manifest.Master.SampleRate / SampleRate;
                            var lower = Math.Clamp(
                                (long)Math.Floor(sourcePosition),
                                0,
                                inputFrames - 1);
                            // Keep the final input frame until the next block
                            // (or EOF), so interpolation is continuous across
                            // the 1 MiB read boundary.
                            if (lower >= blockEnd - 1)
                            {
                                break;
                            }

                            var first = lower < blockStart
                                ? previousFrame
                                : masterSamples[checked((int)(lower - blockStart))];
                            var upper = lower + 1;
                            var second = upper < blockStart
                                ? previousFrame
                                : masterSamples[checked((int)(upper - blockStart))];
                            var fraction = (float)(sourcePosition - lower);
                            asrSamples.Add(first + ((second - first) * fraction));
                            outputFramesWritten++;
                        }

                        if (asrSamples.Count > 0)
                        {
                            await output.WriteAsync(
                                    PcmAudioConverter.EncodePcmS16LE(asrSamples.ToArray()),
                                    cancellationToken)
                                .ConfigureAwait(false);
                        }

                        previousFrame = masterSamples[^1];
                        hasPreviousFrame = true;
                        inputFramesRead = blockEnd;
                    }

                    carry = completeLength == combined.Length
                        ? []
                        : combined[completeLength..];
                }

                if (carry.Length != 0 || inputFramesRead != inputFrames || !hasPreviousFrame)
                {
                    throw new InvalidDataException("El master termina en un frame incompleto.");
                }

                var finalSamples = new List<float>();
                while (outputFramesWritten < outputFrames)
                {
                    var sourcePosition = outputFramesWritten
                        * (double)manifest.Master.SampleRate / SampleRate;
                    var lower = Math.Clamp(
                        (long)Math.Floor(sourcePosition),
                        0,
                        inputFrames - 1);
                    if (lower < inputFrames - 1)
                    {
                        throw new InvalidDataException("No se pudo completar la conversión temporal del master.");
                    }

                    finalSamples.Add(previousFrame);
                    outputFramesWritten++;
                }
                if (finalSamples.Count > 0)
                {
                    await output.WriteAsync(
                            PcmAudioConverter.EncodePcmS16LE(finalSamples.ToArray()),
                            cancellationToken)
                        .ConfigureAwait(false);
                }

                await output.FlushAsync(cancellationToken).ConfigureAwait(false);
                output.Flush(flushToDisk: true);
            }

            if (outputFramesWritten != outputFrames)
            {
                throw new InvalidDataException("El WAV derivado no contiene la duración completa del master.");
            }

            await WrapRawAsync(temporaryRaw, destinationPath, cancellationToken).ConfigureAwait(false);
            return Validate(destinationPath);
        }
        finally
        {
            if (File.Exists(temporaryRaw))
            {
                File.Delete(temporaryRaw);
            }
        }
    }

    private static float[] DecodeMasterMono(ReadOnlySpan<byte> bytes, int channels)
    {
        var bytesPerFrame = checked(channels * sizeof(float));
        var frameCount = bytes.Length / bytesPerFrame;
        var samples = new float[frameCount];
        for (var frame = 0; frame < frameCount; frame++)
        {
            var offset = frame * bytesPerFrame;
            var sum = 0f;
            for (var channel = 0; channel < channels; channel++)
            {
                var value = BitConverter.Int32BitsToSingle(
                    BinaryPrimitives.ReadInt32LittleEndian(
                        bytes.Slice(offset + (channel * sizeof(float)), sizeof(float))));
                sum += float.IsFinite(value) ? value : 0;
            }

            samples[frame] = sum / channels;
        }

        return samples;
    }

    public static float[] ReadSamples(string path)
    {
        Validate(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        stream.Position = 12;
        Span<byte> chunkHeader = stackalloc byte[8];
        while (stream.Position + chunkHeader.Length <= stream.Length)
        {
            stream.ReadExactly(chunkHeader);
            var chunkLength = BinaryPrimitives.ReadUInt32LittleEndian(chunkHeader[4..]);
            if (chunkHeader[..4].SequenceEqual("data"u8))
            {
                var sampleCount = checked((int)(chunkLength / 2));
                var samples = new float[sampleCount];
                var buffer = new byte[128 * 1_024];
                var sampleIndex = 0;
                long remaining = chunkLength;
                while (remaining > 0)
                {
                    var bytesToRead = (int)Math.Min(buffer.Length, remaining);
                    stream.ReadExactly(buffer.AsSpan(0, bytesToRead));
                    for (var byteIndex = 0; byteIndex < bytesToRead; byteIndex += 2)
                    {
                        samples[sampleIndex++] = BinaryPrimitives.ReadInt16LittleEndian(
                            buffer.AsSpan(byteIndex, 2)) / 32768f;
                    }

                    remaining -= bytesToRead;
                }

                return samples;
            }

            stream.Position += chunkLength + (chunkLength & 1);
        }

        throw new InvalidDataException("El WAV no contiene un bloque de audio.");
    }

    private static byte[] CreateHeader(int dataLength)
    {
        var header = new byte[HeaderSize];
        "RIFF"u8.CopyTo(header);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(4), checked((uint)(36 + dataLength)));
        "WAVE"u8.CopyTo(header.AsSpan(8));
        "fmt "u8.CopyTo(header.AsSpan(12));
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(16), 16);
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(20), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(22), checked((ushort)Channels));
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(24), SampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(
            header.AsSpan(28),
            SampleRate * Channels * (BitsPerSample / 8));
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(32), Channels * (BitsPerSample / 8));
        BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(34), checked((ushort)BitsPerSample));
        "data"u8.CopyTo(header.AsSpan(36));
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(40), checked((uint)dataLength));
        return header;
    }

    private static void ValidateRegularFile(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
        {
            throw new InvalidDataException("El audio debe ser un archivo regular, no un enlace o directorio.");
        }
    }

    private static void PreserveInvalidWaveIfPresent(string path)
    {
        if (!File.Exists(path))
        {
            return;
        }

        ValidateRegularFile(path);
        try
        {
            _ = Validate(path);
            return;
        }
        catch (Exception error) when (error is IOException or InvalidDataException)
        {
            var preserved = Path.Combine(
                Path.GetDirectoryName(path)!,
                $"source-invalid-preserved-{Guid.NewGuid():N}.wav");
            File.Copy(path, preserved, overwrite: false);
        }
    }

    private static StringComparison GetPathComparison() =>
        OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
}
