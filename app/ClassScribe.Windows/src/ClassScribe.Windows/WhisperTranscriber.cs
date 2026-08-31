using ClassScribe.Core;
using Whisper.net;

namespace ClassScribe.Windows;

internal sealed class WhisperTranscriber : IAsyncDisposable
{
    private readonly LocalModelProvisioner models;
    private readonly SemaphoreSlim processingGate = new(1, 1);
    private WhisperFactory? factory;
    private string? loadedModelPath;
    private bool isWarmedUp;

    public WhisperTranscriber(LocalModelProvisioner models)
    {
        this.models = models;
    }

    public async Task PrepareAsync(
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        await processingGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureFactoryAsync(progress, cancellationToken).ConfigureAwait(false);
            await WarmUpAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            processingGate.Release();
        }
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
            isWarmedUp = false;
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
            await EnsureFactoryAsync(progress, cancellationToken).ConfigureAwait(false);

            var activeFactory = factory
                ?? throw new InvalidOperationException("El modelo de transcripción no quedó preparado.");
            var builder = activeFactory.CreateBuilder()
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

    private async Task EnsureFactoryAsync(
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        if (factory is not null)
        {
            return;
        }

        var modelPath = await models.EnsureWhisperAsync(progress, cancellationToken).ConfigureAwait(false);
        var preparedFactory = await Task.Run(
                () => WhisperFactory.FromPath(modelPath, new WhisperFactoryOptions
                {
                    // Whisper.net probes any deployed accelerated runtime first and
                    // automatically falls back to the packaged CPU runtime.
                    UseGpu = true,
                }),
                cancellationToken)
            .ConfigureAwait(false);
        factory = preparedFactory;
        loadedModelPath = modelPath;
    }

    private async Task WarmUpAsync(CancellationToken cancellationToken)
    {
        if (isWarmedUp)
        {
            return;
        }

        var activeFactory = factory
            ?? throw new InvalidOperationException("El modelo de transcripción no quedó preparado.");
        await using var processor = activeFactory.CreateBuilder()
            .WithLanguage("es")
            .Build();
        using var silence = PcmWaveFile.CreateWaveStream(new byte[PcmWaveFile.SampleRate * 2]);
        await foreach (var _ in processor.ProcessAsync(silence, cancellationToken).ConfigureAwait(false))
        {
            // Discard the result: this moves native first-inference setup before capture.
        }

        isWarmedUp = true;
    }
}
