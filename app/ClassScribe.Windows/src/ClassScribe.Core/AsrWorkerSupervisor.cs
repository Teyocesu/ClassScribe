using System.Diagnostics;

namespace ClassScribe.Core;

public enum AsrWorkerSupervisorState
{
    Idle,
    Handshaking,
    Running,
    Cancelling,
    Succeeded,
    Cancelled,
    FailedRecoverable,
    UnavailableForSession,
}

public static class AsrWorkerSupervisorStateText
{
    public static AsrPhase ToAsrPhase(this AsrWorkerSupervisorState state) => state switch
    {
        AsrWorkerSupervisorState.Idle
            or AsrWorkerSupervisorState.Succeeded
            or AsrWorkerSupervisorState.Cancelled => AsrPhase.Idle,
        AsrWorkerSupervisorState.Handshaking => AsrPhase.PreparingLoad,
        AsrWorkerSupervisorState.Running => AsrPhase.Transcribing,
        AsrWorkerSupervisorState.Cancelling
            or AsrWorkerSupervisorState.UnavailableForSession => AsrPhase.UnavailableForSession,
        AsrWorkerSupervisorState.FailedRecoverable => AsrPhase.FailedRecoverable,
        _ => throw new ArgumentOutOfRangeException(nameof(state)),
    };
}

public enum AsrWorkerTerminalReason
{
    Success,
    Cancelled,
    ForcedCancellation,
    HeartbeatTimeout,
    AbsoluteDeadline,
    CrashBeforeHandshake,
    CrashDuringJob,
    IncompatibleProtocol,
    MalformedProtocol,
    LaunchFailed,
    TransportFailure,
    RecoverableError,
    TerminalError,
    StaleAttempt,
}

public sealed record AsrWorkerTerminalResult
{
    public required AsrWorkerTerminalReason Reason { get; init; }
    public required SessionAttemptID AttemptID { get; init; }
    public required Guid JobID { get; init; }
    public string? Text { get; init; }
    public string? Code { get; init; }
    public string? Message { get; init; }

    public AsrPhase AsrPhase => Reason switch
    {
        AsrWorkerTerminalReason.Success
            or AsrWorkerTerminalReason.Cancelled
            or AsrWorkerTerminalReason.ForcedCancellation => AsrPhase.Idle,
        AsrWorkerTerminalReason.HeartbeatTimeout
            or AsrWorkerTerminalReason.AbsoluteDeadline
            or AsrWorkerTerminalReason.IncompatibleProtocol
            or AsrWorkerTerminalReason.StaleAttempt => AsrPhase.UnavailableForSession,
        _ => AsrPhase.FailedRecoverable,
    };
}

public sealed record AsrWorkerSupervisorConfiguration
{
    public TimeSpan HandshakeDeadline { get; init; } = TimeSpan.FromSeconds(10);
    public TimeSpan AbsoluteJobDeadline { get; init; } = TimeSpan.FromMinutes(30);
    public TimeSpan HeartbeatInterval { get; init; } = TimeSpan.FromSeconds(1);
    public TimeSpan HeartbeatInactivityBudget { get; init; } = TimeSpan.FromSeconds(5);
    public TimeSpan CancellationGracePeriod { get; init; } = TimeSpan.FromMilliseconds(250);
    public bool AutomaticMonitoring { get; init; } = true;

    public AsrWorkerSupervisorConfiguration Normalize() => this with
    {
        HandshakeDeadline = Positive(HandshakeDeadline),
        AbsoluteJobDeadline = Positive(AbsoluteJobDeadline),
        HeartbeatInterval = Positive(HeartbeatInterval),
        HeartbeatInactivityBudget = Positive(HeartbeatInactivityBudget),
        CancellationGracePeriod = Positive(CancellationGracePeriod),
    };

    private static TimeSpan Positive(TimeSpan value) =>
        value > TimeSpan.Zero ? value : TimeSpan.FromMilliseconds(1);
}

public interface IAsrWorkerClock
{
    TimeSpan Now { get; }
}

public sealed class StopwatchAsrWorkerClock : IAsrWorkerClock
{
    private readonly long origin = Stopwatch.GetTimestamp();

    public TimeSpan Now => Stopwatch.GetElapsedTime(origin);
}

public sealed class FakeAsrWorkerClock : IAsrWorkerClock
{
    private readonly object gate = new();
    private TimeSpan now;

    public TimeSpan Now
    {
        get
        {
            lock (gate)
            {
                return now;
            }
        }
    }

    public void Advance(TimeSpan delta)
    {
        if (delta < TimeSpan.Zero)
        {
            return;
        }

        lock (gate)
        {
            now += delta;
        }
    }
}

/// The lock protects the complete state machine. No transport operation is
/// performed while it is held; a transport may call back from any thread.
public sealed class AsrWorkerSupervisor : IDisposable
{
    private sealed class Actions
    {
        public AsrWorkerEnvelope? StartMessage { get; init; }
        public IReadOnlyList<AsrWorkerEnvelope> Messages { get; init; } = [];
        public bool DetachCallbacks { get; init; }
        public bool Terminate { get; init; }
        public CancellationTokenSource? WatchdogToCancel { get; init; }
        public AsrWorkerTerminalResult? Terminal { get; init; }

        public static Actions None { get; } = new();
    }

    private readonly object gate = new();
    private readonly IAsrWorkerTransport worker;
    private readonly Func<SessionAttemptID, bool> isCurrentAttempt;
    private readonly TaskCompletionSource<AsrWorkerTerminalResult> completion =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly string? sourceReference;
    private readonly IAsrWorkerClock clock;
    private readonly List<AsrWorkerEnvelope> noMessages = [];
    private CancellationTokenSource? watchdogCancellation;
    private AsrWorkerSupervisorState state;
    private AsrWorkerTerminalResult? terminalResult;
    private int rejectedMessageCount;
    private double? latestProgress;
    private TimeSpan currentTime;
    private TimeSpan? startedAt;
    private TimeSpan lastHeartbeatAt;
    private TimeSpan? cancellationStartedAt;
    private bool disposed;

    public AsrWorkerSupervisor(
        SessionAttemptID attemptID,
        IAsrWorkerTransport worker,
        Guid? jobID = null,
        AsrWorkerSupervisorConfiguration? configuration = null,
        IAsrWorkerClock? clock = null,
        Func<SessionAttemptID, bool>? isCurrentAttempt = null,
        string? sourceReference = null)
    {
        AttemptID = attemptID;
        JobID = jobID ?? Guid.NewGuid();
        Configuration = (configuration ?? new AsrWorkerSupervisorConfiguration()).Normalize();
        this.worker = worker;
        this.clock = clock ?? new StopwatchAsrWorkerClock();
        this.isCurrentAttempt = isCurrentAttempt ?? (_ => true);
        this.sourceReference = sourceReference;
        worker.MessageReceived += Receive;
        worker.Exited += WorkerExited;
        worker.Faulted += TransportFault;
    }

    public SessionAttemptID AttemptID { get; }
    public Guid JobID { get; }
    public AsrWorkerSupervisorConfiguration Configuration { get; }

    public AsrWorkerSupervisorState State
    {
        get { lock (gate) return state; }
    }

    public AsrPhase AsrPhase
    {
        get { lock (gate) return state.ToAsrPhase(); }
    }

    public AsrWorkerTerminalResult? TerminalResult
    {
        get { lock (gate) return terminalResult; }
    }

    public int RejectedMessageCount
    {
        get { lock (gate) return rejectedMessageCount; }
    }

    public double? LatestProgress
    {
        get { lock (gate) return latestProgress; }
    }

    public TimeSpan CurrentTime
    {
        get { lock (gate) return currentTime; }
    }

    public void Start()
    {
        Actions actions;
        lock (gate)
        {
            if (state != AsrWorkerSupervisorState.Idle || disposed)
            {
                return;
            }

            RefreshClockLocked();
            if (!isCurrentAttempt(AttemptID))
            {
                actions = FinishLocked(AsrWorkerTerminalReason.StaleAttempt);
            }
            else
            {
                startedAt = currentTime;
                lastHeartbeatAt = currentTime;
                state = AsrWorkerSupervisorState.Handshaking;
                actions = new Actions
                {
                    StartMessage = AsrWorkerEnvelope.Hello(AttemptID, JobID),
                };
            }
        }

        Execute(actions);
        if (actions.StartMessage is not null)
        {
            StartWatchdogIfNeeded();
            EvaluateNow();
        }
    }

    public void Cancel()
    {
        Actions actions;
        lock (gate)
        {
            if (terminalResult is not null
                || state is not AsrWorkerSupervisorState.Handshaking
                    and not AsrWorkerSupervisorState.Running)
            {
                return;
            }

            RefreshClockLocked();
            state = AsrWorkerSupervisorState.Cancelling;
            cancellationStartedAt = currentTime;
            actions = new Actions
            {
                Messages =
                [
                    new AsrWorkerEnvelope
                    {
                        AttemptID = AttemptID,
                        JobID = JobID,
                        MessageType = AsrMessageType.Cancel,
                    },
                ],
            };
        }

        Execute(actions);
        EvaluateNow();
    }

    public void Advance(TimeSpan delta)
    {
        if (clock is not FakeAsrWorkerClock fakeClock || delta < TimeSpan.Zero)
        {
            return;
        }

        fakeClock.Advance(delta);
        EvaluateNow();
    }

    public void EvaluateNow()
    {
        Actions actions;
        lock (gate)
        {
            actions = EvaluateDeadlinesLocked();
        }

        Execute(actions);
    }

    public Task<AsrWorkerTerminalResult> WaitForTerminalAsync() => completion.Task;

    public void Dispose()
    {
        Actions actions;
        lock (gate)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            actions = terminalResult is null
                ? FinishLocked(AsrWorkerTerminalReason.Cancelled, message: "supervisor disposed")
                : Actions.None;
        }

        Execute(actions);
    }

    private void Receive(AsrWorkerEnvelope message)
    {
        Actions actions;
        lock (gate)
        {
            if (terminalResult is not null || disposed)
            {
                return;
            }

            RefreshClockLocked();
            if (!isCurrentAttempt(AttemptID))
            {
                rejectedMessageCount++;
                actions = FinishLocked(AsrWorkerTerminalReason.StaleAttempt);
            }
            else if (message.AttemptID != AttemptID || message.JobID != JobID)
            {
                rejectedMessageCount++;
                actions = Actions.None;
            }
            else
            {
                try
                {
                    message.ValidateShape();
                    if (message.ProtocolVersion != AsrWorkerProtocol.SupportedVersion)
                    {
                        actions = FinishLocked(AsrWorkerTerminalReason.IncompatibleProtocol);
                    }
                    else
                    {
                        actions = message.MessageType switch
                        {
                            AsrMessageType.Ready => HandleReadyLocked(message),
                            AsrMessageType.Heartbeat => HandleHeartbeatLocked(),
                            AsrMessageType.Progress => HandleProgressLocked(message),
                            AsrMessageType.Result => HandleResultLocked(message),
                            AsrMessageType.RecoverableError => HandleErrorLocked(message, true),
                            AsrMessageType.TerminalError => HandleErrorLocked(message, false),
                            AsrMessageType.Cancelled => HandleCancelledLocked(),
                            _ => FinishLocked(AsrWorkerTerminalReason.MalformedProtocol, message: "unexpected worker message"),
                        };
                    }
                }
                catch (AsrWorkerProtocolException)
                {
                    actions = FinishLocked(AsrWorkerTerminalReason.MalformedProtocol, message: "invalid envelope");
                }
            }
        }

        Execute(actions);
    }

    private Actions HandleReadyLocked(AsrWorkerEnvelope message)
    {
        if (state != AsrWorkerSupervisorState.Handshaking
            || message.SelectedVersion != AsrWorkerProtocol.SupportedVersion)
        {
            return FinishLocked(AsrWorkerTerminalReason.IncompatibleProtocol);
        }

        state = AsrWorkerSupervisorState.Running;
        lastHeartbeatAt = currentTime;
        return new Actions
        {
            Messages =
            [
                AsrWorkerEnvelope.StartMessage(AttemptID, JobID, sourceReference),
            ],
        };
    }

    private Actions HandleHeartbeatLocked()
    {
        if (state is AsrWorkerSupervisorState.Handshaking or AsrWorkerSupervisorState.Running)
        {
            lastHeartbeatAt = currentTime;
        }

        return Actions.None;
    }

    private Actions HandleProgressLocked(AsrWorkerEnvelope message)
    {
        if (state != AsrWorkerSupervisorState.Running)
        {
            rejectedMessageCount++;
            return Actions.None;
        }

        latestProgress = message.Progress;
        return Actions.None;
    }

    private Actions HandleResultLocked(AsrWorkerEnvelope message)
    {
        if (state != AsrWorkerSupervisorState.Running)
        {
            rejectedMessageCount++;
            return Actions.None;
        }

        return FinishLocked(AsrWorkerTerminalReason.Success, text: message.Text);
    }

    private Actions HandleErrorLocked(AsrWorkerEnvelope message, bool recoverable)
    {
        if (state is not AsrWorkerSupervisorState.Handshaking
            and not AsrWorkerSupervisorState.Running)
        {
            return Actions.None;
        }

        return FinishLocked(
            recoverable ? AsrWorkerTerminalReason.RecoverableError : AsrWorkerTerminalReason.TerminalError,
            code: message.Code,
            message: message.Message);
    }

    private Actions HandleCancelledLocked()
    {
        if (state != AsrWorkerSupervisorState.Cancelling)
        {
            rejectedMessageCount++;
            return Actions.None;
        }

        return FinishLocked(AsrWorkerTerminalReason.Cancelled);
    }

    private void WorkerExited(AsrWorkerExit exit)
    {
        Actions actions;
        lock (gate)
        {
            if (terminalResult is not null || disposed)
            {
                return;
            }

            RefreshClockLocked();
            actions = state switch
            {
                AsrWorkerSupervisorState.Cancelling => FinishLocked(
                    AsrWorkerTerminalReason.Cancelled,
                    message: $"worker exit {exit.Status}"),
                AsrWorkerSupervisorState.Handshaking => FinishLocked(
                    AsrWorkerTerminalReason.CrashBeforeHandshake,
                    message: $"worker exit {exit.Status}"),
                _ => FinishLocked(
                    AsrWorkerTerminalReason.CrashDuringJob,
                    message: $"worker exit {exit.Status}"),
            };
        }

        Execute(actions);
    }

    private void TransportFault(AsrWorkerTransportFault fault)
    {
        Actions actions;
        lock (gate)
        {
            if (terminalResult is not null || disposed)
            {
                return;
            }

            RefreshClockLocked();
            var reason = fault.Kind switch
            {
                AsrWorkerTransportFaultKind.MalformedFrame
                    or AsrWorkerTransportFaultKind.OversizedFrame => AsrWorkerTerminalReason.MalformedProtocol,
                AsrWorkerTransportFaultKind.LaunchFailed => AsrWorkerTerminalReason.LaunchFailed,
                _ => AsrWorkerTerminalReason.TransportFailure,
            };
            actions = FinishLocked(reason, message: fault.Message);
        }

        Execute(actions);
    }

    private Actions EvaluateDeadlinesLocked()
    {
        if (terminalResult is not null || disposed)
        {
            return Actions.None;
        }

        RefreshClockLocked();
        if (!isCurrentAttempt(AttemptID))
        {
            return FinishLocked(AsrWorkerTerminalReason.StaleAttempt);
        }

        switch (state)
        {
            case AsrWorkerSupervisorState.Handshaking:
                if (startedAt is { } handshakeStart
                    && currentTime - handshakeStart >= Configuration.HandshakeDeadline)
                {
                    return FinishLocked(
                        AsrWorkerTerminalReason.AbsoluteDeadline,
                        message: "handshake deadline");
                }

                break;
            case AsrWorkerSupervisorState.Running:
                if (startedAt is { } jobStart
                    && currentTime - jobStart >= Configuration.AbsoluteJobDeadline)
                {
                    return FinishLocked(
                        AsrWorkerTerminalReason.AbsoluteDeadline,
                        message: "job deadline");
                }

                if (currentTime - lastHeartbeatAt >= Configuration.HeartbeatInactivityBudget)
                {
                    return FinishLocked(
                        AsrWorkerTerminalReason.HeartbeatTimeout,
                        message: "heartbeat timeout");
                }

                break;
            case AsrWorkerSupervisorState.Cancelling:
                if (cancellationStartedAt is { } cancellationStart
                    && currentTime - cancellationStart >= Configuration.CancellationGracePeriod)
                {
                    return FinishLocked(
                        AsrWorkerTerminalReason.ForcedCancellation,
                        message: "cancellation grace period");
                }

                break;
        }

        return Actions.None;
    }

    private void RefreshClockLocked() => currentTime = clock.Now;

    private Actions FinishLocked(
        AsrWorkerTerminalReason reason,
        string? text = null,
        string? code = null,
        string? message = null)
    {
        if (terminalResult is not null)
        {
            return Actions.None;
        }

        var terminal = new AsrWorkerTerminalResult
        {
            Reason = reason,
            AttemptID = AttemptID,
            JobID = JobID,
            Text = text,
            Code = code,
            Message = message,
        };
        terminalResult = terminal;
        state = reason switch
        {
            AsrWorkerTerminalReason.Success => AsrWorkerSupervisorState.Succeeded,
            AsrWorkerTerminalReason.Cancelled
                or AsrWorkerTerminalReason.ForcedCancellation
                or AsrWorkerTerminalReason.StaleAttempt => AsrWorkerSupervisorState.Cancelled,
            AsrWorkerTerminalReason.HeartbeatTimeout
                or AsrWorkerTerminalReason.AbsoluteDeadline
                or AsrWorkerTerminalReason.IncompatibleProtocol => AsrWorkerSupervisorState.UnavailableForSession,
            _ => AsrWorkerSupervisorState.FailedRecoverable,
        };
        var timer = watchdogCancellation;
        watchdogCancellation = null;
        var graceful = reason is AsrWorkerTerminalReason.Success or AsrWorkerTerminalReason.Cancelled;
        return new Actions
        {
            Messages = graceful
                ?
                [
                    new AsrWorkerEnvelope
                    {
                        AttemptID = AttemptID,
                        JobID = JobID,
                        MessageType = AsrMessageType.Shutdown,
                    },
                ]
                : noMessages,
            DetachCallbacks = true,
            Terminate = true,
            WatchdogToCancel = timer,
            Terminal = terminal,
        };
    }

    private void StartWatchdogIfNeeded()
    {
        if (!Configuration.AutomaticMonitoring)
        {
            return;
        }

        var cancellation = new CancellationTokenSource();
        lock (gate)
        {
            if (terminalResult is not null || disposed || watchdogCancellation is not null)
            {
                cancellation.Dispose();
                return;
            }

            watchdogCancellation = cancellation;
        }

        _ = Task.Run(async () =>
        {
            using var timer = new PeriodicTimer(Configuration.HeartbeatInterval);
            try
            {
                while (await timer.WaitForNextTickAsync(cancellation.Token).ConfigureAwait(false))
                {
                    EvaluateNow();
                }
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                // Normal terminal teardown.
            }
        }, cancellation.Token);
    }

    private void Execute(Actions actions)
    {
        actions.WatchdogToCancel?.Cancel();
        if (actions.DetachCallbacks)
        {
            worker.MessageReceived -= Receive;
            worker.Exited -= WorkerExited;
            worker.Faulted -= TransportFault;
        }

        if (actions.StartMessage is not null)
        {
            try
            {
                worker.Start(actions.StartMessage);
            }
            catch (Exception exception)
            {
                TransportFault(new AsrWorkerTransportFault(
                    AsrWorkerTransportFaultKind.LaunchFailed,
                    exception.Message));
            }
        }

        foreach (var message in actions.Messages)
        {
            try
            {
                worker.Send(message);
            }
            catch (Exception exception)
            {
                TransportFault(new AsrWorkerTransportFault(
                    AsrWorkerTransportFaultKind.WriteFailed,
                    exception.Message));
            }
        }

        if (actions.Terminate)
        {
            try
            {
                worker.Terminate();
            }
            catch
            {
                // Completion and ownership cleanup must not depend on a
                // transport teardown implementation throwing.
            }
        }

        if (actions.Terminal is not null)
        {
            completion.TrySetResult(actions.Terminal);
        }
    }
}

public enum AsrFakeWorkerScenario
{
    Success,
    DelayedSuccess,
    NoHeartbeat,
    HangForever,
    NoHandshake,
    CrashBeforeHandshake,
    CrashDuringJob,
    ProtocolVersionMismatch,
    MalformedMessage,
    IgnoresCancellation,
    LateResultAfterCancellation,
    WrongAttemptID,
    WrongJobID,
}

public sealed class FakeAsrWorker : IAsrWorkerTransport
{
    private readonly object gate = new();
    private SessionAttemptID? attemptID;
    private Guid? jobID;
    private bool terminated;
    private int terminateCount;
    private readonly List<AsrWorkerEnvelope> sentMessages = [];

    public FakeAsrWorker(AsrFakeWorkerScenario scenario)
    {
        Scenario = scenario;
    }

    public AsrFakeWorkerScenario Scenario { get; }
    public IReadOnlyList<AsrWorkerEnvelope> SentMessages
    {
        get
        {
            lock (gate)
            {
                return sentMessages.ToArray();
            }
        }
    }
    public bool IsTerminated
    {
        get { lock (gate) return terminated; }
    }

    public int TerminateCount
    {
        get { lock (gate) return terminateCount; }
    }
    public event Action<AsrWorkerEnvelope>? MessageReceived;
    public event Action<AsrWorkerExit>? Exited;
    public event Action<AsrWorkerTransportFault>? Faulted;

    public void Start(AsrWorkerEnvelope hello)
    {
        lock (gate)
        {
            if (terminated)
            {
                return;
            }

            sentMessages.Add(hello);
            attemptID = hello.AttemptID;
            jobID = hello.JobID;
        }
        if (Scenario == AsrFakeWorkerScenario.CrashBeforeHandshake)
        {
            EmitExit(new AsrWorkerExit(AsrWorkerExitKind.Crashed, 1));
            return;
        }

        if (Scenario == AsrFakeWorkerScenario.ProtocolVersionMismatch)
        {
            Emit(AsrWorkerEnvelope.Ready(
                hello.AttemptID,
                hello.JobID,
                AsrWorkerProtocol.SupportedVersion + 1,
                AsrWorkerProtocol.SupportedVersion + 1));
            return;
        }

        if (Scenario == AsrFakeWorkerScenario.NoHandshake)
        {
            return;
        }

        Emit(AsrWorkerEnvelope.Ready(hello.AttemptID, hello.JobID));
    }

    public void Send(AsrWorkerEnvelope message)
    {
        SessionAttemptID? currentAttempt;
        Guid? currentJob;
        lock (gate)
        {
            if (terminated)
            {
                return;
            }

            sentMessages.Add(message);
            currentAttempt = attemptID;
            currentJob = jobID;
        }

        if (currentAttempt is null || currentJob is null)
        {
            return;
        }

        var attempt = currentAttempt;
        var job = currentJob.Value;
        switch (message.MessageType)
        {
            case AsrMessageType.Start:
                switch (Scenario)
                {
                    case AsrFakeWorkerScenario.Success:
                        CompleteSuccess();
                        break;
                    case AsrFakeWorkerScenario.DelayedSuccess:
                        Emit(AsrWorkerEnvelope.Heartbeat(attempt, job));
                        Emit(AsrWorkerEnvelope.ProgressMessage(attempt, job, 0.25));
                        break;
                    case AsrFakeWorkerScenario.HangForever:
                        Emit(AsrWorkerEnvelope.Heartbeat(attempt, job));
                        break;
                    case AsrFakeWorkerScenario.CrashDuringJob:
                        EmitExit(new AsrWorkerExit(AsrWorkerExitKind.Crashed, 2));
                        break;
                    case AsrFakeWorkerScenario.MalformedMessage:
                        Emit(AsrWorkerEnvelope.Result(attempt, job, null));
                        break;
                    case AsrFakeWorkerScenario.WrongAttemptID:
                        Emit(AsrWorkerEnvelope.Result(
                            new SessionAttemptID
                            {
                                SessionID = attempt.SessionID,
                                Generation = attempt.Generation + 1,
                                Nonce = Guid.NewGuid(),
                            },
                            job,
                            "late A"));
                        break;
                    case AsrFakeWorkerScenario.WrongJobID:
                        Emit(AsrWorkerEnvelope.Result(attempt, Guid.NewGuid(), "wrong job"));
                        break;
                }

                break;
            case AsrMessageType.Cancel:
                if (Scenario == AsrFakeWorkerScenario.IgnoresCancellation)
                {
                    break;
                }

                if (Scenario == AsrFakeWorkerScenario.LateResultAfterCancellation)
                {
                    Emit(AsrWorkerEnvelope.Result(attempt, job, "late result"));
                    break;
                }

                Emit(new AsrWorkerEnvelope
                {
                    AttemptID = attempt,
                    JobID = job,
                    MessageType = AsrMessageType.Cancelled,
                });
                break;
        }
    }

    public void Terminate()
    {
        lock (gate)
        {
            if (terminated)
            {
                return;
            }

            terminateCount++;
            terminated = true;
        }
    }

    public void EmitHeartbeat()
    {
        var identity = SnapshotIdentity();
        if (identity is not null)
        {
            Emit(AsrWorkerEnvelope.Heartbeat(identity.Value.Attempt, identity.Value.Job));
        }
    }

    public void CompleteSuccess(string text = "fake transcript")
    {
        var identity = SnapshotIdentity();
        if (identity is not null)
        {
            Emit(AsrWorkerEnvelope.Heartbeat(identity.Value.Attempt, identity.Value.Job));
            Emit(AsrWorkerEnvelope.ProgressMessage(identity.Value.Attempt, identity.Value.Job, 1));
            Emit(AsrWorkerEnvelope.Result(identity.Value.Attempt, identity.Value.Job, text));
        }
    }

    public void Emit(AsrWorkerEnvelope message)
    {
        if (!IsTerminated)
        {
            MessageReceived?.Invoke(message);
        }
    }

    public void EmitFault(AsrWorkerTransportFault fault)
    {
        if (!IsTerminated)
        {
            Faulted?.Invoke(fault);
        }
    }

    public void EmitExit(AsrWorkerExit exit)
    {
        if (!IsTerminated)
        {
            Exited?.Invoke(exit);
        }
    }

    private (SessionAttemptID Attempt, Guid Job)? SnapshotIdentity()
    {
        lock (gate)
        {
            if (terminated || attemptID is null || jobID is null)
            {
                return null;
            }

            return (attemptID, jobID.Value);
        }
    }
}
