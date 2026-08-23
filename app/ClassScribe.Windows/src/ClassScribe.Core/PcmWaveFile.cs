using System.Buffers.Binary;

namespace ClassScribe.Core;

public static class PcmWaveFile
{
    public const int SampleRate = 16_000;
    public const short Channels = 1;
    public const short BitsPerSample = 16;
    public const string AudioFormatName = "pcm_s16le_16000_mono";
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
}
