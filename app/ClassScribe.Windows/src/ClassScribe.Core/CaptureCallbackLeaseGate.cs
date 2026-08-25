namespace ClassScribe.Core;

/// Closes callback admission and waits for every callback already admitted to
/// finish. A generation switch must not publish until this gate is drained.
public sealed class CaptureCallbackLeaseGate
{
    private readonly object sync = new();
    private readonly List<TaskCompletionSource> drainWaiters = [];
    private bool accepting = true;
    private int inFlight;

    public bool TryEnter()
    {
        lock (sync)
        {
            if (!accepting)
            {
                return false;
            }

            inFlight++;
            return true;
        }
    }

    public void Leave()
    {
        TaskCompletionSource[]? completedWaiters = null;
        lock (sync)
        {
            if (inFlight <= 0)
            {
                throw new InvalidOperationException("El callback no tiene un lease activo.");
            }

            inFlight--;
            if (inFlight == 0 && !accepting && drainWaiters.Count > 0)
            {
                completedWaiters = drainWaiters.ToArray();
                drainWaiters.Clear();
            }
        }

        if (completedWaiters is not null)
        {
            foreach (var waiter in completedWaiters)
            {
                waiter.TrySetResult();
            }
        }
    }

    public Task CloseAndWaitAsync()
    {
        lock (sync)
        {
            accepting = false;
            if (inFlight == 0)
            {
                return Task.CompletedTask;
            }

            var completion = new TaskCompletionSource(
                TaskCreationOptions.RunContinuationsAsynchronously);
            drainWaiters.Add(completion);
            return completion.Task;
        }
    }
}

/// Product callback boundary used by the Windows recorder. The recorder keeps
/// the lease around every health, level, timeline, and writer side effect;
/// tests can drive the same boundary without constructing WASAPI objects.
public sealed class WindowsCaptureCallbackLifecycle
{
    private readonly CaptureCallbackLeaseGate callbackGate = new();

    public bool TryEnter() => callbackGate.TryEnter();

    public void Leave() => callbackGate.Leave();

    public bool Run(Action callback)
    {
        ArgumentNullException.ThrowIfNull(callback);
        if (!TryEnter())
        {
            return false;
        }

        try
        {
            callback();
            return true;
        }
        finally
        {
            Leave();
        }
    }

    public Task CloseAndWaitAsync() => callbackGate.CloseAndWaitAsync();
}
