using System.Diagnostics;
using System.Reflection;
using System.Text.Encodings.Web;
using System.Text.Json;
using ClassScribe.Core;
using SherpaOnnx;

namespace ClassScribe.Windows;

internal static class DiarizationWorker
{
    private const string WorkerFlag = "--classscribe-diarize";
    private const long MaximumWorkerOutputBytes = 64 * 1_024 * 1_024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static bool IsWorkerInvocation(IReadOnlyList<string> arguments) =>
        arguments.Count == 5 && string.Equals(arguments[0], WorkerFlag, StringComparison.Ordinal);

    public static int RunWorker(IReadOnlyList<string> arguments)
    {
        try
        {
            if (!IsWorkerInvocation(arguments))
            {
                return 64;
            }

            var audioPath = Path.GetFullPath(arguments[1]);
            var outputPath = Path.GetFullPath(arguments[2]);
            var segmentationPath = Path.GetFullPath(arguments[3]);
            var embeddingPath = Path.GetFullPath(arguments[4]);
            PcmWaveFile.Validate(audioPath);
            ValidateRegularModel(segmentationPath);
            ValidateRegularModel(embeddingPath);

            var config = new OfflineSpeakerDiarizationConfig();
            config.Segmentation.Pyannote.Model = segmentationPath;
            config.Segmentation.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 4);
            config.Embedding.Model = embeddingPath;
            config.Embedding.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 1, 4);
            config.Clustering.NumClusters = -1;
            config.Clustering.Threshold = 0.5f;

            using var diarizer = new OfflineSpeakerDiarization(config);
            if (PcmWaveFile.SampleRate != diarizer.SampleRate)
            {
                throw new InvalidDataException(
                    $"El diarizador requiere {diarizer.SampleRate} Hz y recibió {PcmWaveFile.SampleRate} Hz.");
            }

            var spans = diarizer.Process(PcmWaveFile.ReadSamples(audioPath))
                .Where(static span => span.End > span.Start && span.Speaker >= 0)
                .Select(static span => new DiarizationSpan
                {
                    Start = span.Start,
                    End = span.End,
                    SpeakerID = $"Persona {span.Speaker + 1}",
                    Quality = 1,
                })
                .ToArray();
            var directory = Path.GetDirectoryName(outputPath)
                ?? throw new InvalidOperationException("El resultado necesita una carpeta de destino.");
            Directory.CreateDirectory(directory);
            var temporary = Path.Combine(directory, $".diarization-{Guid.NewGuid():N}.tmp");
            try
            {
                File.WriteAllText(temporary, JsonSerializer.Serialize(spans, JsonOptions));
                File.Move(temporary, outputPath, overwrite: true);
            }
            finally
            {
                File.Delete(temporary);
            }

            return 0;
        }
        catch (Exception error)
        {
            CrashLog.Write(error);
            return 70;
        }
    }

    public static async Task<IReadOnlyList<DiarizationSpan>> RunIsolatedAsync(
        string audioPath,
        DiarizationModels models,
        CancellationToken cancellationToken)
    {
        var audioDuration = PcmWaveFile.Validate(audioPath);
        var maximumRuntime = TimeSpan.FromSeconds(Math.Clamp(
            (audioDuration * 1.5) + 120,
            300,
            3_600));
        var outputPath = Path.Combine(
            Path.GetDirectoryName(audioPath)!,
            $".diarization-{Guid.NewGuid():N}.json");
        var startInfo = CreateWorkerStartInfo();
        startInfo.ArgumentList.Add(WorkerFlag);
        startInfo.ArgumentList.Add(Path.GetFullPath(audioPath));
        startInfo.ArgumentList.Add(outputPath);
        startInfo.ArgumentList.Add(Path.GetFullPath(models.SegmentationPath));
        startInfo.ArgumentList.Add(Path.GetFullPath(models.EmbeddingPath));

        try
        {
            using var process = Process.Start(startInfo)
                ?? throw new InvalidOperationException("Windows no pudo iniciar el análisis de hablantes.");
            using var timeoutCancellation = new CancellationTokenSource(maximumRuntime);
            using var workerCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                timeoutCancellation.Token);
            try
            {
                await process.WaitForExitAsync(workerCancellation.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (
                timeoutCancellation.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                TryKill(process);
                throw new TimeoutException(
                    "El análisis aislado de hablantes excedió el tiempo seguro. "
                    + "La transcripción completa se conservó.");
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                throw;
            }

            if (process.ExitCode != 0 || !IsRegularOutput(outputPath))
            {
                throw new InvalidOperationException(
                    "El análisis aislado de hablantes falló. La transcripción completa se conservó.");
            }

            await using var stream = File.OpenRead(outputPath);
            return await JsonSerializer.DeserializeAsync<DiarizationSpan[]>(
                    stream,
                    JsonOptions,
                    cancellationToken)
                .ConfigureAwait(false) ?? [];
        }
        finally
        {
            File.Delete(outputPath);
        }
    }

    private static ProcessStartInfo CreateWorkerStartInfo()
    {
        var processPath = Environment.ProcessPath
            ?? throw new InvalidOperationException("No se pudo localizar el ejecutable de ClassScribe.");
        var startInfo = new ProcessStartInfo(processPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = AppContext.BaseDirectory,
        };
        if (string.Equals(
                Path.GetFileNameWithoutExtension(processPath),
                "dotnet",
                StringComparison.OrdinalIgnoreCase))
        {
            var assemblyPath = Assembly.GetEntryAssembly()?.Location;
            if (string.IsNullOrWhiteSpace(assemblyPath))
            {
                throw new InvalidOperationException("No se pudo localizar ClassScribe.dll.");
            }

            startInfo.ArgumentList.Add(assemblyPath);
        }

        return startInfo;
    }

    private static void ValidateRegularModel(string path)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0
            || new FileInfo(path).Length < 1_000_000)
        {
            throw new InvalidDataException("El modelo de voces no es un archivo local válido.");
        }
    }

    private static bool IsRegularOutput(string path)
    {
        try
        {
            var attributes = File.GetAttributes(path);
            var length = new FileInfo(path).Length;
            return (attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0
                && length > 0
                && length <= MaximumWorkerOutputBytes;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // The worker may have exited between the checks.
        }
    }
}
