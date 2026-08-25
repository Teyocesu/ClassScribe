using System.Buffers.Binary;
using System.Diagnostics;
using System.Threading.Channels;
using ClassScribe.Core;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace ClassScribe.Windows;

internal sealed class WindowsAudioCapture : IAsyncDisposable
{
    private const int BytesPerSecond = PcmWaveFile.SampleRate * PcmWaveFile.Channels
        * (PcmWaveFile.BitsPerSample / 8);
    private const int SnapshotCapacity = BytesPerSecond * 45;
    private readonly object sync = new();
    private readonly Queue<byte[]> recentPackets = new();
    private WasapiRecorder? recorder;
    private MMDevice? selectedDevice;
    private Channel<byte[]>? packetChannel;
    private FileStream? rawStream;
    private Task? writerTask;
    private TaskCompletionSource firstPacket = NewSignal();
    private TaskCompletionSource stopped = NewSignal();
    private Exception? captureFailure;
    private string? rawPath;
    private SessionAttemptID? captureAttempt;
    private CaptureDataAvailableHandler? dataAvailableHandler;
    private EventHandler<StoppedEventArgs>? recordingStoppedHandler;
    private long capturedBytes;
    private int recentBytes;

    public event Action<SessionAttemptID, double>? LevelChanged;

    public event Action<SessionAttemptID, Exception>? CaptureFaulted;

    public string? LastWarning { get; private set; }

    public bool IsRecording
    {
        get
        {
            lock (sync)
            {
                return recorder is not null;
            }
        }
    }

    public double DurationSeconds => Interlocked.Read(ref capturedBytes) / (double)BytesPerSecond;

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

                    var name = title.Length == 0 ? process.ProcessName : $"{process.ProcessName} — {title}";
                    sources.Add(new AudioSourceOption(
                        AudioSourceKind.Process,
                        process.Id.ToString(System.Globalization.CultureInfo.InvariantCulture),
                        name,
                        process.Id));
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
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(attempt);
        if (IsRecording)
        {
            throw new InvalidOperationException("Ya hay una grabación en curso.");
        }

        Directory.CreateDirectory(sessionFolder);
        rawPath = Path.Combine(sessionFolder, "source.raw");
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
        recentPackets.Clear();
        captureAttempt = attempt;

        try
        {
            var builder = new WasapiRecorderBuilder()
                .WithSharedMode()
                .WithEventSync()
                .WithFormat(new WaveFormat(PcmWaveFile.SampleRate, PcmWaveFile.BitsPerSample, PcmWaveFile.Channels))
                .WithBufferLength(100)
                .WithMmcssThreadPriority("Audio");

            if (source.Kind == AudioSourceKind.Process)
            {
                if (source.ProcessId is null)
                {
                    throw new InvalidOperationException("La aplicación seleccionada ya no tiene un proceso válido.");
                }

                recorder = await builder
                    .WithProcessLoopback(
                        checked((uint)source.ProcessId.Value),
                        ProcessLoopbackMode.IncludeTargetProcessTree)
                    .BuildAsync()
                    .ConfigureAwait(false);
            }
            else
            {
                var enumerator = new MMDeviceEnumerator();
                try
                {
                    selectedDevice = enumerator.GetDevice(source.Id);
                }
                finally
                {
                    enumerator.Dispose();
                }

                recorder = builder.WithDevice(selectedDevice).Build();
            }

            var callbackAttempt = attempt;
            dataAvailableHandler = (buffer, flags, devicePosition, qpcPosition) =>
                HandleDataAvailable(callbackAttempt, buffer, flags, devicePosition, qpcPosition);
            recordingStoppedHandler = (sender, eventArgs) =>
                HandleRecordingStopped(callbackAttempt, sender, eventArgs);
            recorder.DataAvailable += dataAvailableHandler!;
            recorder.RecordingStopped += recordingStoppedHandler!;
            recorder.StartRecording();

            try
            {
                await firstPacket.Task
                    .WaitAsync(TimeSpan.FromSeconds(10), cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (TimeoutException error)
            {
                throw new IOException(
                    source.Kind == AudioSourceKind.Process
                        ? "Windows no entregó audio. Reproduce sonido en la aplicación seleccionada y vuelve a intentarlo."
                        : "Windows no entregó audio del micrófono seleccionado.",
                    error);
            }
        }
        catch
        {
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

    public byte[] Snapshot(TimeSpan maximumDuration)
    {
        var requestedBytes = Math.Clamp(
            (int)Math.Ceiling(maximumDuration.TotalSeconds * BytesPerSecond),
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
        var currentRecorder = recorder
            ?? throw new InvalidOperationException("No hay una grabación activa.");
        Exception? stopFailure = null;
        try
        {
            currentRecorder.StopRecording();
            await stopped.Task.WaitAsync(TimeSpan.FromSeconds(10), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is TimeoutException
                                           or InvalidOperationException
                                           or OperationCanceledException)
        {
            stopFailure = error;
        }

        await FinishCaptureResourcesAsync().ConfigureAwait(false);
        var wavePath = await FinalizeRawAsync(CancellationToken.None).ConfigureAwait(false);
        if (captureFailure is not null || stopFailure is not null)
        {
            LastWarning = "Windows informó un problema al cerrar la fuente, pero el WAV fue validado y se conservó.";
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

    private void HandleDataAvailable(
        SessionAttemptID attempt,
        ReadOnlySpan<byte> buffer,
        AudioClientBufferFlags flags,
        long devicePosition,
        long qpcPosition)
    {
        if (captureAttempt != attempt)
        {
            return;
        }

        _ = flags;
        _ = devicePosition;
        _ = qpcPosition;
        if (buffer.Length == 0)
        {
            return;
        }

        var copy = buffer.ToArray();
        if (packetChannel?.Writer.TryWrite(copy) != true)
        {
            captureFailure ??= new IOException("El disco no pudo guardar el audio con suficiente rapidez.");
            TryStopRecorder();
            return;
        }

        Interlocked.Add(ref capturedBytes, copy.Length);
        lock (sync)
        {
            recentPackets.Enqueue(copy);
            recentBytes += copy.Length;
            while (recentBytes > SnapshotCapacity && recentPackets.TryDequeue(out var removed))
            {
                recentBytes -= removed.Length;
            }
        }

        firstPacket.TrySetResult();
        LevelChanged?.Invoke(attempt, CalculateLevel(copy));
    }

    private void HandleRecordingStopped(SessionAttemptID attempt, object? sender, StoppedEventArgs eventArgs)
    {
        if (captureAttempt != attempt)
        {
            return;
        }

        captureFailure ??= eventArgs.Exception;
        stopped.TrySetResult();
        if (eventArgs.Exception is not null)
        {
            CaptureFaulted?.Invoke(attempt, eventArgs.Exception);
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
                if (bytesSinceDurableFlush >= BytesPerSecond * 2)
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
        TryStopRecorder();
        try
        {
            if (recorder is not null)
            {
                await stopped.Task.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
            }
        }
        catch (TimeoutException)
        {
            // Disposal below forcibly releases a capture that failed to stop.
        }

        await FinishCaptureResourcesAsync().ConfigureAwait(false);

        if (rawPath is not null && File.Exists(rawPath))
        {
            try
            {
                await FinalizeRawAsync(CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception error) when (error is IOException
                                               or UnauthorizedAccessException
                                               or InvalidDataException)
            {
                // Keep source.raw in place so the history screen can recover it later.
            }
        }
    }

    private async Task FinishCaptureResourcesAsync()
    {
        var currentRecorder = recorder;
        var finishedAttempt = captureAttempt;
        recorder = null;
        captureAttempt = null;
        if (currentRecorder is not null)
        {
            if (dataAvailableHandler is not null)
            {
                currentRecorder.DataAvailable -= dataAvailableHandler;
            }

            if (recordingStoppedHandler is not null)
            {
                currentRecorder.RecordingStopped -= recordingStoppedHandler;
            }
        }
        dataAvailableHandler = null;
        recordingStoppedHandler = null;

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

            if (currentRecorder is not null)
            {
                try
                {
                    await currentRecorder.DisposeAsync().ConfigureAwait(false);
                }
                catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException)
                {
                    captureFailure ??= error;
                }
            }

            selectedDevice?.Dispose();
            selectedDevice = null;
            packetChannel = null;
            writerTask = null;
            rawStream = null;
            if (finishedAttempt is not null)
            {
                LevelChanged?.Invoke(finishedAttempt, 0);
            }
        }
    }

    private async Task<string> FinalizeRawAsync(CancellationToken cancellationToken)
    {
        var source = rawPath ?? throw new InvalidOperationException("No existe audio crudo para finalizar.");
        PcmWaveFile.ValidateRaw(source);
        var wavePath = Path.Combine(Path.GetDirectoryName(source)!, "source.wav");
        await PcmWaveFile.WrapRawAsync(source, wavePath, cancellationToken).ConfigureAwait(false);
        File.Delete(source);
        rawPath = null;
        return wavePath;
    }

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
}
