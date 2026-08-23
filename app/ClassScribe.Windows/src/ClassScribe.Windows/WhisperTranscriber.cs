using ClassScribe.Core;
using Whisper.net;

namespace ClassScribe.Windows;

internal sealed class WhisperTranscriber : IAsyncDisposable
{
    private readonly LocalModelProvisioner models;
    private readonly SemaphoreSlim processingGate = new(1, 1);
    private WhisperFactory? factory;
    private string? loadedModelPath;

    public WhisperTranscriber(LocalModelProvisioner models)
    {
        this.models = models;
    }

    public async Task<IReadOnlyList<TranscriptSegment>> TranscribeFileAsync(
        string wavePath,
        string vocabulary,
        string languageCode,
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(
            wavePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            128 * 1_024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        return await TranscribeAsync(stream, vocabulary, languageCode, 0, progress, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<TranscriptSegment>> TranscribePcmAsync(
        ReadOnlyMemory<byte> pcm,
        string vocabulary,
        string languageCode,
        double offsetSeconds,
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        using var stream = PcmWaveFile.CreateWaveStream(pcm.Span);
        return await TranscribeAsync(stream, vocabulary, languageCode, offsetSeconds, progress, cancellationToken)
            .ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        await processingGate.WaitAsync().ConfigureAwait(false);
        try
        {
            factory?.Dispose();
            factory = null;
            loadedModelPath = null;
        }
        finally
        {
            processingGate.Release();
            processingGate.Dispose();
        }
    }

    private async Task<IReadOnlyList<TranscriptSegment>> TranscribeAsync(
        Stream wave,
        string vocabulary,
        string languageCode,
        double offsetSeconds,
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        await processingGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var modelPath = await models.EnsureWhisperAsync(progress, cancellationToken).ConfigureAwait(false);
            if (factory is null || !string.Equals(loadedModelPath, modelPath, StringComparison.Ordinal))
            {
                factory?.Dispose();
                factory = WhisperFactory.FromPath(modelPath, new WhisperFactoryOptions
                {
                    UseGpu = false,
                });
                loadedModelPath = modelPath;
            }

            var builder = factory.CreateBuilder()
                .WithLanguage(languageCode)
                .WithProbabilities();
            if (!string.IsNullOrWhiteSpace(vocabulary))
            {
                builder.WithPrompt(vocabulary.Trim());
            }

            await using var processor = builder.Build();
            var result = new List<TranscriptSegment>();
            await foreach (var segment in processor.ProcessAsync(wave, cancellationToken).ConfigureAwait(false))
            {
                var text = segment.Text.Trim();
                if (text.Length == 0)
                {
                    continue;
                }

                result.Add(new TranscriptSegment
                {
                    Start = Math.Max(0, offsetSeconds + segment.Start.TotalSeconds),
                    End = Math.Max(0, offsetSeconds + segment.End.TotalSeconds),
                    Text = text,
                    Confidence = Math.Clamp(segment.Probability, 0, 1),
                    Provisional = offsetSeconds > 0,
                });
            }

            return result;
        }
        finally
        {
            processingGate.Release();
        }
    }
}
