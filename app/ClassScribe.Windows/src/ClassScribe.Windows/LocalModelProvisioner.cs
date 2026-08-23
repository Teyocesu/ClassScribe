using System.Net.Http.Headers;
using System.Security.Cryptography;
using SharpCompress.Readers;

namespace ClassScribe.Windows;

internal sealed record ModelDownloadProgress(string Name, long ReceivedBytes, long TotalBytes)
{
    public double Fraction => TotalBytes <= 0 ? 0 : Math.Clamp(ReceivedBytes / (double)TotalBytes, 0, 1);
}

internal sealed record DiarizationModels(string SegmentationPath, string EmbeddingPath);

internal sealed class LocalModelProvisioner : IDisposable
{
    private const string WhisperUrl =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin";
    private const long WhisperSize = 574_041_195;
    private const string WhisperSha256 =
        "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2";

    private const string SegmentationUrl =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/"
        + "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2";
    private const long SegmentationArchiveSize = 6_958_444;
    private const string SegmentationArchiveSha256 =
        "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488";
    private const string SegmentationEntry = "sherpa-onnx-pyannote-segmentation-3-0/model.onnx";
    private const long SegmentationModelSize = 5_992_913;
    private const string SegmentationModelSha256 =
        "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079";

    private const string EmbeddingUrl =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/"
        + "wespeaker_en_voxceleb_resnet34.onnx";
    private const long EmbeddingSize = 26_534_365;
    private const string EmbeddingSha256 =
        "5ef208a9da1453335308a6b6f4e6dfbd7e183a38b604de0a57664f45d257fe94";

    private readonly HttpClient httpClient;
    private readonly SemaphoreSlim whisperGate = new(1, 1);
    private readonly SemaphoreSlim diarizationGate = new(1, 1);

    public LocalModelProvisioner(string? root = null)
    {
        Root = root ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ClassScribe",
            "Models");
        httpClient = new HttpClient
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
        httpClient.DefaultRequestHeaders.UserAgent.Add(
            new ProductInfoHeaderValue("ClassScribe", "1.0"));
    }

    public string Root { get; }

    public async Task<string> EnsureWhisperAsync(
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        await whisperGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureSafeModelRoot();
            return await EnsureFileAsync(
                    new Uri(WhisperUrl),
                    Path.Combine(Root, "whisper", "ggml-large-v3-turbo-q5_0.bin"),
                    "modelo de transcripción",
                    WhisperSize,
                    WhisperSha256,
                    progress,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            whisperGate.Release();
        }
    }

    public async Task<DiarizationModels> EnsureDiarizationAsync(
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        await diarizationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureSafeModelRoot();
            var segmentationDirectory = Path.Combine(Root, "diarization", "pyannote-segmentation-3.0");
            EnsureSafeModelDirectory(segmentationDirectory);
            var segmentationPath = Path.Combine(segmentationDirectory, "model.onnx");
            if (!await IsExpectedFileAsync(
                    segmentationPath,
                    SegmentationModelSize,
                    SegmentationModelSha256,
                    cancellationToken).ConfigureAwait(false))
            {
                var archivePath = await EnsureFileAsync(
                        new Uri(SegmentationUrl),
                        Path.Combine(Root, "downloads", "pyannote-segmentation-3.0.tar.bz2"),
                        "modelo de separación de hablantes",
                        SegmentationArchiveSize,
                        SegmentationArchiveSha256,
                        progress,
                        cancellationToken)
                    .ConfigureAwait(false);
                await ExtractSingleModelAsync(
                        archivePath,
                        SegmentationEntry,
                        segmentationPath,
                        SegmentationModelSize,
                        SegmentationModelSha256,
                        cancellationToken)
                    .ConfigureAwait(false);
            }

            var embeddingPath = await EnsureFileAsync(
                    new Uri(EmbeddingUrl),
                    Path.Combine(Root, "diarization", "wespeaker-resnet34.onnx"),
                    "modelo de voces",
                    EmbeddingSize,
                    EmbeddingSha256,
                    progress,
                    cancellationToken)
                .ConfigureAwait(false);
            return new DiarizationModels(segmentationPath, embeddingPath);
        }
        finally
        {
            diarizationGate.Release();
        }
    }

    public void Dispose()
    {
        httpClient.Dispose();
        whisperGate.Dispose();
        diarizationGate.Dispose();
    }

    private async Task<string> EnsureFileAsync(
        Uri uri,
        string destination,
        string displayName,
        long expectedSize,
        string expectedHash,
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(destination)
            ?? throw new InvalidOperationException("El modelo necesita una carpeta de destino.");
        EnsureSafeModelDirectory(directory);
        if (await IsExpectedFileAsync(destination, expectedSize, expectedHash, cancellationToken)
                .ConfigureAwait(false))
        {
            return destination;
        }

        var temporary = Path.Combine(directory, $".classscribe-download-{Guid.NewGuid():N}.tmp");

        try
        {
            using var response = await httpClient.GetAsync(
                    uri,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken)
                .ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            if (!string.Equals(
                    response.RequestMessage?.RequestUri?.Scheme,
                    Uri.UriSchemeHttps,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException($"La descarga del {displayName} salió del canal HTTPS.");
            }
            if (response.Content.Headers.ContentLength is long declaredLength
                && declaredLength != expectedSize)
            {
                throw new InvalidDataException(
                    $"El servidor informó un tamaño inesperado para el {displayName}.");
            }

            await using var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            await using var output = new FileStream(
                temporary,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                128 * 1_024,
                FileOptions.Asynchronous | FileOptions.WriteThrough);
            var buffer = new byte[128 * 1_024];
            long received = 0;
            while (true)
            {
                var count = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (count == 0)
                {
                    break;
                }

                received += count;
                if (received > expectedSize)
                {
                    throw new InvalidDataException($"La descarga del {displayName} excedió el tamaño esperado.");
                }

                await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                progress?.Report(new ModelDownloadProgress(displayName, received, expectedSize));
            }

            await output.FlushAsync(cancellationToken).ConfigureAwait(false);
            output.Flush(flushToDisk: true);
            if (received != expectedSize)
            {
                throw new InvalidDataException($"La descarga del {displayName} quedó incompleta.");
            }

            await output.DisposeAsync().ConfigureAwait(false);
            if (!await IsExpectedFileAsync(temporary, expectedSize, expectedHash, cancellationToken)
                    .ConfigureAwait(false))
            {
                throw new InvalidDataException($"La firma SHA-256 del {displayName} no coincide.");
            }

            File.Move(temporary, destination, overwrite: true);
            return destination;
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    private static async Task<bool> IsExpectedFileAsync(
        string path,
        long expectedSize,
        string expectedHash,
        CancellationToken cancellationToken)
    {
        try
        {
            if (!File.Exists(path)
                || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0
                || new FileInfo(path).Length != expectedSize)
            {
                return false;
            }

            await using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                128 * 1_024,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            var hash = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
            return string.Equals(Convert.ToHexStringLower(hash), expectedHash, StringComparison.Ordinal);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private async Task ExtractSingleModelAsync(
        string archivePath,
        string expectedEntry,
        string destination,
        long expectedSize,
        string expectedHash,
        CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(destination)
            ?? throw new InvalidOperationException("El modelo necesita una carpeta de destino.");
        EnsureSafeModelDirectory(directory);
        var temporary = Path.Combine(directory, $".classscribe-extract-{Guid.NewGuid():N}.tmp");

        try
        {
            await Task.Run(
                () =>
                {
                    using var archive = File.OpenRead(archivePath);
                    using var reader = ReaderFactory.OpenReader(archive);
                    var found = false;
                    while (reader.MoveToNextEntry())
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        var entry = reader.Entry
                            ?? throw new InvalidDataException("El archivo contiene una entrada vacía.");
                        var key = (entry.Key ?? string.Empty).Replace('\\', '/').TrimStart('/');
                        if (entry.IsDirectory
                            || !string.Equals(key, expectedEntry, StringComparison.Ordinal))
                        {
                            continue;
                        }

                        if (found || entry.Size <= 0 || entry.Size > 100 * 1_024 * 1_024)
                        {
                            throw new InvalidDataException("El archivo del modelo contiene una entrada inválida.");
                        }

                        using var output = new FileStream(
                            temporary,
                            FileMode.CreateNew,
                            FileAccess.Write,
                            FileShare.None);
                        reader.WriteEntryTo(output);
                        output.Flush(flushToDisk: true);
                        found = true;
                    }

                    if (!found)
                    {
                        throw new InvalidDataException("No se encontró el modelo esperado dentro del archivo.");
                    }
                },
                cancellationToken).ConfigureAwait(false);

            if (!await IsExpectedFileAsync(temporary, expectedSize, expectedHash, cancellationToken)
                    .ConfigureAwait(false))
            {
                throw new InvalidDataException("La firma del modelo extraído no coincide.");
            }

            File.Move(temporary, destination, overwrite: true);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    private void EnsureSafeModelRoot()
    {
        Directory.CreateDirectory(Root);
        RejectReparsePoint(Root);
    }

    private void EnsureSafeModelDirectory(string directory)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Root));
        var target = Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory));
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        if (!string.Equals(target, root, comparison)
            && !target.StartsWith(root + Path.DirectorySeparatorChar, comparison))
        {
            throw new UnauthorizedAccessException("Los modelos deben permanecer dentro de ClassScribe.");
        }

        EnsureSafeModelRoot();
        var current = root;
        var relative = Path.GetRelativePath(root, target);
        foreach (var component in relative.Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            Directory.CreateDirectory(current);
            RejectReparsePoint(current);
        }
    }

    private static void RejectReparsePoint(string directory)
    {
        if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException("La carpeta de modelos no puede ser un enlace o punto de unión.");
        }
    }
}
