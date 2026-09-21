using ClassScribe.Core;
using Whisper.net;

namespace ClassScribe.Windows;

internal sealed class WhisperTranscriber : IAsyncDisposable
{
    private const float VadThreshold = 0.40f;
    private static readonly TimeSpan VadBudget = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan VadMinimumSpeech = TimeSpan.FromMilliseconds(150);
    private static readonly TimeSpan VadMergeSilence = TimeSpan.FromMilliseconds(300);

    private readonly LocalModelProvisioner models;
    private readonly SemaphoreSlim processingGate = new(1, 1);
    private readonly SemaphoreSlim vadGate = new(1, 1);
    private WhisperFactory? factory;
    private WhisperVadFactory? vadFactory;
    private bool isWarmedUp;
    private int vadUnavailable;

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
        SpeechPresenceEvidence? speechEvidence;
        await using (var vadStream = new FileStream(
                         wavePath,
                         FileMode.Open,
                         FileAccess.Read,
                         FileShare.Read,
                         128 * 1_024,
                         FileOptions.Asynchronous | FileOptions.SequentialScan))
        {
            speechEvidence = await TryDetectSpeechAsync(
                    vadStream,
                    0,
                    progress,
                    cancellationToken)
                .ConfigureAwait(false);
        }

        if (speechEvidence is not null && !speechEvidence.HasSpeech)
        {
            return [];
        }

        // Whisper always receives a fresh stream for the original file. VAD
        // only supplies acceptance evidence and never crops or concatenates it.
        await using var stream = new FileStream(
            wavePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            128 * 1_024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        return await TranscribeAsync(
                stream,
                vocabulary,
                languageCode,
                0,
                progress,
                cancellationToken,
                speechEvidence)
            .ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<TranscriptSegment>> TranscribePcmAsync(
        ReadOnlyMemory<byte> pcm,
        string vocabulary,
        string languageCode,
        double offsetSeconds,
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken,
        SpeechPresenceEvidence? speechEvidence = null)
    {
        if (pcm.Length == 0)
        {
            return [];
        }

        if (speechEvidence is null)
        {
            using var vadStream = PcmWaveFile.CreateWaveStream(pcm.Span);
            speechEvidence = await TryDetectSpeechAsync(
                    vadStream,
                    offsetSeconds,
                    progress,
                    cancellationToken)
                .ConfigureAwait(false);
        }

        if (speechEvidence is not null && !speechEvidence.HasSpeech)
        {
            return [];
        }

        using var stream = PcmWaveFile.CreateWaveStream(pcm.Span);
        return await TranscribeAsync(
                stream,
                vocabulary,
                languageCode,
                offsetSeconds,
                progress,
                cancellationToken,
                speechEvidence)
            .ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        await processingGate.WaitAsync().ConfigureAwait(false);
        try
        {
            factory?.Dispose();
            factory = null;
            isWarmedUp = false;
        }
        finally
        {
            processingGate.Release();
            processingGate.Dispose();
        }

        await vadGate.WaitAsync().ConfigureAwait(false);
        try
        {
            vadFactory?.Dispose();
            vadFactory = null;
        }
        finally
        {
            vadGate.Release();
            vadGate.Dispose();
        }
    }

    private async Task<IReadOnlyList<TranscriptSegment>> TranscribeAsync(
        Stream wave,
        string vocabulary,
        string languageCode,
        double offsetSeconds,
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken,
        SpeechPresenceEvidence? speechEvidence = null)
    {
        await processingGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureFactoryAsync(progress, cancellationToken).ConfigureAwait(false);

            var activeFactory = factory
                ?? throw new InvalidOperationException("El modelo de transcripción no quedó preparado.");
            var builder = activeFactory.CreateBuilder()
                .WithLanguage(languageCode)
                .WithThreads(Math.Clamp(Environment.ProcessorCount, 1, 16))
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

            return SpeechPresenceAcceptancePolicy.FilterSegments(result, speechEvidence);
        }
        finally
        {
            processingGate.Release();
        }
    }

    private async Task<SpeechPresenceEvidence?> TryDetectSpeechAsync(
        Stream wave,
        double offsetSeconds,
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        if (Volatile.Read(ref vadUnavailable) != 0)
        {
            ProcessingDiagnostics.Mark("vad_skipped", detail: "unavailable_for_process");
            return null;
        }

        var startedAt = ProcessingDiagnostics.Mark("vad_start");
        using var vadCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        vadCancellation.CancelAfter(VadBudget);
        try
        {
            var activeFactory = await EnsureVadFactoryAsync(
                    progress,
                    vadCancellation.Token,
                    cancellationToken)
                .ConfigureAwait(false);
            if (activeFactory is null)
            {
                Interlocked.Exchange(ref vadUnavailable, 1);
                ProcessingDiagnostics.Mark("vad_unavailable", detail: "deadline");
                return null;
            }

            cancellationToken.ThrowIfCancellationRequested();
            await using var processor = activeFactory.CreateBuilder()
                .WithThreads(Math.Clamp(Environment.ProcessorCount, 1, 16))
                .WithUseGpu(false)
                .WithThreshold(VadThreshold)
                .WithMinSpeechDuration(VadMinimumSpeech)
                .WithMinSilenceDuration(VadMergeSilence)
                .WithSpeechPadding(TimeSpan.Zero)
                .Build();
            var detected = await processor.DetectSpeechAsync(wave, vadCancellation.Token).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            var timelineOffset = double.IsFinite(offsetSeconds) ? Math.Max(0, offsetSeconds) : 0;
            var regions = detected
                .Select(segment => new SpeechPresenceRegion(
                    timelineOffset + Math.Max(0, segment.Start.TotalSeconds),
                    timelineOffset + Math.Max(0, segment.End.TotalSeconds)))
                .ToArray();
            return new SpeechPresenceEvidence(regions);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            Interlocked.Exchange(ref vadUnavailable, 1);
            ProcessingDiagnostics.Mark("vad_unavailable", detail: "deadline");
            return null;
        }
        catch (Exception error)
        {
            // VAD model download/load/inference is an acceptance aid. Any
            // failure returns nil so the caller executes the old ASR path.
            CrashLog.Write(error);
            Interlocked.Exchange(ref vadUnavailable, 1);
            ProcessingDiagnostics.Mark("vad_unavailable", detail: "failure");
            return null;
        }
        finally
        {
            ProcessingDiagnostics.Mark("vad_end", startedAt: startedAt);
        }
    }

    private async Task<WhisperVadFactory?> EnsureVadFactoryAsync(
        IProgress<ModelDownloadProgress>? progress,
        CancellationToken cancellationToken,
        CancellationToken callerCancellationToken)
    {
        await vadGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (Volatile.Read(ref vadUnavailable) != 0)
            {
                return null;
            }

            if (vadFactory is not null)
            {
                return vadFactory;
            }

            var startedAt = ProcessingDiagnostics.Mark("vad_model_load_start");
            try
            {
                var modelPath = await models.EnsureVadAsync(progress, cancellationToken).ConfigureAwait(false);
                var preparedFactory = await LoadVadFactoryAsync(modelPath, cancellationToken)
                    .ConfigureAwait(false);
                if (preparedFactory is null)
                {
                    Interlocked.Exchange(ref vadUnavailable, 1);
                    return null;
                }

                vadFactory = preparedFactory;
                return preparedFactory;
            }
            catch (OperationCanceledException) when (callerCancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception)
            {
                Interlocked.Exchange(ref vadUnavailable, 1);
                throw;
            }
            finally
            {
                ProcessingDiagnostics.Mark("vad_model_load_end", startedAt: startedAt);
            }
        }
        finally
        {
            vadGate.Release();
        }
    }

    private static async Task<WhisperVadFactory?> LoadVadFactoryAsync(
        string modelPath,
        CancellationToken cancellationToken)
    {
        var loadTask = Task.Run(
            () => WhisperVadFactory.FromPath(modelPath, new WhisperFactoryOptions
            {
                UseGpu = false,
            }));
        using var waitCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var cancellationTask = Task.Delay(Timeout.InfiniteTimeSpan, waitCancellation.Token);
        try
        {
            var completed = await Task.WhenAny(loadTask, cancellationTask).ConfigureAwait(false);
            if (completed != loadTask)
            {
                _ = ObserveTimedOutVadLoadAsync(loadTask);
                cancellationToken.ThrowIfCancellationRequested();
                return null;
            }

            return await loadTask.ConfigureAwait(false);
        }
        finally
        {
            waitCancellation.Cancel();
        }
    }

    private static async Task ObserveTimedOutVadLoadAsync(Task<WhisperVadFactory> loadTask)
    {
        try
        {
            var factory = await loadTask.ConfigureAwait(false);
            factory.Dispose();
        }
        catch (Exception)
        {
            // The caller already failed open; consume late native-load errors.
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

        var startedAt = ProcessingDiagnostics.Mark("asr_model_load_start");
        try
        {
            var modelPath = await models.EnsureWhisperAsync(progress, cancellationToken).ConfigureAwait(false);
            var preparedFactory = await Task.Run(
                    () => WhisperFactory.FromPath(modelPath, new WhisperFactoryOptions
                    {
                        // Whisper.net's packaged CPU backend is self-contained. Its
                        // CUDA backends require a separate CUDA runtime installation.
                        UseGpu = false,
                    }),
                    cancellationToken)
                .ConfigureAwait(false);
            factory = preparedFactory;
        }
        finally
        {
            ProcessingDiagnostics.Mark("asr_model_load_end", startedAt: startedAt);
        }
    }

    private async Task WarmUpAsync(CancellationToken cancellationToken)
    {
        if (isWarmedUp)
        {
            return;
        }

        var activeFactory = factory
            ?? throw new InvalidOperationException("El modelo de transcripción no quedó preparado.");
        var startedAt = ProcessingDiagnostics.Mark("asr_warmup_start");
        try
        {
            await using var processor = activeFactory.CreateBuilder()
                .WithLanguage("es")
                .WithThreads(Math.Clamp(Environment.ProcessorCount, 1, 16))
                .Build();
            using var silence = PcmWaveFile.CreateWaveStream(new byte[PcmWaveFile.SampleRate * 2]);
            await foreach (var _ in processor.ProcessAsync(silence, cancellationToken).ConfigureAwait(false))
            {
                // Discard the result: this moves native first-inference setup before capture.
            }

            isWarmedUp = true;
        }
        finally
        {
            ProcessingDiagnostics.Mark("asr_warmup_end", startedAt: startedAt);
        }
    }
}
