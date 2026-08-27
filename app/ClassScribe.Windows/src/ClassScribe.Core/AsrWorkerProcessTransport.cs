using System.Buffers.Binary;
using System.Diagnostics;
using System.Text.Json;
using System.Threading.Channels;

namespace ClassScribe.Core;

/// Process-backed prototype transport. It owns framing and process lifecycle;
/// envelope semantics remain in AsrWorkerProtocol.
public sealed class ProcessAsrWorkerTransport : IAsrWorkerTransport, IDisposable
{
    private readonly object gate = new();
    private readonly ProcessStartInfo startInfo;
    private readonly AsrWorkerProcessLifecycle lifecycle = new();
    private Process? process;
    private bool processStarted;
    private bool terminationRequested;
    private bool processExited;
    private bool faultReported;
    private bool terminated;
    private int terminateCount;

    public ProcessAsrWorkerTransport(string executable, IReadOnlyList<string> arguments)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executable);
        startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }
    }

    public event Action<AsrWorkerEnvelope>? MessageReceived;
    public event Action<AsrWorkerExit>? Exited;
    public event Action<AsrWorkerTransportFault>? Faulted;

    public bool IsTerminated
    {
        get { lock (gate) return terminated || processExited; }
    }

    public int TerminateCount
    {
        get { lock (gate) return terminateCount; }
    }

    public int? ProcessId
    {
        get
        {
            Process? child;
            bool started;
            lock (gate)
            {
                child = process;
                started = processStarted;
            }

            if (child is null || !started)
            {
                return null;
            }

            try
            {
                return child.Id;
            }
            catch (InvalidOperationException)
            {
                return null;
            }
        }
    }

    public bool HasExited
    {
        get
        {
            Process? child;
            bool started;
            bool exited;
            lock (gate)
            {
                child = process;
                started = processStarted;
                exited = processExited;
            }

            if (exited || child is null)
            {
                return true;
            }

            if (!started)
            {
                return false;
            }

            try
            {
                return child.HasExited;
            }
            catch (ObjectDisposedException)
            {
                return true;
            }
            catch (InvalidOperationException)
            {
                return true;
            }
        }
    }

    public void Start(AsrWorkerEnvelope hello)
    {
        Process? child = null;
        CancellationTokenSource? pendingCancellation = null;
        var lifecycleInstalled = false;
        var started = false;
        try
        {
            _ = hello.Encode();
            var cancellation = new CancellationTokenSource();
            pendingCancellation = cancellation;
            // Install both resources before Process.Start: Exited may fire
            // before Process.Start returns for a very short-lived child.
            var channel = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions
            {
                SingleReader = true,
                SingleWriter = false,
                AllowSynchronousContinuations = false,
            });
            if (!lifecycle.TryInstall(cancellation, channel))
            {
                return;
            }
            lifecycleInstalled = true;

            child = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            child.Exited += (_, _) => ProcessExited(child);

            var shouldStart = false;
            lock (gate)
            {
                if (!terminationRequested && !processExited && !faultReported)
                {
                    process = child;
                    shouldStart = true;
                }
            }

            if (!shouldStart)
            {
                lifecycle.Terminate();
                child.Dispose();
                return;
            }

            // The lock is deliberately not held across Process.Start. A
            // concurrent Terminate may win here; the post-start check below
            // then kills the child without starting any live loops.
            if (!child.Start())
            {
                throw new InvalidOperationException("No se pudo iniciar el worker ASR.");
            }
            lock (gate)
            {
                processStarted = true;
            }
            started = true;

            bool shouldRunLoops;
            lock (gate)
            {
                shouldRunLoops = !terminationRequested
                    && !processExited
                    && !faultReported
                    && lifecycle.IsActive;
            }

            if (!shouldRunLoops)
            {
                KillProcess(child);
                lifecycle.Terminate();
                return;
            }

            _ = Task.Run(() => ReadLoopAsync(child, child.StandardOutput.BaseStream, cancellation.Token));
            _ = Task.Run(() => WriteLoopAsync(child.StandardInput.BaseStream, channel.Reader, cancellation.Token));
            _ = Task.Run(() => child.StandardError.BaseStream.CopyToAsync(Stream.Null, cancellation.Token));
            Send(hello);
        }
        catch (Exception exception)
        {
            if (!lifecycleInstalled)
            {
                pendingCancellation?.Dispose();
            }

            ReportFault(new AsrWorkerTransportFault(
                AsrWorkerTransportFaultKind.LaunchFailed,
                exception.Message));
            if (!started)
            {
                child?.Dispose();
            }
        }
    }

    /// Serializes and enqueues a frame. It never waits for the child pipe.
    public void Send(AsrWorkerEnvelope message)
    {
        byte[] frame;
        try
        {
            var payload = message.Encode();
            if (payload.Length > AsrWorkerProtocol.MaximumMessageBytes)
            {
                throw new AsrWorkerProtocolException("El mensaje ASR excede el límite de tamaño.");
            }

            frame = new byte[sizeof(uint) + payload.Length];
            BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(0, sizeof(uint)), (uint)payload.Length);
            payload.CopyTo(frame, sizeof(uint));
        }
        catch (Exception exception)
        {
            ReportFault(new AsrWorkerTransportFault(
                AsrWorkerTransportFaultKind.WriteFailed,
                exception.Message));
            return;
        }

        lock (gate)
        {
            if (terminated || terminationRequested || processExited)
            {
                return;
            }
        }

        if (!lifecycle.TryEnqueue(frame) && !lifecycle.IsStopped)
        {
            ReportFault(new AsrWorkerTransportFault(
                AsrWorkerTransportFaultKind.WriteFailed,
                "El canal de escritura ASR no está disponible."));
        }
    }

    /// Kill is independent from the write channel and does not await any task.
    public void Terminate()
    {
        Process? child;
        lock (gate)
        {
            if (terminationRequested)
            {
                return;
            }

            terminationRequested = true;
            terminated = true;
            terminateCount++;
            child = process;
        }

        if (child is not null)
        {
            KillProcess(child);
        }
        lifecycle.Terminate();
    }

    public void Dispose()
    {
        Terminate();
        lifecycle.Dispose();

        Process? child;
        lock (gate)
        {
            child = process;
        }

        child?.Dispose();
    }

    private async Task ReadLoopAsync(
        Process child,
        Stream output,
        CancellationToken cancellationToken)
    {
        try
        {
            var header = new byte[sizeof(uint)];
            while (!cancellationToken.IsCancellationRequested)
            {
                if (!await ReadExactlyAsync(output, header, cancellationToken).ConfigureAwait(false))
                {
                    if (await HasExitedAfterGraceAsync(child, cancellationToken).ConfigureAwait(false))
                    {
                        ProcessExited(child);
                    }
                    else
                    {
                        ReportFault(new AsrWorkerTransportFault(
                            AsrWorkerTransportFaultKind.UnexpectedEof,
                            "El worker cerró stdout antes de completar un frame."));
                    }
                    return;
                }

                var length = BinaryPrimitives.ReadUInt32BigEndian(header);
                if (length == 0 || length > AsrWorkerProtocol.MaximumMessageBytes)
                {
                    ReportFault(new AsrWorkerTransportFault(
                        length == 0
                            ? AsrWorkerTransportFaultKind.MalformedFrame
                            : AsrWorkerTransportFaultKind.OversizedFrame,
                        "Tamaño de frame ASR inválido."));
                    return;
                }

                var payload = new byte[(int)length];
                if (!await ReadExactlyAsync(output, payload, cancellationToken).ConfigureAwait(false))
                {
                    if (await HasExitedAfterGraceAsync(child, cancellationToken).ConfigureAwait(false))
                    {
                        ProcessExited(child);
                    }
                    else
                    {
                        ReportFault(new AsrWorkerTransportFault(
                            AsrWorkerTransportFaultKind.UnexpectedEof,
                            "EOF durante el payload ASR."));
                    }
                    return;
                }

                try
                {
                    MessageReceived?.Invoke(AsrWorkerEnvelope.Decode(payload));
                }
                catch (AsrWorkerProtocolException exception)
                {
                    ReportFault(new AsrWorkerTransportFault(
                        AsrWorkerTransportFaultKind.MalformedFrame,
                        exception.Message));
                    return;
                }
                catch (JsonException exception)
                {
                    ReportFault(new AsrWorkerTransportFault(
                        AsrWorkerTransportFaultKind.MalformedFrame,
                        exception.Message));
                    return;
                }
            }
        }
        catch (EndOfStreamException)
        {
            if (await HasExitedAfterGraceAsync(child, cancellationToken).ConfigureAwait(false))
            {
                ProcessExited(child);
            }
            else
            {
                ReportFault(new AsrWorkerTransportFault(
                    AsrWorkerTransportFaultKind.UnexpectedEof,
                    "EOF durante el frame ASR."));
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Normal teardown.
        }
        catch (Exception exception)
        {
            ReportFault(new AsrWorkerTransportFault(
                AsrWorkerTransportFaultKind.ReadFailed,
                exception.Message));
        }
    }

    private async Task WriteLoopAsync(
        Stream input,
        ChannelReader<byte[]> reader,
        CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var frame in reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                await input.WriteAsync(frame, cancellationToken).ConfigureAwait(false);
                await input.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Normal teardown.
        }
        catch (Exception exception)
        {
            ReportFault(new AsrWorkerTransportFault(
                AsrWorkerTransportFaultKind.WriteFailed,
                exception.Message));
        }
    }

    private static async Task<bool> ReadExactlyAsync(
        Stream stream,
        byte[] buffer,
        CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return offset == 0 ? false : throw new EndOfStreamException();
            }

            offset += read;
        }

        return true;
    }

    private static async Task<bool> HasExitedAfterGraceAsync(
        Process child,
        CancellationToken cancellationToken)
    {
        if (child.HasExited)
        {
            return true;
        }

        await Task.Delay(10, cancellationToken).ConfigureAwait(false);
        return child.HasExited;
    }

    private void ProcessExited(Process child)
    {
        Action<AsrWorkerExit>? handler;
        lock (gate)
        {
            if (processExited)
            {
                return;
            }

            processExited = true;
            terminated = true;
            handler = terminationRequested || faultReported ? null : Exited;
        }

        lifecycle.ProcessExited();

        var status = -1;
        try
        {
            status = child.ExitCode;
        }
        catch (ObjectDisposedException)
        {
            // The process can be disposed by a concurrent owner after exit.
        }
        catch (InvalidOperationException)
        {
            // The process can be disposed by a concurrent owner after exit.
        }

        handler?.Invoke(new AsrWorkerExit(
            status == 0 ? AsrWorkerExitKind.Clean : AsrWorkerExitKind.Crashed,
            status));
    }

    private void ReportFault(AsrWorkerTransportFault fault)
    {
        Action<AsrWorkerTransportFault>? handler;
        lock (gate)
        {
            if (faultReported)
            {
                return;
            }

            faultReported = true;
            handler = Faulted;
        }

        try
        {
            handler?.Invoke(fault);
        }
        finally
        {
            Terminate();
        }
    }

    private static void KillProcess(Process child)
    {
        try
        {
            if (!child.HasExited)
            {
                child.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
            // The process was not started or exited between the check and kill.
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // Cleanup remains idempotent; the exit event is authoritative.
        }
    }
}
