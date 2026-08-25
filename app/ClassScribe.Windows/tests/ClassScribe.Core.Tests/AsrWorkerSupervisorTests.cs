using System.Text.Json;
using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class AsrWorkerSupervisorTests
{
    [TestMethod]
    public async Task SuccessfulHandshakeAndResult()
    {
        var context = Create(AsrFakeWorkerScenario.Success);
        context.Supervisor.Start();

        var terminal = await context.Supervisor.WaitForTerminalAsync();

        Assert.AreEqual(AsrWorkerSupervisorState.Succeeded, context.Supervisor.State);
        Assert.AreEqual(AsrWorkerTerminalReason.Success, terminal.Reason);
        Assert.AreEqual("fake transcript", terminal.Text);
        Assert.AreEqual(1d, context.Supervisor.LatestProgress!.Value);
        Assert.IsTrue(context.Worker.IsTerminated);
        CollectionAssert.AreEqual(
            new[] { AsrMessageType.Hello, AsrMessageType.Start, AsrMessageType.Shutdown },
            context.Worker.SentMessages.Select(message => message.MessageType).ToArray());
    }

    [TestMethod]
    public async Task CancellationTerminatesCooperativeWorker()
    {
        var context = Create(AsrFakeWorkerScenario.DelayedSuccess);
        context.Supervisor.Start();
        context.Supervisor.Cancel();

        var terminal = await context.Supervisor.WaitForTerminalAsync();

        Assert.AreEqual(AsrWorkerTerminalReason.Cancelled, terminal.Reason);
        Assert.AreEqual(AsrWorkerSupervisorState.Cancelled, context.Supervisor.State);
        Assert.IsTrue(context.Worker.IsTerminated);
    }

    [TestMethod]
    public async Task CancellationKillsUncooperativeWorker()
    {
        var context = Create(AsrFakeWorkerScenario.IgnoresCancellation);
        context.Supervisor.Start();
        context.Supervisor.Cancel();
        Assert.AreEqual(AsrWorkerSupervisorState.Cancelling, context.Supervisor.State);

        context.Supervisor.Advance(TimeSpan.FromMilliseconds(500));

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.ForcedCancellation, terminal.Reason);
        Assert.IsTrue(context.Worker.IsTerminated);
        Assert.AreEqual(1, context.Worker.TerminateCount);
    }

    [TestMethod]
    public async Task HeartbeatTimeoutTerminatesWorker()
    {
        var context = Create(AsrFakeWorkerScenario.NoHeartbeat);
        context.Supervisor.Start();
        context.Supervisor.Advance(TimeSpan.FromMilliseconds(750));

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.HeartbeatTimeout, terminal.Reason);
        Assert.AreEqual(AsrWorkerSupervisorState.UnavailableForSession, context.Supervisor.State);
        Assert.IsTrue(context.Worker.IsTerminated);
        Assert.AreEqual(1, context.Worker.TerminateCount);
    }

    [TestMethod]
    public async Task AbsoluteDeadlineTerminatesWorker()
    {
        var context = Create(AsrFakeWorkerScenario.HangForever);
        context.Supervisor.Start();
        context.Supervisor.Advance(TimeSpan.FromMilliseconds(500));
        context.Worker.EmitHeartbeat();
        context.Supervisor.Advance(TimeSpan.FromMilliseconds(500));
        context.Worker.EmitHeartbeat();
        context.Supervisor.Advance(TimeSpan.FromMilliseconds(500));
        context.Worker.EmitHeartbeat();
        context.Supervisor.Advance(TimeSpan.FromMilliseconds(1_500));

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.AbsoluteDeadline, terminal.Reason);
        Assert.IsTrue(context.Worker.IsTerminated);
    }

    [TestMethod]
    public async Task HandshakeDeadlineTerminatesWorker()
    {
        var context = Create(AsrFakeWorkerScenario.NoHandshake);
        context.Supervisor.Start();
        context.Supervisor.Advance(TimeSpan.FromSeconds(10));

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.AbsoluteDeadline, terminal.Reason);
        Assert.AreEqual("handshake deadline", terminal.Message);
        Assert.IsTrue(context.Worker.IsTerminated);
    }

    [TestMethod]
    public async Task FakeClockJumpUsesElapsedTime()
    {
        var context = Create(AsrFakeWorkerScenario.NoHandshake);
        context.Supervisor.Start();
        context.Clock.Advance(TimeSpan.FromSeconds(10));
        context.Supervisor.EvaluateNow();

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(TimeSpan.FromSeconds(10), context.Supervisor.CurrentTime);
        Assert.AreEqual(AsrWorkerTerminalReason.AbsoluteDeadline, terminal.Reason);
    }

    [TestMethod]
    public async Task CrashBeforeHandshake()
    {
        var context = Create(AsrFakeWorkerScenario.CrashBeforeHandshake);
        context.Supervisor.Start();

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.CrashBeforeHandshake, terminal.Reason);
        Assert.AreEqual(AsrWorkerSupervisorState.FailedRecoverable, context.Supervisor.State);
        Assert.IsTrue(context.Worker.IsTerminated);
    }

    [TestMethod]
    public async Task CrashDuringJob()
    {
        var context = Create(AsrFakeWorkerScenario.CrashDuringJob);
        context.Supervisor.Start();

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.CrashDuringJob, terminal.Reason);
        Assert.AreEqual(AsrWorkerSupervisorState.FailedRecoverable, context.Supervisor.State);
    }

    [TestMethod]
    public async Task IncompatibleProtocolRejected()
    {
        var context = Create(AsrFakeWorkerScenario.ProtocolVersionMismatch);
        context.Supervisor.Start();

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.IncompatibleProtocol, terminal.Reason);
        Assert.AreEqual(AsrWorkerSupervisorState.UnavailableForSession, context.Supervisor.State);
        CollectionAssert.AreEqual(
            new[] { AsrMessageType.Hello, AsrMessageType.Shutdown },
            context.Worker.SentMessages.Select(message => message.MessageType).ToArray());
    }

    [TestMethod]
    public async Task MalformedMessageRejected()
    {
        var context = Create(AsrFakeWorkerScenario.MalformedMessage);
        context.Supervisor.Start();

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.MalformedProtocol, terminal.Reason);
        Assert.IsNull(terminal.Text);
        Assert.AreEqual(AsrWorkerSupervisorState.FailedRecoverable, context.Supervisor.State);
    }

    [TestMethod]
    public async Task StaleAttemptResultRejected()
    {
        SessionAttemptID? current = null;
        var context = Create(
            AsrFakeWorkerScenario.DelayedSuccess,
            attempt => current == attempt);
        current = context.Attempt;
        context.Supervisor.Start();
        current = SessionAttemptID.Create(context.Attempt.SessionID, 2);
        context.Worker.CompleteSuccess("late A");

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.StaleAttempt, terminal.Reason);
        Assert.IsNull(terminal.Text);
        Assert.IsTrue(context.Worker.IsTerminated);
    }

    [TestMethod]
    public void WrongJobResultRejected()
    {
        var context = Create(AsrFakeWorkerScenario.WrongJobID);
        context.Supervisor.Start();

        Assert.IsNull(context.Supervisor.TerminalResult);
        Assert.AreEqual(AsrWorkerSupervisorState.Running, context.Supervisor.State);
        Assert.AreEqual(1, context.Supervisor.RejectedMessageCount);
        Assert.IsFalse(context.Worker.IsTerminated);
    }

    [TestMethod]
    public void WrongAttemptResultRejected()
    {
        var context = Create(AsrFakeWorkerScenario.WrongAttemptID);
        context.Supervisor.Start();

        Assert.IsNull(context.Supervisor.TerminalResult);
        Assert.AreEqual(AsrWorkerSupervisorState.Running, context.Supervisor.State);
        Assert.AreEqual(1, context.Supervisor.RejectedMessageCount);
        Assert.IsFalse(context.Worker.IsTerminated);
    }

    [TestMethod]
    public async Task InvalidHandshakeRejected()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var worker = new FakeAsrWorker(AsrFakeWorkerScenario.DelayedSuccess);
        using var supervisor = new AsrWorkerSupervisor(attempt, worker);
        supervisor.Start();
        worker.Emit(new AsrWorkerEnvelope
        {
            AttemptID = attempt,
            JobID = supervisor.JobID,
            MessageType = AsrMessageType.Ready,
        });

        var terminal = await supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.MalformedProtocol, terminal.Reason);
        Assert.IsTrue(worker.IsTerminated);
    }

    [TestMethod]
    public async Task HungWorkerDoesNotBlockNextAttempt()
    {
        SessionAttemptID? current = null;
        var first = Create(
            AsrFakeWorkerScenario.HangForever,
            attempt => current == attempt);
        current = first.Attempt;
        first.Supervisor.Start();
        first.Supervisor.Advance(TimeSpan.FromMilliseconds(500));
        first.Worker.EmitHeartbeat();
        first.Supervisor.Advance(TimeSpan.FromMilliseconds(2_500));

        var firstTerminal = await first.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.AbsoluteDeadline, firstTerminal.Reason);
        Assert.IsTrue(first.Worker.IsTerminated);

        var secondAttempt = SessionAttemptID.Create(first.Attempt.SessionID, 2);
        current = secondAttempt;
        var secondWorker = new FakeAsrWorker(AsrFakeWorkerScenario.Success);
        using var second = new AsrWorkerSupervisor(
            secondAttempt,
            secondWorker,
            configuration: first.Supervisor.Configuration,
            isCurrentAttempt: attempt => current == attempt);
        second.Start();

        var secondTerminal = await second.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.Success, secondTerminal.Reason);
        Assert.IsTrue(secondWorker.IsTerminated);
    }

    [TestMethod]
    public async Task LateResultAfterCancellationIsRejected()
    {
        var context = Create(AsrFakeWorkerScenario.LateResultAfterCancellation);
        context.Supervisor.Start();
        context.Supervisor.Cancel();
        Assert.AreEqual(AsrWorkerSupervisorState.Cancelling, context.Supervisor.State);
        Assert.IsNull(context.Supervisor.TerminalResult);

        context.Supervisor.Advance(TimeSpan.FromMilliseconds(500));

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.ForcedCancellation, terminal.Reason);
        Assert.IsNull(terminal.Text);
    }

    [TestMethod]
    public async Task MalformedRawTransportFaultCompletesSupervisor()
    {
        var context = Create(AsrFakeWorkerScenario.DelayedSuccess);
        context.Supervisor.Start();
        context.Worker.EmitFault(new AsrWorkerTransportFault(
            AsrWorkerTransportFaultKind.MalformedFrame,
            "raw frame"));

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.MalformedProtocol, terminal.Reason);
        Assert.IsNull(terminal.Text);
        Assert.IsTrue(context.Worker.IsTerminated);
    }

    [TestMethod]
    public async Task TransportFailureCompletesSupervisor()
    {
        var context = Create(AsrFakeWorkerScenario.DelayedSuccess);
        context.Supervisor.Start();
        context.Worker.EmitFault(new AsrWorkerTransportFault(
            AsrWorkerTransportFaultKind.WriteFailed,
            "pipe closed"));

        var terminal = await context.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.TransportFailure, terminal.Reason);
        Assert.IsTrue(context.Worker.IsTerminated);
    }

    [TestMethod]
    public void ConcurrentHeartbeatAndResultTerminalizeOnce()
    {
        var context = Create(AsrFakeWorkerScenario.HangForever);
        context.Supervisor.Start();
        context.Clock.Advance(TimeSpan.FromSeconds(1));
        Parallel.Invoke(
            context.Supervisor.EvaluateNow,
            () => context.Worker.CompleteSuccess("race result"));

        Assert.IsNotNull(context.Supervisor.TerminalResult);
        Assert.AreEqual(1, context.Worker.TerminateCount);
        Assert.AreNotEqual(AsrWorkerSupervisorState.Running, context.Supervisor.State);
    }

    [TestMethod]
    public void ConcurrentCancelAndExitTerminalizeOnce()
    {
        var context = Create(AsrFakeWorkerScenario.IgnoresCancellation);
        context.Supervisor.Start();
        Parallel.Invoke(
            context.Supervisor.Cancel,
            () => context.Worker.EmitExit(new AsrWorkerExit(AsrWorkerExitKind.Crashed, 9)));

        Assert.IsNotNull(context.Supervisor.TerminalResult);
        Assert.AreEqual(1, context.Worker.TerminateCount);
    }

    [TestMethod]
    public void ProtocolEnvelopeRoundTripsVersionAndIdentity()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var envelope = AsrWorkerEnvelope.ProgressMessage(attempt, Guid.NewGuid(), 0.5);
        var json = JsonSerializer.Serialize(envelope);
        var decoded = JsonSerializer.Deserialize<AsrWorkerEnvelope>(json);

        Assert.IsNotNull(decoded);
        decoded!.ValidateShape();
        Assert.AreEqual(AsrWorkerProtocol.SupportedVersion, decoded.ProtocolVersion);
        Assert.AreEqual(attempt, decoded.AttemptID);
        Assert.AreEqual(envelope.JobID, decoded.JobID);
        Assert.AreEqual(AsrMessageType.Progress, decoded.MessageType);
    }

    [TestMethod]
    public void MalformedTransportFrameRejected()
    {
        Assert.ThrowsException<JsonException>(() => AsrWorkerEnvelope.Decode(new byte[] { 123 }));
    }

    private static TestContext Create(
        AsrFakeWorkerScenario scenario,
        Func<SessionAttemptID, bool>? isCurrentAttempt = null)
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var worker = new FakeAsrWorker(scenario);
        var clock = new FakeAsrWorkerClock();
        var supervisor = new AsrWorkerSupervisor(
            attempt,
            worker,
            configuration: new AsrWorkerSupervisorConfiguration
            {
                HandshakeDeadline = TimeSpan.FromSeconds(1),
                AbsoluteJobDeadline = TimeSpan.FromSeconds(3),
                HeartbeatInterval = TimeSpan.FromMilliseconds(250),
                HeartbeatInactivityBudget = TimeSpan.FromMilliseconds(750),
                CancellationGracePeriod = TimeSpan.FromMilliseconds(500),
                AutomaticMonitoring = false,
            },
            clock: clock,
            isCurrentAttempt: isCurrentAttempt);
        return new TestContext(attempt, worker, clock, supervisor);
    }

    private sealed record TestContext(
        SessionAttemptID Attempt,
        FakeAsrWorker Worker,
        FakeAsrWorkerClock Clock,
        AsrWorkerSupervisor Supervisor);
}
