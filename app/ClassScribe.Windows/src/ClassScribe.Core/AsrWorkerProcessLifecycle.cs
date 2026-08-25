using System.Threading.Channels;

namespace ClassScribe.Core;

/// Owns the write channel and cancellation source for one process transport.
/// Setup may race with exit/termination, so rejected resources are completed
/// and disposed immediately instead of being left to a later GC pass.
internal sealed class AsrWorkerProcessLifecycle : IDisposable
{
    private readonly object gate = new();
    private CancellationTokenSource? lifetime;
    private Channel<byte[]>? writeChannel;
    private bool stopped;

    public bool IsActive
    {
        get
        {
            lock (gate)
            {
                return !stopped && lifetime is not null && writeChannel is not null;
            }
        }
    }

    public bool IsStopped
    {
        get { lock (gate) return stopped; }
    }

    public bool TryInstall(
        CancellationTokenSource candidateLifetime,
        Channel<byte[]> candidateChannel)
    {
        ArgumentNullException.ThrowIfNull(candidateLifetime);
        ArgumentNullException.ThrowIfNull(candidateChannel);

        var accepted = false;
        lock (gate)
        {
            if (!stopped && lifetime is null && writeChannel is null)
            {
                lifetime = candidateLifetime;
                writeChannel = candidateChannel;
                accepted = true;
            }
        }

        if (!accepted)
        {
            Cleanup(candidateLifetime, candidateChannel);
        }

        return accepted;
    }

    public bool TryEnqueue(byte[] frame)
    {
        ArgumentNullException.ThrowIfNull(frame);
        ChannelWriter<byte[]> writer;
        lock (gate)
        {
            if (stopped || writeChannel is null)
            {
                return false;
            }

            writer = writeChannel.Writer;
        }

        return writer.TryWrite(frame);
    }

    public void ProcessExited() => Stop();

    public void Terminate() => Stop();

    public void Dispose() => Stop();

    private void Stop()
    {
        CancellationTokenSource? cancellation;
        Channel<byte[]>? channel;
        lock (gate)
        {
            if (stopped)
            {
                return;
            }

            stopped = true;
            cancellation = lifetime;
            channel = writeChannel;
            lifetime = null;
            writeChannel = null;
        }

        Cleanup(cancellation, channel);
    }

    private static void Cleanup(
        CancellationTokenSource? cancellation,
        Channel<byte[]>? channel)
    {
        channel?.Writer.TryComplete();
        if (cancellation is null)
        {
            return;
        }

        try
        {
            cancellation.Cancel();
        }
        catch (AggregateException)
        {
            // A cancellation callback must not prevent process termination.
        }
        finally
        {
            cancellation.Dispose();
        }
    }
}
