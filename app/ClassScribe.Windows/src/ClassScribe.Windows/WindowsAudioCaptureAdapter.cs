using NAudio.CoreAudioApi;
using NAudio.Wave;
using ClassScribe.Core;

namespace ClassScribe.Windows;

/// Product-owned recorder boundary. The WindowsAudioCapture lifecycle below
/// uses this interface for every generation, so tests exercise the same
/// session/rebind/Stop path without requiring a physical WASAPI endpoint.
internal interface IWindowsAudioRecorder : IAsyncDisposable
{
    event Action<ReadOnlyMemory<byte>>? DataAvailable;

    event Action<Exception?>? RecordingStopped;

    void StartRecording();

    void StopRecording();
}

/// Owns the gap between a native recorder build completing and the product
/// caller adopting that recorder. Cancellation in that gap must dispose the
/// built resource before the cancellation escapes.
internal static class WindowsAudioRecorderOwnership
{
    internal static async Task<T> AdoptBuiltRecorderAsync<T>(
        T recorder,
        Func<T, ValueTask> disposeAsync,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(disposeAsync);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            return recorder;
        }
        catch
        {
            await disposeAsync(recorder).ConfigureAwait(false);
            throw;
        }
    }
}

internal sealed record WindowsRenderEndpoint(string EndpointId, MMDevice? Device);

internal interface IWindowsAudioCaptureFactory
{
    WindowsRenderEndpoint GetDefaultRenderEndpoint();

    string GetDefaultRenderEndpointId();

    Task<IWindowsAudioRecorder> BuildProcessLoopbackRecorderAsync(
        uint rootProcessId,
        CancellationToken cancellationToken);

    IWindowsAudioRecorder BuildSystemOutputRecorder(WindowsRenderEndpoint endpoint);

    MMDevice GetDevice(string deviceId);

    IWindowsAudioRecorder BuildDeviceRecorder(MMDevice device);
}

/// Real NAudio adapter used by the Windows product. System output is explicitly
/// built from the selected default render endpoint plus WASAPI loopback; it is
/// never a process-loopback capture and never enumerates all processes.
internal sealed class NAudioWindowsAudioCaptureFactory : IWindowsAudioCaptureFactory
{
    private static WasapiRecorderBuilder CreateBuilder() => new WasapiRecorderBuilder()
        .WithSharedMode()
        .WithEventSync()
        .WithFormat(new WaveFormat(PcmWaveFile.SampleRate, PcmWaveFile.BitsPerSample, PcmWaveFile.Channels))
        .WithBufferLength(100)
        .WithMmcssThreadPriority("Audio");

    public WindowsRenderEndpoint GetDefaultRenderEndpoint()
    {
        using var enumerator = new MMDeviceEnumerator();
        var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        return new WindowsRenderEndpoint(device.ID, device);
    }

    public string GetDefaultRenderEndpointId()
    {
        using var endpoint = GetDefaultRenderEndpoint().Device;
        return endpoint?.ID ?? string.Empty;
    }

    public async Task<IWindowsAudioRecorder> BuildProcessLoopbackRecorderAsync(
        uint rootProcessId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var recorder = await CreateBuilder()
            .WithProcessLoopback(rootProcessId, ProcessLoopbackMode.IncludeTargetProcessTree)
            .BuildAsync()
            .ConfigureAwait(false);
        var adoptedRecorder = await WindowsAudioRecorderOwnership.AdoptBuiltRecorderAsync(
                recorder,
                static candidate => candidate.DisposeAsync(),
                cancellationToken)
            .ConfigureAwait(false);
        return new NAudioWindowsAudioRecorder(adoptedRecorder);
    }

    public IWindowsAudioRecorder BuildSystemOutputRecorder(WindowsRenderEndpoint endpoint)
    {
        var device = endpoint.Device
            ?? throw new InvalidOperationException("El endpoint de salida no tiene un dispositivo WASAPI.");
        return new NAudioWindowsAudioRecorder(
            CreateBuilder()
                .WithDevice(device)
                .WithLoopbackCapture()
                .Build());
    }

    public MMDevice GetDevice(string deviceId)
    {
        using var enumerator = new MMDeviceEnumerator();
        return enumerator.GetDevice(deviceId);
    }

    public IWindowsAudioRecorder BuildDeviceRecorder(MMDevice device) =>
        new NAudioWindowsAudioRecorder(CreateBuilder().WithDevice(device).Build());
}

internal sealed class NAudioWindowsAudioRecorder : IWindowsAudioRecorder
{
    private readonly WasapiRecorder recorder;

    public NAudioWindowsAudioRecorder(WasapiRecorder recorder)
    {
        this.recorder = recorder;
        this.recorder.DataAvailable += HandleDataAvailable;
        this.recorder.RecordingStopped += HandleRecordingStopped;
    }

    public event Action<ReadOnlyMemory<byte>>? DataAvailable;

    public event Action<Exception?>? RecordingStopped;

    public void StartRecording() => recorder.StartRecording();

    public void StopRecording() => recorder.StopRecording();

    public ValueTask DisposeAsync()
    {
        recorder.DataAvailable -= HandleDataAvailable;
        recorder.RecordingStopped -= HandleRecordingStopped;
        return recorder.DisposeAsync();
    }

    private void HandleDataAvailable(
        ReadOnlySpan<byte> buffer,
        AudioClientBufferFlags flags,
        long devicePosition,
        long qpcPosition)
    {
        _ = flags;
        _ = devicePosition;
        _ = qpcPosition;
        DataAvailable?.Invoke(buffer.ToArray());
    }

    private void HandleRecordingStopped(object? sender, StoppedEventArgs eventArgs)
    {
        _ = sender;
        RecordingStopped?.Invoke(eventArgs.Exception);
    }
}
