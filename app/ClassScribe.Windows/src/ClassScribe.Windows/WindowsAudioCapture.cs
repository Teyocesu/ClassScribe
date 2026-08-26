using System.Buffers.Binary;
using System.Diagnostics;
using System.Text.Json;
using System.Threading.Channels;
using ClassScribe.Core;
using NAudio.CoreAudioApi;

namespace ClassScribe.Windows;

internal sealed class WindowsAudioCapture : IAsyncDisposable
{
    private const int AsrBytesPerSecond = PcmWaveFile.SampleRate * PcmWaveFile.Channels
        * (PcmWaveFile.BitsPerSample / 8);
    // The rebind budget is: native stop (10 s) + identity resolution (3 s) +
    // first callback (10 s), with margin for scheduler/driver variance. A
    // longer handoff is an explicit capture fault, never a silently shortened
    // recording.
    private static readonly TimeSpan RebindGapSafetyBound = TimeSpan.FromSeconds(30);
    private const int SnapshotCapacity = AsrBytesPerSecond * 45;
    private readonly object sync = new();
    private readonly Queue<byte[]> recentPackets = new();
    private readonly CaptureSourceGenerationGate sourceGenerationGate = new();
    private readonly CaptureRebindCoordinator rebindCoordinator = new();
    private readonly SystemOutputCaptureAuthorizationAuthority systemOutputAuthorizationAuthority = new();
    private readonly IWindowsAudioCaptureFactory captureFactory;
    private IWindowsAudioRecorder? recorder;
    private MMDevice? selectedDevice;
    private string? activeRenderEndpointID;
    private Channel<byte[]>? packetChannel;
    private FileStream? rawStream;
    private Task? writerTask;
    private TaskCompletionSource firstPacket = NewSignal();
    private TaskCompletionSource stopped = NewSignal();
    private Exception? captureFailure;
    private string? rawPath;
    private string? manifestPath;
    private MasterAudioWriter? masterWriter;
    private bool usesMasterContract;
    private AudioPcmFormat? masterFormat;
    private long masterFramesWritten;
    private SessionAttemptID? captureAttempt;
    private CaptureSourceGeneration? activeSourceGeneration;
    private AudioSourceOption? activeSource;
    private int? activeRootProcessId;
    private WindowsCaptureCallbackLifecycle? activeCallbackLifecycle;
    private Action<ReadOnlyMemory<byte>>? dataAvailableHandler;
    private Action<Exception?>? recordingStoppedHandler;
    private long capturedBytes;
    private int recentBytes;
    private CaptureHandoffTimeline packetTimeline = new(AsrBytesPerSecond);
    private Task? monitorTask;
    private long lastProbeTimestamp;
    private int rebindFailureCount;
    private SessionAttemptID? noCallbackReportedAttempt;
    private CancellationTokenSource? captureCancellation;
    private Task<Exception?>? stopRecorderTask;
    private Task<string>? stopSessionTask;
    private Func<string, CancellationToken, Task>? finalizationHookForTesting;
    private bool sessionAdmissionOpen;
    private bool stopRequested;
    private readonly CaptureSignalHealthTracker signalHealthTracker =
        new(CaptureSignalThresholds.Windows);

    public event Action<SessionAttemptID, double>? LevelChanged;

    public event Action<SessionAttemptID, CaptureSignalHealthSnapshot>? SignalHealthChanged;

    public event Action<SessionAttemptID, CaptureFault>? CaptureFaulted;

    internal WindowsAudioCapture(IWindowsAudioCaptureFactory? captureFactory = null)
    {
        this.captureFactory = captureFactory ?? new NAudioWindowsAudioCaptureFactory();
    }

    public string? LastWarning { get; private set; }

    internal CaptureFailureCategory? LastStartFailureCategory { get; private set; }

    public bool IsRecording
    {
        get
        {
            lock (sync)
            {
                return IsCaptureSessionActiveLocked;
            }
        }
    }

    private bool IsCaptureSessionActiveLocked =>
        (stopSessionTask is not null && !stopSessionTask.IsCompleted)
            || sessionAdmissionOpen
            || captureAttempt is not null
            || rawStream is not null
            || packetChannel is not null
            || writerTask is not null;

    public double DurationSeconds
    {
        get
        {
            lock (sync)
            {
                return usesMasterContract && masterFormat is { } format && format.SampleRate > 0
                    ? masterFramesWritten / (double)format.SampleRate
                    : Interlocked.Read(ref capturedBytes) / (double)AsrBytesPerSecond;
            }
        }
    }

    public CaptureSignalHealthSnapshot? SignalHealth => signalHealthTracker.Snapshot(captureAttempt);

    public static IReadOnlyList<AudioSourceOption> EnumerateApplications()
    {
        var ownProcessId = Environment.ProcessId;
        var sources = new List<AudioSourceOption>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    if (process.Id == ownProcessId || process.HasExited)
                    {
                        continue;
                    }

                    var title = process.MainWindowTitle.Trim();
                    if (process.MainWindowHandle == IntPtr.Zero && title.Length == 0)
                    {
                        continue;
                    }

                    var processName = process.ProcessName;
                    var identity = WindowsApplicationIdentity.FromObservation(
                        TryExecutablePath(process),
                        processName);
                    var name = title.Length == 0 ? processName : $"{processName} — {title}";
                    sources.Add(new AudioSourceOption(
                        AudioSourceKind.Process,
                        identity.StableKey,
                        name,
                        process.Id,
                        identity));
                }
                catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
                {
                    // Processes may disappear or deny access while the list is being built.
                }
            }
        }

        return sources
            .OrderBy(static source => source.Name, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(static source => source.ProcessId)
            .ToArray();
    }

    private static IReadOnlyList<WindowsProcessIncarnation> EnumerateProcessIncarnations()
    {
        var ownProcessId = Environment.ProcessId;
        var snapshots = new List<WindowsProcessIncarnation>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    if (process.Id == ownProcessId || process.HasExited)
                    {
                        continue;
                    }

                    snapshots.Add(new WindowsProcessIncarnation(
                        process.Id,
                        WindowsApplicationIdentity.FromObservation(
                            TryExecutablePath(process),
                            process.ProcessName)));
                }
                catch (Exception error) when (
                    error is InvalidOperationException or System.ComponentModel.Win32Exception)
                {
                    // The process may exit or deny access between the two
                    // observations. It is not a valid replacement candidate.
                }
            }
        }

        return snapshots;
    }

    private static string? TryExecutablePath(Process process)
    {
        try
        {
            return process.MainModule?.FileName;
        }
        catch (Exception error) when (
            error is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }

    public static IReadOnlyList<AudioSourceOption> EnumerateMicrophones()
    {
        using var enumerator = new MMDeviceEnumerator();
        using var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
        return devices
            .Select(static device => new AudioSourceOption(AudioSourceKind.Microphone, device.ID, device.FriendlyName))
            .OrderBy(static source => source.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }

    public async Task StartAsync(
        AudioSourceOption source,
        string sessionFolder,
        SessionAttemptID attempt,
        CancellationToken cancellationToken,
        SystemOutputCaptureAuthorization? systemOutputAuthorization = null)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(attempt);
        LastStartFailureCategory = null;
        if (source.Kind == AudioSourceKind.SystemOutput
            && !systemOutputAuthorizationAuthority.Accepts(systemOutputAuthorization, attempt))
        {
            throw new InvalidOperationException(
                "La captura del audio del sistema requiere una autorización explícita para este intento.");
        }
        if (cancellationToken.IsCancellationRequested)
        {
            if (source.Kind == AudioSourceKind.SystemOutput)
            {
                systemOutputAuthorizationAuthority.Invalidate(attempt);
            }
            cancellationToken.ThrowIfCancellationRequested();
        }

        lock (sync)
        {
            if (IsCaptureSessionActiveLocked)
            {
                throw new InvalidOperationException("Ya hay una grabación en curso.");
            }

            if (stopSessionTask?.IsCompleted == true)
            {
                stopSessionTask = null;
            }

            // Session ownership is reserved before a rebind can make the
            // source-generation recorder temporarily disappear.
            sessionAdmissionOpen = true;
            stopRequested = false;
            captureAttempt = attempt;
        }

        CaptureSourceGeneration sourceGeneration;
        var resourcesInitialized = false;
        try
        {
            sourceGeneration = InitializeSessionResources(source, sessionFolder, attempt);
            resourcesInitialized = true;
        }
        catch (Exception error)
        {
            LastStartFailureCategory = error is OperationCanceledException
                ? CaptureFailureCategory.Other
                : CaptureFailureCategory.Storage;
            await AbortAsync().ConfigureAwait(false);
            throw;
        }

        try
        {
            if (source.Kind == AudioSourceKind.Process)
            {
                if (source.ProcessId is null || source.Identity is null)
                {
                    throw new InvalidOperationException("La aplicación seleccionada no tiene una identidad estable verificable.");
                }

                // This is the final startup-only revalidation. The returned
                // root PID is passed directly to BuildAsync; no process
                // replacement is attempted while a recorder is running.
                var resolvedRootPID = await WindowsApplicationStartup.ResolveBeforeBuildAsync(
                    source.Identity,
                    source.ProcessId,
                    EnumerateProcessIncarnations,
                    cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                var builtRecorder = await WindowsApplicationStartup.BuildProcessLoopbackIfCurrentSourceGenerationAsync(
                    attempt,
                    sourceGeneration,
                    IsCurrentSourceGeneration,
                    () => captureFactory.BuildProcessLoopbackRecorderAsync(
                        checked((uint)resolvedRootPID),
                        cancellationToken),
                    cancellationToken).ConfigureAwait(false);
                lock (sync)
                {
                    activeRootProcessId = resolvedRootPID;
                }
                recorder = builtRecorder;
            }
            else if (source.Kind == AudioSourceKind.SystemOutput)
            {
                var renderEndpoint = captureFactory.GetDefaultRenderEndpoint();
                selectedDevice = renderEndpoint.Device;
                activeRenderEndpointID = renderEndpoint.EndpointId;
                recorder = captureFactory.BuildSystemOutputRecorder(renderEndpoint);
            }
            else
            {
                selectedDevice = captureFactory.GetDevice(source.Id);
                recorder = captureFactory.BuildDeviceRecorder(selectedDevice);
            }

            var generationRecorder = recorder
                ?? throw new InvalidOperationException("Windows no construyó el recorder de la fuente.");
            await StartRecorderGenerationAsync(
                generationRecorder,
                source,
                attempt,
                sourceGeneration,
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            LastStartFailureCategory = error is OperationCanceledException
                ? CaptureFailureCategory.Other
                : resourcesInitialized
                    ? CaptureFailureCategory.Source
                    : CaptureFailureCategory.Storage;
            try
            {
                await AbortAsync().ConfigureAwait(false);
            }
            catch (Exception cleanupError) when (cleanupError is IOException
                                                       or UnauthorizedAccessException
                                                       or InvalidDataException)
            {
                // Preserve the original startup failure. Any non-empty raw
                // audio remains available to the history recovery path.
            }
            throw;
        }
    }

    private CaptureSourceGeneration InitializeSessionResources(
        AudioSourceOption source,
        string sessionFolder,
        SessionAttemptID attempt)
    {
        lock (sync)
        {
            if (captureAttempt != attempt || stopRequested || !sessionAdmissionOpen)
            {
                throw new OperationCanceledException();
            }
        }

        Directory.CreateDirectory(sessionFolder);
        usesMasterContract = source.Kind is AudioSourceKind.Process or AudioSourceKind.SystemOutput;
        rawPath = Path.Combine(sessionFolder, usesMasterContract ? "master.raw" : "source.raw");
        manifestPath = usesMasterContract
            ? Path.Combine(sessionFolder, "audio-manifest.json")
            : null;
        masterWriter = usesMasterContract
            ? new MasterAudioWriter(manifestPath!)
            : null;
        masterFormat = null;
        masterFramesWritten = 0;
        rawStream = new FileStream(
            rawPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.Read,
            128 * 1_024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        packetChannel = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(256)
        {
            SingleReader = true,
            SingleWriter = true,
            FullMode = BoundedChannelFullMode.Wait,
        });
        writerTask = WritePacketsAsync(packetChannel.Reader, rawStream);
        firstPacket = NewSignal();
        stopped = NewSignal();
        captureFailure = null;
        LastWarning = null;
        capturedBytes = 0;
        recentBytes = 0;
        packetTimeline = usesMasterContract
            ? new CaptureHandoffTimeline()
            : new CaptureHandoffTimeline(AsrBytesPerSecond);
        packetTimeline.Reset();
        lastProbeTimestamp = 0;
        rebindFailureCount = 0;
        noCallbackReportedAttempt = null;
        captureCancellation = new CancellationTokenSource();
        var sourceGeneration = sourceGenerationGate.Begin(attempt);
        // Startup latency is not durable audio. The timeline anchors only
        // when the first non-empty PCM callback reaches the writer boundary.
        packetTimeline.BeginGeneration(sourceGeneration);
        recentPackets.Clear();
        lock (sync)
        {
            if (captureAttempt != attempt || stopRequested || !sessionAdmissionOpen)
            {
                throw new OperationCanceledException();
            }
            activeSourceGeneration = sourceGeneration;
            activeSource = source;
            activeRootProcessId = source.ProcessId;
            activeRenderEndpointID = null;
        }
        signalHealthTracker.Begin(attempt);
        PublishSignalHealth(attempt);
        return sourceGeneration;
    }

    private bool IsCurrentSourceGeneration(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation)
    {
        lock (sync)
        {
            return captureAttempt == attempt
                && !stopRequested
                && activeSourceGeneration == generation
                && sourceGenerationGate.Accepts(attempt, generation);
        }
    }

    private async Task StartRecorderGenerationAsync(
        IWindowsAudioRecorder generationRecorder,
        AudioSourceOption source,
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        CancellationToken cancellationToken)
    {
        var generationFirstPacket = NewSignal();
        var generationStopped = NewSignal();
        var generationCallbackLifecycle = new WindowsCaptureCallbackLifecycle();
        Action<ReadOnlyMemory<byte>> dataHandler = buffer =>
            HandleDataAvailable(
                attempt,
                generation,
                generationFirstPacket,
                generationCallbackLifecycle,
                generationRecorder.Format,
                buffer.Span);
        Action<Exception?> stoppedHandler = error =>
            HandleRecordingStopped(attempt, generation, generationStopped, error);

        if (!IsCurrentSourceGeneration(attempt, generation))
        {
            throw new OperationCanceledException(cancellationToken);
        }
        lock (sync)
        {
            if (stopRequested)
            {
                throw new OperationCanceledException(cancellationToken);
            }
            recorder = generationRecorder;
            firstPacket = generationFirstPacket;
            stopped = generationStopped;
            activeCallbackLifecycle = generationCallbackLifecycle;
            dataAvailableHandler = dataHandler;
            recordingStoppedHandler = stoppedHandler;
        }

        generationRecorder.DataAvailable += dataHandler;
        generationRecorder.RecordingStopped += stoppedHandler;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsCurrentSourceGeneration(attempt, generation))
            {
                throw new OperationCanceledException(cancellationToken);
            }
            generationRecorder.StartRecording();
            await generationFirstPacket.Task
                .WaitAsync(
                    TimeSpan.FromSeconds(CaptureSignalThresholds.Windows.InitialCallbackBudgetSeconds),
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (TimeoutException error)
        {
            PublishSignalHealth(attempt);
            throw new IOException(
                source.Kind switch
                {
                    AudioSourceKind.Process =>
                        "Windows no entregó audio. Reproduce sonido en la aplicación seleccionada y vuelve a intentarlo.",
                    AudioSourceKind.SystemOutput =>
                        "Windows no entregó audio de la salida del sistema. Reproduce sonido y vuelve a intentarlo.",
                    _ => "Windows no entregó audio del micrófono seleccionado.",
                },
                error);
        }
    }

    public byte[] Snapshot(TimeSpan maximumDuration)
    {
        var requestedBytes = Math.Clamp(
            (int)Math.Ceiling(maximumDuration.TotalSeconds * AsrBytesPerSecond),
            0,
            SnapshotCapacity);
        lock (sync)
        {
            var bytesToCopy = Math.Min(recentBytes, requestedBytes);
            bytesToCopy -= bytesToCopy % 2;
            if (bytesToCopy == 0)
            {
                return [];
            }

            var destination = new byte[bytesToCopy];
            var skip = recentBytes - bytesToCopy;
            var offset = 0;
            foreach (var packet in recentPackets)
            {
                if (skip >= packet.Length)
                {
                    skip -= packet.Length;
                    continue;
                }

                var sourceOffset = skip;
                var count = Math.Min(packet.Length - sourceOffset, destination.Length - offset);
                Buffer.BlockCopy(packet, sourceOffset, destination, offset, count);
                offset += count;
                skip = 0;
                if (offset == destination.Length)
                {
                    break;
                }
            }

            return destination;
        }
    }

    public async Task<string> StopAsync(CancellationToken cancellationToken)
    {
        Task<string> sessionStopTask;
        TaskCompletionSource<string>? owner = null;
        lock (sync)
        {
            if (stopSessionTask is not null)
            {
                sessionStopTask = stopSessionTask;
            }
            else
            {
                if (!IsCaptureSessionActiveLocked)
                {
                    throw new InvalidOperationException("No hay una grabación activa.");
                }

                var completion = new TaskCompletionSource<string>(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                sessionStopTask = completion.Task;
                stopSessionTask = sessionStopTask;
                owner = completion;
            }
        }

        if (owner is null)
        {
            // Followers observe the exact shared result/error. The owner's
            // cancellation token controls cleanup; a follower cannot replace
            // the single-flight result with its own cancellation.
            return await sessionStopTask.ConfigureAwait(false);
        }

        try
        {
            var path = await StopOwnedAsync(cancellationToken).ConfigureAwait(false);
            owner.TrySetResult(path);
            return path;
        }
        catch (Exception error)
        {
            owner.TrySetException(error);
            throw;
        }
    }

    private async Task<string> StopOwnedAsync(CancellationToken cancellationToken)
    {
        SessionAttemptID? stoppingAttempt;
        lock (sync)
        {
            stoppingAttempt = captureAttempt;
            stopRequested = true;
        }
        if (stoppingAttempt is not null)
        {
            captureCancellation?.Cancel();
            sourceGenerationGate.Invalidate(stoppingAttempt);
            rebindCoordinator.Cancel(stoppingAttempt);
            systemOutputAuthorizationAuthority.Invalidate(stoppingAttempt);
        }
        var stopFailure = await StopCurrentRecorderAsync(cancellationToken).ConfigureAwait(false);

        var rawPathForAttempt = await FinishCaptureResourcesAsync().ConfigureAwait(false);
        var wavePath = await FinalizeRawAsync(
                rawPathForAttempt
                    ?? throw new InvalidOperationException("No existe audio crudo para finalizar."),
                CancellationToken.None)
            .ConfigureAwait(false);
        if (captureFailure is not null || stopFailure is not null)
        {
            LastWarning = "Windows informó un problema al cerrar la fuente, pero el audio validado se conservó.";
        }

        cancellationToken.ThrowIfCancellationRequested();
        return wavePath;
    }

    public async ValueTask DisposeAsync()
    {
        await AbortAsync().ConfigureAwait(false);
    }

    private static TaskCompletionSource NewSignal() =>
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private bool IsCurrentAttempt(SessionAttemptID attempt)
    {
        lock (sync)
        {
            return captureAttempt == attempt;
        }
    }

    private bool IsStopRequested()
    {
        lock (sync)
        {
            return stopRequested;
        }
    }

    private void HandleDataAvailable(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        TaskCompletionSource generationFirstPacket,
        WindowsCaptureCallbackLifecycle callbackLifecycle,
        AudioPcmFormat inputFormat,
        ReadOnlySpan<byte> buffer)
    {
        if (!callbackLifecycle.TryEnter())
        {
            return;
        }

        try
        {
            HandleDataAvailableCore(
                attempt,
                generation,
                generationFirstPacket,
                inputFormat,
                buffer);
        }
        finally
        {
            callbackLifecycle.Leave();
        }
    }

    private void HandleDataAvailableCore(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        TaskCompletionSource generationFirstPacket,
        AudioPcmFormat inputFormat,
        ReadOnlySpan<byte> buffer)
    {
        if (!IsCurrentSourceGeneration(attempt, generation))
        {
            return;
        }

        // The first check admits the callback. A rebind can advance the source
        // generation immediately afterwards, so recheck before health mutation
        // and again immediately before the durable writer boundary.
        if (!IsCurrentSourceGeneration(attempt, generation))
        {
            return;
        }
        CaptureSignalMeasurement measurement;
        try
        {
            measurement = CaptureSignalMeasurement.FromPcm(buffer, inputFormat);
        }
        catch (Exception error) when (error is InvalidDataException or ArgumentOutOfRangeException)
        {
            FailCapture(attempt, error);
            return;
        }
        if (!signalHealthTracker.TryRecordCallback(attempt, measurement))
        {
            return;
        }
        PublishSignalHealth(attempt);
        if (buffer.Length == 0)
        {
            generationFirstPacket.TrySetResult();
            LevelChanged?.Invoke(attempt, 0);
            return;
        }

        var copy = buffer.ToArray();
        if (usesMasterContract)
        {
            HandleMasterDataAvailable(
                attempt,
                generation,
                generationFirstPacket,
                inputFormat,
                copy);
            return;
        }

        // This is the durable boundary: normal callbacks never consult a
        // clock, and only a new generation can have a pending handoff plan.
        if (!IsCurrentSourceGeneration(attempt, generation))
        {
            return;
        }

        var plan = packetTimeline.PreparePacket(
            generation,
            copy.Length,
            arrivalTimestamp: Stopwatch.GetTimestamp,
            maximumGap: RebindGapSafetyBound);
        if (plan.IsRejected)
        {
            return;
        }

        if (plan.HandoffGap.IsExplicitFailure)
        {
            var error = new IOException(
                $"La pausa de rebind ({plan.HandoffGap.GapSeconds:F1}s) excede el límite seguro de {RebindGapSafetyBound.TotalSeconds:F0}s.");
            generationFirstPacket.TrySetException(error);
            FailCapture(attempt, error);
            return;
        }

        if (plan.HandoffGap.SilenceBytes > 0)
        {
            if (!TryQueueSilence(attempt, generation, plan.HandoffGap.SilenceBytes))
            {
                return;
            }
        }

        // Keep the check adjacent to the actual packet enqueue. It closes the
        // paused-callback race where an old callback passed the first gate and
        // the generation advanced while it was copying the buffer.
        if (!IsCurrentSourceGeneration(attempt, generation)
            || !TryQueuePacket(copy))
        {
            return;
        }

        AddAsrPacketToSnapshot(copy);
        packetTimeline.CommitPacket(plan);

        generationFirstPacket.TrySetResult();
        LevelChanged?.Invoke(attempt, CalculateLevel(copy));
    }

    private void HandleMasterDataAvailable(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        TaskCompletionSource generationFirstPacket,
        AudioPcmFormat inputFormat,
        byte[] copy)
    {
        MasterAudioPacket packet;
        AudioPcmFormat durableFormat;
        lock (sync)
        {
            if (!IsCurrentSourceGeneration(attempt, generation)
                || masterWriter is null)
            {
                return;
            }

            try
            {
                packet = masterWriter.PreparePacket(copy, inputFormat, generation);
                if (packet.IsEmpty)
                {
                    return;
                }

                durableFormat = packet.Format;
                masterFormat = durableFormat;
                packetTimeline.SetFormat(durableFormat);
            }
            catch (Exception error) when (error is IOException
                                               or UnauthorizedAccessException
                                               or InvalidDataException
                                               or ArgumentOutOfRangeException
                                               or InvalidOperationException
                                               or JsonException)
            {
                FailCapture(attempt, error);
                return;
            }

            var plan = packetTimeline.PreparePacket(
                generation,
                packet.Bytes.Length,
                arrivalTimestamp: Stopwatch.GetTimestamp,
                maximumGap: RebindGapSafetyBound);
            if (plan.IsRejected)
            {
                return;
            }

            if (plan.HandoffGap.IsExplicitFailure)
            {
                var error = new IOException(
                    $"La pausa de rebind ({plan.HandoffGap.GapSeconds:F1}s) excede el límite seguro de {RebindGapSafetyBound.TotalSeconds:F0}s.");
                generationFirstPacket.TrySetException(error);
                FailCapture(attempt, error);
                return;
            }

            if (plan.HandoffGap.SilenceBytes > 0)
            {
                if (!TryQueueSilence(
                        attempt,
                        generation,
                        plan.HandoffGap.SilenceBytes,
                        durableFormat))
                {
                    return;
                }

                masterWriter.CommitFrames(plan.HandoffGap.SilenceBytes / durableFormat.BytesPerFrame);
            }

            if (!IsCurrentSourceGeneration(attempt, generation)
                || !TryQueuePacket(packet.Bytes))
            {
                return;
            }

            masterWriter.CommitFrames(packet.FrameCount);
            masterFramesWritten = masterWriter.FramesWritten;
            AddAsrPacketToSnapshot(copy, inputFormat);
            packetTimeline.CommitPacket(plan);
        }

        generationFirstPacket.TrySetResult();
        LevelChanged?.Invoke(attempt, CalculateLevel(copy, inputFormat));
    }

    private void AddAsrPacketToSnapshot(byte[] input, AudioPcmFormat format)
    {
        try
        {
            var samples = PcmAudioConverter.Convert(
                input,
                format,
                PcmWaveFile.SampleRate,
                PcmWaveFile.Channels);
            AddAsrPacketToSnapshot(PcmAudioConverter.EncodePcmS16LE(samples));
        }
        catch (Exception error) when (error is InvalidDataException or ArgumentOutOfRangeException)
        {
            // Durable master conversion already owns the capture failure
            // boundary. A malformed ASR conversion cannot reinterpret it as
            // master data or corrupt the live ring.
            captureFailure ??= error;
        }
    }

    private static byte[] CreateAsrSilence(int frames) =>
        new byte[checked(frames * PcmWaveFile.Channels * (PcmWaveFile.BitsPerSample / 8))];

    private bool TryQueueSilence(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        int silenceBytes,
        AudioPcmFormat? masterFormat = null)
    {
        const int maximumChunkBytes = 64 * 1024;
        var durableBytesPerFrame = masterFormat?.BytesPerFrame ?? 2;
        var remaining = silenceBytes - (silenceBytes % durableBytesPerFrame);
        var durableFramesQueued = 0;
        var asrFramesQueued = 0;
        var totalDurableFrames = masterFormat is { } format
            ? remaining / format.BytesPerFrame
            : 0;
        while (remaining > 0)
        {
            if (!IsCurrentSourceGeneration(attempt, generation))
            {
                return false;
            }

            var chunkBytes = Math.Min(remaining, maximumChunkBytes);
            chunkBytes -= chunkBytes % durableBytesPerFrame;
            if (chunkBytes <= 0)
            {
                return false;
            }
            var silence = new byte[chunkBytes];
            if (!TryQueuePacket(silence))
            {
                return false;
            }

            if (masterFormat is { } format)
            {
                var chunkDurableFrames = chunkBytes / format.BytesPerFrame;
                var targetAsrFrames = (int)Math.Round(
                    (durableFramesQueued + chunkDurableFrames)
                        * (double)PcmWaveFile.SampleRate / format.SampleRate,
                    MidpointRounding.AwayFromZero);
                var chunkAsrFrames = targetAsrFrames - asrFramesQueued;
                if (chunkAsrFrames > 0)
                {
                    AddAsrPacketToSnapshot(CreateAsrSilence(chunkAsrFrames));
                }

                durableFramesQueued += chunkDurableFrames;
                asrFramesQueued = targetAsrFrames;
            }
            else
            {
                AddAsrPacketToSnapshot(silence);
            }
            remaining -= chunkBytes;
        }

        if (masterFormat is { } format && totalDurableFrames > 0)
        {
            var expectedAsrFrames = Math.Max(
                1,
                (int)Math.Round(
                    totalDurableFrames * (double)PcmWaveFile.SampleRate / format.SampleRate,
                    MidpointRounding.AwayFromZero));
            if (expectedAsrFrames > asrFramesQueued)
            {
                AddAsrPacketToSnapshot(CreateAsrSilence(expectedAsrFrames - asrFramesQueued));
            }
        }

        return true;
    }

    private void FailCapture(SessionAttemptID attempt, Exception error)
    {
        var shouldPublish = false;
        lock (sync)
        {
            if (captureFailure is null)
            {
                captureFailure = error;
                shouldPublish = true;
            }
        }

        if (shouldPublish)
        {
            CaptureFaulted?.Invoke(
                attempt,
                new CaptureFault(error, CaptureFailureCategory.Source));
        }

        TryStopRecorder();
    }

    private bool TryQueuePacket(byte[] packet)
    {
        if (packetChannel?.Writer.TryWrite(packet) == true)
        {
            return true;
        }

        captureFailure ??= new IOException("El disco no pudo guardar el audio con suficiente rapidez.");
        TryStopRecorder();
        return false;
    }

    private void AddAsrPacketToSnapshot(byte[] packet)
    {
        Interlocked.Add(ref capturedBytes, packet.Length);
        lock (sync)
        {
            recentPackets.Enqueue(packet);
            recentBytes += packet.Length;
            while (recentBytes > SnapshotCapacity && recentPackets.TryDequeue(out var removed))
            {
                recentBytes -= removed.Length;
            }
        }
    }

    private void HandleRecordingStopped(
        SessionAttemptID attempt,
        CaptureSourceGeneration generation,
        TaskCompletionSource generationStopped,
        Exception? error)
    {
        // The generation-local waiter may be released after the gate advances;
        // only the current generation may mutate health/fault state.
        generationStopped.TrySetResult();
        if (!IsCurrentSourceGeneration(attempt, generation))
        {
            return;
        }

        captureFailure ??= error;
        if (error is not null)
        {
            CaptureFaulted?.Invoke(
                attempt,
                new CaptureFault(error, CaptureFailureCategory.Source));
        }
    }

    private async Task WritePacketsAsync(ChannelReader<byte[]> reader, FileStream destination)
    {
        var bytesSinceDurableFlush = 0;
        try
        {
            await foreach (var packet in reader.ReadAllAsync().ConfigureAwait(false))
            {
                await destination.WriteAsync(packet).ConfigureAwait(false);
                bytesSinceDurableFlush += packet.Length;
                if (bytesSinceDurableFlush >= 512 * 1_024)
                {
                    await destination.FlushAsync().ConfigureAwait(false);
                    destination.Flush(flushToDisk: true);
                    bytesSinceDurableFlush = 0;
                }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            captureFailure ??= error;
            firstPacket.TrySetException(error);
            TryStopRecorder();
        }
    }

    private async Task AbortAsync()
    {
        SessionAttemptID? attempt;
        lock (sync)
        {
            attempt = captureAttempt;
            if (attempt is not null || IsCaptureSessionActiveLocked)
            {
                stopRequested = true;
            }
        }
        if (attempt is not null)
        {
            captureCancellation?.Cancel();
            sourceGenerationGate.Invalidate(attempt);
            rebindCoordinator.Cancel(attempt);
            systemOutputAuthorizationAuthority.Invalidate(attempt);
        }
        _ = await StopCurrentRecorderAsync(CancellationToken.None).ConfigureAwait(false);
        var rawPathForAttempt = await FinishCaptureResourcesAsync().ConfigureAwait(false);

        if (rawPathForAttempt is not null && File.Exists(rawPathForAttempt))
        {
            try
            {
                await FinalizeRawAsync(rawPathForAttempt, CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception error) when (error is IOException
                                               or UnauthorizedAccessException
                                               or InvalidDataException)
            {
                // Keep the durable master (or legacy source.raw) in place so
                // the history screen can recover it later.
            }
        }
    }

    private async Task<Exception?> StopCurrentRecorderAsync(CancellationToken cancellationToken)
    {
        Task<Exception?> stopTask;
        TaskCompletionSource<Exception?>? owner = null;
        lock (sync)
        {
            if (stopRecorderTask is not null)
            {
                stopTask = stopRecorderTask;
            }
            else
            {
                var completion = new TaskCompletionSource<Exception?>(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                stopTask = completion.Task;
                stopRecorderTask = stopTask;
                owner = completion;
            }
        }

        if (owner is null)
        {
            // A concurrent Stop/rebind shares the same native teardown. The
            // owner already receives the session cancellation token, so a
            // follower must wait for cleanup instead of abandoning it.
            return await stopTask.ConfigureAwait(false);
        }

        try
        {
            var result = await StopCurrentRecorderCoreAsync(cancellationToken)
                .ConfigureAwait(false);
            owner.TrySetResult(result);
            return result;
        }
        catch (Exception error)
        {
            owner.TrySetException(error);
            throw;
        }
        finally
        {
            lock (sync)
            {
                if (ReferenceEquals(stopRecorderTask, stopTask))
                {
                    stopRecorderTask = null;
                }
            }
        }
    }

    private async Task<Exception?> StopCurrentRecorderCoreAsync(CancellationToken cancellationToken)
    {
        IWindowsAudioRecorder? currentRecorder;
        TaskCompletionSource generationStopped;
        WindowsCaptureCallbackLifecycle? currentCallbackLifecycle;
        Action<ReadOnlyMemory<byte>>? currentDataHandler;
        Action<Exception?>? currentStoppedHandler;
        lock (sync)
        {
            currentRecorder = recorder;
            generationStopped = stopped;
            currentCallbackLifecycle = activeCallbackLifecycle;
            currentDataHandler = dataAvailableHandler;
            currentStoppedHandler = recordingStoppedHandler;
        }
        if (currentRecorder is null)
        {
            return null;
        }

        Exception? stopFailure = null;
        try
        {
            // Close admission and drain the product callback path before the
            // native recorder is stopped. The old generation remains current
            // until this completes, so no callback can cross the switch.
            if (currentCallbackLifecycle is not null)
            {
                await currentCallbackLifecycle.CloseAndWaitAsync().ConfigureAwait(false);
            }
            currentRecorder.StopRecording();
            await generationStopped.Task
                .WaitAsync(TimeSpan.FromSeconds(10), cancellationToken)
                .ConfigureAwait(false);
        }
        catch (Exception error) when (error is TimeoutException
                                           or InvalidOperationException
                                           or OperationCanceledException)
        {
            stopFailure = error;
        }

        if (currentDataHandler is not null)
        {
            currentRecorder.DataAvailable -= currentDataHandler;
        }
        if (currentStoppedHandler is not null)
        {
            currentRecorder.RecordingStopped -= currentStoppedHandler;
        }
        lock (sync)
        {
            if (ReferenceEquals(recorder, currentRecorder))
            {
                recorder = null;
                if (ReferenceEquals(activeCallbackLifecycle, currentCallbackLifecycle))
                {
                    activeCallbackLifecycle = null;
                }
                dataAvailableHandler = null;
                recordingStoppedHandler = null;
            }
        }
        try
        {
            await currentRecorder.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            stopFailure ??= error;
        }
        return stopFailure;
    }

    private async Task<string?> FinishCaptureResourcesAsync()
    {
        SessionAttemptID? finishedAttempt;
        string? rawPathForAttempt;
        lock (sync)
        {
            finishedAttempt = captureAttempt;
            rawPathForAttempt = rawPath;
            captureAttempt = null;
            activeSourceGeneration = null;
            activeSource = null;
            activeRootProcessId = null;
            monitorTask = null;
            activeProbeToken = null;
            captureCancellation = null;
            sessionAdmissionOpen = false;
            stopRequested = false;
        }

        packetChannel?.Writer.TryComplete();
        try
        {
            if (writerTask is not null)
            {
                await writerTask.ConfigureAwait(false);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            captureFailure ??= error;
        }
        finally
        {
            if (rawStream is not null)
            {
                try
                {
                    await rawStream.FlushAsync().ConfigureAwait(false);
                    rawStream.Flush(flushToDisk: true);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    captureFailure ??= error;
                }
                finally
                {
                    await rawStream.DisposeAsync().ConfigureAwait(false);
                }
            }

            selectedDevice?.Dispose();
            selectedDevice = null;
            activeRenderEndpointID = null;
            packetChannel = null;
            writerTask = null;
            rawStream = null;
            masterWriter = null;
            packetTimeline.Reset();
            if (finishedAttempt is not null)
            {
                signalHealthTracker.Invalidate(finishedAttempt);
                LevelChanged?.Invoke(finishedAttempt, 0);
            }
        }

        return rawPathForAttempt;
    }

    private async Task<string> FinalizeRawAsync(
        string source,
        CancellationToken cancellationToken)
    {
        Func<string, CancellationToken, Task>? finalizationHook;
        lock (sync)
        {
            finalizationHook = finalizationHookForTesting;
        }
        if (finalizationHook is not null)
        {
            await finalizationHook(source, cancellationToken).ConfigureAwait(false);
        }

        var wavePath = Path.Combine(Path.GetDirectoryName(source)!, "source.wav");
        if (string.Equals(
                Path.GetFileName(source),
                "master.raw",
                StringComparison.OrdinalIgnoreCase))
        {
            var manifest = Path.Combine(Path.GetDirectoryName(source)!, "audio-manifest.json");
            _ = PcmWaveFile.ValidateMaster(source, manifest);
            await PcmWaveFile.DeriveFromMasterAsync(
                    source,
                    manifest,
                    wavePath,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        else
        {
            PcmWaveFile.ValidateRaw(source);
            await PcmWaveFile.WrapRawAsync(source, wavePath, cancellationToken).ConfigureAwait(false);
            File.Delete(source);
        }
        lock (sync)
        {
            if (rawPath == source)
            {
                rawPath = null;
            }
        }
        return wavePath;
    }

    private void ScheduleApplicationProbe(
        SessionAttemptID attempt,
        CaptureSignalHealthSnapshot snapshot)
    {
        AudioSourceOption? source;
        int? rootPID;
        CancellationToken cancellationToken;
        lock (sync)
        {
            source = activeSource;
            rootPID = activeRootProcessId;
            cancellationToken = captureCancellation?.Token ?? CancellationToken.None;
            if (monitorTask is not null
                || captureAttempt != attempt
                || source is null
                || source.Kind != AudioSourceKind.Process
                || source.Identity is null
                || rootPID is null)
            {
                return;
            }
        }

        var now = Stopwatch.GetTimestamp();
        if (now - Interlocked.Read(ref lastProbeTimestamp)
                < Stopwatch.Frequency)
        {
            return;
        }
        Interlocked.Exchange(ref lastProbeTimestamp, now);
        var selectedSource = source!;
        var selectedRootPID = rootPID!.Value;
        var probeToken = Guid.NewGuid();
        var placeholder = Task.CompletedTask;
        lock (sync)
        {
            if (monitorTask is not null)
            {
                return;
            }
            activeProbeToken = probeToken;
            monitorTask = placeholder;
        }

        var probeTask = ProbeApplicationAsync(
            selectedSource,
            selectedRootPID,
            attempt,
            snapshot.State,
            cancellationToken,
            probeToken);
        lock (sync)
        {
            if (activeProbeToken == probeToken
                && ReferenceEquals(monitorTask, placeholder))
            {
                monitorTask = probeTask;
            }
        }
    }

    private void ScheduleSystemOutputProbe(SessionAttemptID attempt)
    {
        string? activeEndpointID;
        CancellationToken cancellationToken;
        lock (sync)
        {
            activeEndpointID = activeRenderEndpointID;
            cancellationToken = captureCancellation?.Token ?? CancellationToken.None;
            if (monitorTask is not null
                || captureAttempt != attempt
                || activeSource?.Kind != AudioSourceKind.SystemOutput
                || string.IsNullOrWhiteSpace(activeEndpointID))
            {
                return;
            }
        }

        var now = Stopwatch.GetTimestamp();
        if (now - Interlocked.Read(ref lastProbeTimestamp)
                < Stopwatch.Frequency)
        {
            return;
        }
        Interlocked.Exchange(ref lastProbeTimestamp, now);
        var probeToken = Guid.NewGuid();
        var placeholder = Task.CompletedTask;
        lock (sync)
        {
            if (monitorTask is not null)
            {
                return;
            }
            activeProbeToken = probeToken;
            monitorTask = placeholder;
        }

        var probeTask = ProbeSystemOutputAsync(
            activeEndpointID!,
            attempt,
            cancellationToken,
            probeToken);
        lock (sync)
        {
            if (activeProbeToken == probeToken
                && ReferenceEquals(monitorTask, placeholder))
            {
                monitorTask = probeTask;
            }
        }
    }

    private async Task ProbeSystemOutputAsync(
        string activeEndpointID,
        SessionAttemptID attempt,
        CancellationToken cancellationToken,
        Guid probeToken)
    {
        try
        {
            var observedEndpointID = await Task.Run(
                    captureFactory.GetDefaultRenderEndpointId,
                    cancellationToken)
                .WaitAsync(TimeSpan.FromSeconds(1), cancellationToken)
                .ConfigureAwait(false);
            if (!IsCurrentAttempt(attempt))
            {
                return;
            }
            if (SystemOutputEndpointPolicy.ShouldRestart(activeEndpointID, observedEndpointID))
            {
                await RebindSystemOutputAsync(attempt, cancellationToken)
                    .ConfigureAwait(false);
            }
        }
        catch (TimeoutException)
        {
            // The next health tick retries the bounded endpoint observation.
        }
        catch (OperationCanceledException)
        {
            // Stop/session replacement owns cancellation and cleanup.
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            // Endpoint enumeration can race a device removal; keep the raw
            // stream and retry on a later health tick.
        }
        finally
        {
            lock (sync)
            {
                if (monitorTask is not null && probeToken == activeProbeToken)
                {
                    monitorTask = null;
                    activeProbeToken = null;
                }
            }
        }
    }

    private async Task ProbeApplicationAsync(
        AudioSourceOption source,
        int rootPID,
        SessionAttemptID attempt,
        CaptureSignalState signalState,
        CancellationToken cancellationToken,
        Guid probeToken)
    {
        try
        {
            if (source.Identity is null)
            {
                return;
            }
            var resolution = await WindowsApplicationStartup.ResolveBeforeBuildAsync(
                source.Identity,
                rootPID,
                EnumerateProcessIncarnations,
                cancellationToken)
                .WaitAsync(TimeSpan.FromSeconds(1), cancellationToken)
                .ConfigureAwait(false);
            if (!IsCurrentAttempt(attempt))
            {
                return;
            }

            if (source.Identity.Strength == ApplicationIdentityStrength.Strong
                && resolution != rootPID)
            {
                await RebindApplicationAsync(source, attempt, resolution, cancellationToken)
                    .ConfigureAwait(false);
            }
        }
        catch (WindowsApplicationResolutionException)
        {
            // Missing/ambiguous/weak evidence never gets converted into a
            // sibling PID. The current durable stream remains available.
        }
        catch (TimeoutException)
        {
            // A bounded probe may be retried by the health timer; it never
            // blocks teardown or silently selects an unverified process.
        }
        catch (OperationCanceledException)
        {
            // Stop/session replacement owns cancellation and cleanup.
        }
        finally
        {
            lock (sync)
            {
                if (monitorTask is not null && probeToken == activeProbeToken)
                {
                    monitorTask = null;
                    activeProbeToken = null;
                }
            }
        }
    }

    private Guid? activeProbeToken;

    private async Task<bool> RebindSystemOutputAsync(
        SessionAttemptID attempt,
        CancellationToken cancellationToken)
    {
        if (!rebindCoordinator.Begin(attempt))
        {
            return false;
        }

        IWindowsAudioRecorder? builtRecorder = null;
        MMDevice? builtDevice = null;
        try
        {
            CaptureSourceGeneration? oldGeneration;
            string? oldEndpointID;
            AudioSourceOption? source;
            lock (sync)
            {
                oldGeneration = activeSourceGeneration;
                oldEndpointID = activeRenderEndpointID;
                source = activeSource;
                if (stopRequested || !IsCaptureSessionActiveLocked)
                {
                    oldGeneration = null;
                }
            }
            if (oldGeneration is null
                || source?.Kind != AudioSourceKind.SystemOutput
                || string.IsNullOrWhiteSpace(oldEndpointID))
            {
                return false;
            }

            // Close admission, drain the callback lease, and dispose the old
            // endpoint only after its recorder is fully detached. The raw file,
            // packet timeline, and attempt remain shared across generations.
            var stopFailure = await StopCurrentRecorderAsync(cancellationToken)
                .ConfigureAwait(false);
            if (!IsCurrentSourceGeneration(attempt, oldGeneration)
                || !rebindCoordinator.CanPublish(attempt)
                || IsStopRequested())
            {
                return false;
            }
            if (stopFailure is not null)
            {
                captureFailure ??= stopFailure;
            }

            MMDevice? oldDevice;
            lock (sync)
            {
                oldDevice = selectedDevice;
                selectedDevice = null;
            }
            oldDevice?.Dispose();

            var nextGeneration = sourceGenerationGate.Advance(attempt);
            if (nextGeneration is null)
            {
                return false;
            }
            lock (sync)
            {
                activeSourceGeneration = nextGeneration;
            }
            packetTimeline.MarkHandoff(nextGeneration);
            signalHealthTracker.Begin(attempt);
            PublishSignalHealth(attempt);

            if (!IsCurrentSourceGeneration(attempt, nextGeneration))
            {
                return false;
            }
            var endpoint = captureFactory.GetDefaultRenderEndpoint();
            builtDevice = endpoint.Device;
            builtRecorder = captureFactory.BuildSystemOutputRecorder(endpoint);
            await StartRecorderGenerationAsync(
                builtRecorder,
                source,
                attempt,
                nextGeneration,
                cancellationToken).ConfigureAwait(false);
            if (!IsCurrentSourceGeneration(attempt, nextGeneration)
                || !rebindCoordinator.CanPublish(attempt)
                || IsStopRequested())
            {
                throw new OperationCanceledException(cancellationToken);
            }

            lock (sync)
            {
                if (stopRequested
                    || captureAttempt != attempt
                    || activeSourceGeneration != nextGeneration
                    || !sourceGenerationGate.Accepts(attempt, nextGeneration)
                    || !rebindCoordinator.CanPublish(attempt))
                {
                    throw new OperationCanceledException(cancellationToken);
                }
                selectedDevice = builtDevice;
                activeRenderEndpointID = endpoint.EndpointId;
                activeSource = source;
            }
            builtDevice = null;
            builtRecorder = null;
            rebindFailureCount = 0;
            return true;
        }
        catch (Exception error) when (error is IOException
                                           or InvalidOperationException
                                           or TimeoutException
                                           or OperationCanceledException
                                           or System.Runtime.InteropServices.COMException)
        {
            if (builtRecorder is not null)
            {
                bool attachedToSession;
                lock (sync)
                {
                    attachedToSession = ReferenceEquals(recorder, builtRecorder);
                }
                if (attachedToSession)
                {
                    _ = await StopCurrentRecorderAsync(CancellationToken.None)
                        .ConfigureAwait(false);
                }
                else
                {
                    try
                    {
                        await builtRecorder.DisposeAsync().ConfigureAwait(false);
                    }
                    catch (Exception disposeError) when (
                        disposeError is InvalidOperationException or System.Runtime.InteropServices.COMException)
                    {
                        captureFailure ??= disposeError;
                    }
                }
            }
            builtDevice?.Dispose();
            if (IsCurrentAttempt(attempt) && rebindCoordinator.CanPublish(attempt))
            {
                rebindFailureCount++;
                if (rebindFailureCount >= 2)
                {
                    CaptureFaulted?.Invoke(
                        attempt,
                        new CaptureFault(error, CaptureFailureCategory.Source));
                }
            }
            return false;
        }
        finally
        {
            rebindCoordinator.End(attempt);
        }
    }

    private async Task<bool> RebindApplicationAsync(
        AudioSourceOption source,
        SessionAttemptID attempt,
        int resolvedRootPID,
        CancellationToken cancellationToken)
    {
        if (source.Identity is null
            || source.Identity.Strength != ApplicationIdentityStrength.Strong)
        {
            return false;
        }
        if (!rebindCoordinator.Begin(attempt))
        {
            return false;
        }

        IWindowsAudioRecorder? builtRecorder = null;
        try
        {
            CaptureSourceGeneration? oldGeneration;
            int? oldRootPID;
            lock (sync)
            {
                oldGeneration = activeSourceGeneration;
                oldRootPID = activeRootProcessId;
            }
            if (oldGeneration is null || oldRootPID is null)
            {
                return false;
            }

            // Stop and drain the old recorder while its generation is still
            // current. Only after that lease has closed may the source gate
            // publish the next generation.
            var stopFailure = await StopCurrentRecorderAsync(cancellationToken)
                .ConfigureAwait(false);
            if (!IsCurrentSourceGeneration(attempt, oldGeneration)
                || !rebindCoordinator.CanPublish(attempt))
            {
                return false;
            }
            if (stopFailure is not null)
            {
                captureFailure ??= stopFailure;
            }

            var nextGeneration = sourceGenerationGate.Advance(attempt);
            if (nextGeneration is null)
            {
                return false;
            }
            lock (sync)
            {
                activeSourceGeneration = nextGeneration;
            }

            // The first accepted non-empty PCM callback records the arrival
            // timestamp. This keeps resolve/build/start/first-callback delay
            // inside the measured gap instead of timestamping at old stop.
            packetTimeline.MarkHandoff(nextGeneration);
            signalHealthTracker.Begin(attempt);
            PublishSignalHealth(attempt);

            var refreshedRootPID = await WindowsApplicationStartup.ResolveBeforeBuildAsync(
                source.Identity,
                resolvedRootPID,
                EnumerateProcessIncarnations,
                cancellationToken)
                .WaitAsync(TimeSpan.FromSeconds(3), cancellationToken)
                .ConfigureAwait(false);
            if (refreshedRootPID == oldRootPID)
            {
                throw new IOException("La encarnación de la aplicación no cambió de forma verificable.");
            }
            if (!IsCurrentSourceGeneration(attempt, nextGeneration))
            {
                return false;
            }

            builtRecorder = await WindowsApplicationStartup.BuildProcessLoopbackIfCurrentSourceGenerationAsync(
                attempt,
                nextGeneration,
                IsCurrentSourceGeneration,
                () => captureFactory.BuildProcessLoopbackRecorderAsync(
                    checked((uint)refreshedRootPID),
                    cancellationToken),
                cancellationToken).ConfigureAwait(false);
            await StartRecorderGenerationAsync(
                builtRecorder,
                source,
                attempt,
                nextGeneration,
                cancellationToken).ConfigureAwait(false);
            builtRecorder = null;
            if (!IsCurrentSourceGeneration(attempt, nextGeneration)
                || !rebindCoordinator.CanPublish(attempt))
            {
                return false;
            }
            lock (sync)
            {
                if (stopRequested
                    || captureAttempt != attempt
                    || activeSourceGeneration != nextGeneration
                    || !sourceGenerationGate.Accepts(attempt, nextGeneration)
                    || !rebindCoordinator.CanPublish(attempt))
                {
                    return false;
                }
                activeRootProcessId = refreshedRootPID;
                activeSource = source;
            }
            rebindFailureCount = 0;
            return true;
        }
        catch (Exception error) when (error is IOException
                                           or InvalidOperationException
                                           or WindowsApplicationResolutionException
                                           or TimeoutException
                                           or OperationCanceledException)
        {
            if (builtRecorder is not null)
            {
                bool attachedToSession;
                lock (sync)
                {
                    attachedToSession = ReferenceEquals(recorder, builtRecorder);
                }
                if (attachedToSession)
                {
                    _ = await StopCurrentRecorderAsync(CancellationToken.None)
                        .ConfigureAwait(false);
                }
                else
                {
                    try
                    {
                        await builtRecorder.DisposeAsync().ConfigureAwait(false);
                    }
                    catch (Exception disposeError) when (disposeError is InvalidOperationException or System.Runtime.InteropServices.COMException)
                    {
                        captureFailure ??= disposeError;
                    }
                }
            }
            if (IsCurrentAttempt(attempt) && rebindCoordinator.CanPublish(attempt))
            {
                rebindFailureCount++;
                if (rebindFailureCount >= 2)
                {
                    CaptureFaulted?.Invoke(
                        attempt,
                        new CaptureFault(error, CaptureFailureCategory.Source));
                }
            }
            return false;
        }
        finally
        {
            rebindCoordinator.End(attempt);
        }
    }

    // Test/product seam: the public wrapper keeps the rebind boundary
    // deterministic without exposing native recorder types to Core tests.
    internal Task<bool> RebindApplicationForTestAsync(
        AudioSourceOption source,
        SessionAttemptID attempt,
        int resolvedRootPID,
        CancellationToken cancellationToken = default) =>
        RebindApplicationAsync(source, attempt, resolvedRootPID, cancellationToken);

    private void TryStopRecorder()
    {
        try
        {
            recorder?.StopRecording();
        }
        catch (InvalidOperationException)
        {
            // Already stopped or not initialized.
        }
    }

    private static double CalculateLevel(ReadOnlySpan<byte> pcm)
    {
        if (pcm.Length < 2)
        {
            return 0;
        }

        double squares = 0;
        var samples = pcm.Length / 2;
        for (var index = 0; index < samples; index++)
        {
            var sample = BinaryPrimitives.ReadInt16LittleEndian(pcm[(index * 2)..]);
            var normalized = sample / 32768d;
            squares += normalized * normalized;
        }

        var rootMeanSquare = Math.Sqrt(squares / samples);
        return Math.Clamp(rootMeanSquare * 4, 0, 1);
    }

    private static double CalculateLevel(ReadOnlySpan<byte> pcm, AudioPcmFormat format)
    {
        try
        {
            var measurement = CaptureSignalMeasurement.FromPcm(pcm, format);
            return Math.Clamp(measurement.Rms * 4, 0, 1);
        }
        catch (Exception error) when (error is InvalidDataException or ArgumentOutOfRangeException)
        {
            return 0;
        }
    }

    public CaptureSignalHealthSnapshot? EvaluateSignalHealth(SessionAttemptID attempt)
    {
        var snapshot = signalHealthTracker.Snapshot(attempt);
        if (snapshot is not null)
        {
            SignalHealthChanged?.Invoke(attempt, snapshot);
            bool isProcessSource;
            bool isSystemOutputSource;
            lock (sync)
            {
                isProcessSource = activeSource?.Kind == AudioSourceKind.Process;
                isSystemOutputSource = activeSource?.Kind == AudioSourceKind.SystemOutput;
            }
            if (isProcessSource)
            {
                ScheduleApplicationProbe(attempt, snapshot);
            }
            else if (isSystemOutputSource)
            {
                ScheduleSystemOutputProbe(attempt);
            }
            if (snapshot.State == CaptureSignalState.NoCallbacks
                && snapshot.ElapsedSinceStart >= CaptureSignalThresholds.Windows.InitialCallbackBudgetSeconds + 6
                && noCallbackReportedAttempt != attempt)
            {
                noCallbackReportedAttempt = attempt;
                CaptureFaulted?.Invoke(
                    attempt,
                    new CaptureFault(
                        new IOException("Windows dejó de entregar callbacks de audio; el audio recibido se conserva."),
                        CaptureFailureCategory.Source));
            }
        }

        return snapshot;
    }

    // This is the only product issuance boundary. The UI calls it only after
    // the explicit consent presenter returns an affirmative decision.
    internal SystemOutputCaptureAuthorization IssueSystemOutputAuthorizationAfterExplicitUserConsent(
        SessionAttemptID attempt) =>
        systemOutputAuthorizationAuthority.IssueAfterExplicitUserConsent(attempt);

    internal void InvalidateSystemOutputAuthorization(SessionAttemptID attempt) =>
        systemOutputAuthorizationAuthority.Invalidate(attempt);

    // Product-path seams for deterministic Windows lifecycle tests. They call
    // the same endpoint observation and rebind implementation used by the
    // health timer; only the factory behind WASAPI is replaceable.
    internal Task<bool> ProbeSystemOutputForTestAsync(
        SessionAttemptID attempt,
        CancellationToken cancellationToken = default) =>
        ProbeSystemOutputForTestCoreAsync(attempt, cancellationToken);

    private async Task<bool> ProbeSystemOutputForTestCoreAsync(
        SessionAttemptID attempt,
        CancellationToken cancellationToken)
    {
        string? activeEndpointID;
        lock (sync)
        {
            activeEndpointID = activeRenderEndpointID;
        }

        if (string.IsNullOrWhiteSpace(activeEndpointID) || !IsCurrentAttempt(attempt))
        {
            return false;
        }

        var observedEndpointID = await Task.Run(
                captureFactory.GetDefaultRenderEndpointId,
                cancellationToken)
            .ConfigureAwait(false);
        if (!SystemOutputEndpointPolicy.ShouldRestart(activeEndpointID, observedEndpointID))
        {
            return false;
        }

        return await RebindSystemOutputAsync(attempt, cancellationToken).ConfigureAwait(false);
    }

    internal string? ActiveRenderEndpointIDForTest
    {
        get
        {
            lock (sync)
            {
                return activeRenderEndpointID;
            }
        }
    }

    internal void SetFinalizationHookForTest(
        Func<string, CancellationToken, Task>? hook)
    {
        lock (sync)
        {
            finalizationHookForTesting = hook;
        }
    }

    private void PublishSignalHealth(SessionAttemptID attempt)
    {
        if (signalHealthTracker.Snapshot(attempt) is { } snapshot)
        {
            SignalHealthChanged?.Invoke(attempt, snapshot);
        }
    }
}
