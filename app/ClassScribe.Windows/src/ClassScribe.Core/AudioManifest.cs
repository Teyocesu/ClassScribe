using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClassScribe.Core;

public sealed record AudioManifestMaster
{
    [JsonPropertyName("relativePath")]
    public string RelativePath { get; init; } = "master.raw";

    [JsonPropertyName("encoding")]
    public string Encoding { get; init; } = "float32LE";

    [JsonPropertyName("sampleRate")]
    public int SampleRate { get; init; }

    [JsonPropertyName("channels")]
    public int Channels { get; init; }
}

public sealed record AudioManifestAsrDerivative
{
    [JsonPropertyName("relativePath")]
    public string RelativePath { get; init; } = "source.wav";

    [JsonPropertyName("encoding")]
    public string Encoding { get; init; } = "pcm_s16le";

    [JsonPropertyName("sampleRate")]
    public int SampleRate { get; init; } = PcmWaveFile.SampleRate;

    [JsonPropertyName("channels")]
    public int Channels { get; init; } = PcmWaveFile.Channels;
}

public sealed record AudioManifestConversion
{
    [JsonPropertyName("sourceGeneration")]
    public long SourceGeneration { get; init; }

    [JsonPropertyName("inputSampleRate")]
    public int InputSampleRate { get; init; }

    [JsonPropertyName("inputChannels")]
    public int InputChannels { get; init; }

    [JsonPropertyName("outputSampleRate")]
    public int OutputSampleRate { get; init; }

    [JsonPropertyName("outputChannels")]
    public int OutputChannels { get; init; }
}

public sealed record AudioManifest
{
    [JsonPropertyName("version")]
    public int Version { get; init; } = 1;

    [JsonPropertyName("master")]
    public AudioManifestMaster Master { get; init; } = new();

    [JsonPropertyName("asrDerivative")]
    public AudioManifestAsrDerivative AsrDerivative { get; init; } = new();

    [JsonPropertyName("conversions")]
    public IReadOnlyList<AudioManifestConversion> Conversions { get; init; } = [];
}

public static class AudioManifestFile
{
    private const long MaximumManifestBytes = 1 * 1_024 * 1_024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
    };

    public static AudioManifest ReadValidated(string path)
    {
        EnsureRegularFile(path);
        var info = new FileInfo(path);
        if (info.Length <= 0 || info.Length > MaximumManifestBytes)
        {
            throw new InvalidDataException("El manifest de audio no tiene un tamaño válido.");
        }

        var manifest = JsonSerializer.Deserialize<AudioManifest>(File.ReadAllText(path), JsonOptions)
            ?? throw new InvalidDataException("El manifest de audio está vacío.");
        Validate(manifest);
        return manifest;
    }

    public static void Validate(AudioManifest manifest)
    {
        ArgumentNullException.ThrowIfNull(manifest);
        if (manifest.Version != 1 || manifest.Master is null || manifest.AsrDerivative is null)
        {
            throw new InvalidDataException($"El manifest de audio no tiene una versión o estructura compatible: {manifest.Version}.");
        }

        if (!IsSafeRelativePath(manifest.Master.RelativePath)
            || !IsSafeRelativePath(manifest.AsrDerivative.RelativePath))
        {
            throw new InvalidDataException("El manifest contiene una ruta relativa insegura.");
        }

        if (!string.Equals(manifest.Master.RelativePath, "master.raw", StringComparison.Ordinal)
            || !string.Equals(manifest.Master.Encoding, "float32LE", StringComparison.Ordinal)
            || manifest.Master.SampleRate <= 0
            || manifest.Master.Channels is < 1 or > 2)
        {
            throw new InvalidDataException("El formato master del manifest no es compatible.");
        }

        if (!string.Equals(manifest.AsrDerivative.RelativePath, "source.wav", StringComparison.Ordinal)
            || !string.Equals(manifest.AsrDerivative.Encoding, "pcm_s16le", StringComparison.Ordinal)
            || manifest.AsrDerivative.SampleRate != PcmWaveFile.SampleRate
            || manifest.AsrDerivative.Channels != PcmWaveFile.Channels)
        {
            throw new InvalidDataException("El derivado ASR del manifest no es compatible.");
        }

        foreach (var conversion in manifest.Conversions ?? [])
        {
            if (conversion.SourceGeneration < 1
                || conversion.InputSampleRate <= 0
                || conversion.InputChannels <= 0
                || conversion.OutputSampleRate != manifest.Master.SampleRate
                || conversion.OutputChannels != manifest.Master.Channels)
            {
                throw new InvalidDataException("El evento de conversión del manifest no es válido.");
            }
        }
    }

    public static void WriteAtomic(string path, AudioManifest manifest)
    {
        Validate(manifest);
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException("El manifest necesita una carpeta de destino.");
        Directory.CreateDirectory(directory);
        EnsureDirectory(directory);
        if (File.Exists(path))
        {
            EnsureRegularFile(path);
        }

        var temporary = Path.Combine(directory, $".classscribe-manifest-{Guid.NewGuid():N}.tmp");
        try
        {
            var json = JsonSerializer.Serialize(manifest, JsonOptions);
            using (var stream = new FileStream(
                       temporary,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       16 * 1_024,
                       FileOptions.WriteThrough))
            {
                using var writer = new StreamWriter(stream);
                writer.Write(json);
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    public static string ResolveWithinSession(string manifestPath, string relativePath)
    {
        if (!IsSafeRelativePath(relativePath))
        {
            throw new InvalidDataException("El manifest contiene una ruta relativa insegura.");
        }

        var directory = Path.GetDirectoryName(Path.GetFullPath(manifestPath))
            ?? throw new InvalidDataException("El manifest no tiene una carpeta válida.");
        return Path.GetFullPath(Path.Combine(directory, relativePath));
    }

    private static bool IsSafeRelativePath(string path) =>
        !string.IsNullOrWhiteSpace(path)
        && !Path.IsPathRooted(path)
        && !path.Contains(Path.DirectorySeparatorChar)
        && !path.Contains(Path.AltDirectorySeparatorChar)
        && path is not "." and not ".."
        && Path.GetFileName(path) == path;

    private static void EnsureDirectory(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint))
            != FileAttributes.Directory)
        {
            throw new UnauthorizedAccessException("La carpeta del manifest no puede ser un enlace.");
        }
    }

    private static void EnsureRegularFile(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
        {
            throw new InvalidDataException("El manifest debe ser un archivo regular.");
        }
    }
}
