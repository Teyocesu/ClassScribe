using System.Threading.Channels;
using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class AsrWorkerProcessTransportTests
{
    [TestMethod]
    public void ExitWinsInitializationRaceCleansResourcesCreatedLater()
    {
        using var lifecycle = new AsrWorkerProcessLifecycle();
        using var lifetime = new CancellationTokenSource();
        var channel = Channel.CreateUnbounded<byte[]>();

        lifecycle.ProcessExited();
        Assert.IsFalse(lifecycle.TryInstall(lifetime, channel));
        Assert.IsTrue(lifetime.IsCancellationRequested);
        Assert.IsTrue(channel.Reader.Completion.IsCompleted);
        Assert.IsTrue(lifecycle.IsStopped);
    }

    [TestMethod]
    public void TerminateWinsInitializationRaceDoesNotReviveResources()
    {
        using var lifecycle = new AsrWorkerProcessLifecycle();
        using var lifetime = new CancellationTokenSource();
        var channel = Channel.CreateUnbounded<byte[]>();

        lifecycle.Terminate();
        Assert.IsFalse(lifecycle.TryInstall(lifetime, channel));
        Assert.IsTrue(lifetime.IsCancellationRequested);
        Assert.IsTrue(channel.Reader.Completion.IsCompleted);
        Assert.IsTrue(lifecycle.IsStopped);
        Assert.IsFalse(lifecycle.IsActive);
    }

    [TestMethod]
    public void NormalLifecycleSetupCanRunUntilTermination()
    {
        using var lifecycle = new AsrWorkerProcessLifecycle();
        using var lifetime = new CancellationTokenSource();
        var channel = Channel.CreateUnbounded<byte[]>();

        Assert.IsTrue(lifecycle.TryInstall(lifetime, channel));
        Assert.IsTrue(lifecycle.IsActive);
        Assert.IsFalse(lifetime.IsCancellationRequested);
        Assert.IsFalse(channel.Reader.Completion.IsCompleted);

        lifecycle.Terminate();
        Assert.IsTrue(lifetime.IsCancellationRequested);
        Assert.IsTrue(channel.Reader.Completion.IsCompleted);
        Assert.IsFalse(lifecycle.IsActive);
    }

    [TestMethod]
    public async Task ProcessSuccess()
    {
        using var context = Create("success");
        context.Supervisor.Start();
        var terminal = await context.Supervisor.WaitForTerminalAsync();

        Assert.AreEqual(AsrWorkerTerminalReason.Success, terminal.Reason);
        Assert.AreEqual("process fake transcript", terminal.Text);
        Assert.IsTrue(await WaitForExitAsync(context.Worker));
        Assert.AreEqual(1, context.Worker.TerminateCount);
    }

    [TestMethod]
    public async Task ProcessCrashBeforeHandshake()
    {
        using var context = Create("crash-before-handshake");
        context.Supervisor.Start();
        var terminal = await context.Supervisor.WaitForTerminalAsync();

        Assert.AreEqual(AsrWorkerTerminalReason.CrashBeforeHandshake, terminal.Reason);
        Assert.IsTrue(await WaitForExitAsync(context.Worker));
    }

    [TestMethod]
    public async Task ProcessCrashDuringJob()
    {
        using var context = Create("crash-during-job");
        context.Supervisor.Start();
        var terminal = await context.Supervisor.WaitForTerminalAsync();

        Assert.AreEqual(AsrWorkerTerminalReason.CrashDuringJob, terminal.Reason);
        Assert.IsTrue(await WaitForExitAsync(context.Worker));
    }

    [TestMethod]
    public async Task ProcessMalformedRawFrame()
    {
        using var context = Create("malformed-raw-frame");
        context.Supervisor.Start();
        var terminal = await context.Supervisor.WaitForTerminalAsync();

        Assert.AreEqual(AsrWorkerTerminalReason.MalformedProtocol, terminal.Reason);
        Assert.IsNull(terminal.Text);
        Assert.IsTrue(await WaitForExitAsync(context.Worker));
    }

    [TestMethod]
    public async Task ProcessUnexpectedEof()
    {
        using var context = Create("unexpected-eof");
        context.Supervisor.Start();
        var terminal = await context.Supervisor.WaitForTerminalAsync();

        Assert.AreEqual(AsrWorkerTerminalReason.TransportFailure, terminal.Reason);
        Assert.IsTrue(await WaitForExitAsync(context.Worker));
    }

    [TestMethod]
    public async Task ProcessLaunchFailureCompletesSupervisor()
    {
        using var worker = new ProcessAsrWorkerTransport(
            "/definitely/not/a/real/executable",
            []);
        using var supervisor = new AsrWorkerSupervisor(
            SessionAttemptID.Create(Guid.NewGuid(), 1),
            worker);

        supervisor.Start();
        var terminal = await supervisor.WaitForTerminalAsync();

        Assert.AreEqual(AsrWorkerTerminalReason.LaunchFailed, terminal.Reason);
        Assert.AreEqual(1, worker.TerminateCount);
    }

    [TestMethod]
    public async Task ProcessIgnoresCancellation()
    {
        using var context = Create("ignores-cancellation");
        context.Supervisor.Start();
        Assert.IsTrue(await WaitForRunningAsync(context.Supervisor));
        context.Supervisor.Cancel();
        var terminal = await context.Supervisor.WaitForTerminalAsync();

        Assert.AreEqual(AsrWorkerTerminalReason.ForcedCancellation, terminal.Reason);
        Assert.AreEqual(1, context.Worker.TerminateCount);
        Assert.IsTrue(await WaitForExitAsync(context.Worker));
    }

    [TestMethod]
    public async Task ProcessHeartbeatTimeout()
    {
        using var context = Create("no-heartbeat");
        context.Supervisor.Start();
        var terminal = await context.Supervisor.WaitForTerminalAsync();

        Assert.AreEqual(AsrWorkerTerminalReason.HeartbeatTimeout, terminal.Reason);
        Assert.AreEqual(1, context.Worker.TerminateCount);
        Assert.IsTrue(await WaitForExitAsync(context.Worker));
    }

    [TestMethod]
    public async Task ProcessAbsoluteDeadline()
    {
        using var context = Create("hang", absoluteJobDeadline: TimeSpan.FromMilliseconds(160));
        context.Supervisor.Start();
        var terminal = await context.Supervisor.WaitForTerminalAsync();

        Assert.AreEqual(AsrWorkerTerminalReason.AbsoluteDeadline, terminal.Reason);
        Assert.AreEqual(1, context.Worker.TerminateCount);
        Assert.IsTrue(await WaitForExitAsync(context.Worker));
    }

    [TestMethod]
    public async Task ProcessHungAThenB()
    {
        using var first = Create("hang", absoluteJobDeadline: TimeSpan.FromMilliseconds(140));
        first.Supervisor.Start();
        var firstTerminal = await first.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.AbsoluteDeadline, firstTerminal.Reason);
        Assert.IsTrue(await WaitForExitAsync(first.Worker));

        using var second = Create("success");
        second.Supervisor.Start();
        var secondTerminal = await second.Supervisor.WaitForTerminalAsync();
        Assert.AreEqual(AsrWorkerTerminalReason.Success, secondTerminal.Reason);
        Assert.IsTrue(await WaitForExitAsync(second.Worker));
    }

    private static ProcessTestContext Create(
        string scenario,
        TimeSpan? absoluteJobDeadline = null)
    {
        var command = FindFakeCommand(scenario);
        if (command is null)
        {
            Assert.Inconclusive(
                "Configura CLASSSCRIBE_ASR_FAKE_PYTHON y CLASSSCRIBE_ASR_FAKE_WORKER_SCRIPT para ejecutar el gate process-backed Windows.");
        }

        var worker = new ProcessAsrWorkerTransport(command.Value.Executable, command.Value.Arguments);
        var supervisor = new AsrWorkerSupervisor(
            SessionAttemptID.Create(Guid.NewGuid(), 1),
            worker,
            configuration: new AsrWorkerSupervisorConfiguration
            {
                HandshakeDeadline = TimeSpan.FromMilliseconds(250),
                AbsoluteJobDeadline = absoluteJobDeadline ?? TimeSpan.FromMilliseconds(500),
                HeartbeatInterval = TimeSpan.FromMilliseconds(20),
                HeartbeatInactivityBudget = TimeSpan.FromMilliseconds(80),
                CancellationGracePeriod = TimeSpan.FromMilliseconds(80),
                AutomaticMonitoring = true,
            });
        return new ProcessTestContext(worker, supervisor);
    }

    private static (string Executable, string[] Arguments)? FindFakeCommand(string scenario)
    {
        var script = Environment.GetEnvironmentVariable("CLASSSCRIBE_ASR_FAKE_WORKER_SCRIPT");
        var python = Environment.GetEnvironmentVariable("CLASSSCRIBE_ASR_FAKE_PYTHON")
            ?? (OperatingSystem.IsWindows() ? "python.exe" : "python3");
        if (string.IsNullOrWhiteSpace(script) || !File.Exists(script))
        {
            return null;
        }

        return (python, [script, "--scenario", scenario]);
    }

    private static async Task<bool> WaitForExitAsync(ProcessAsrWorkerTransport worker)
    {
        for (var index = 0; index < 200; index++)
        {
            if (worker.HasExited)
            {
                return true;
            }

            await Task.Delay(10).ConfigureAwait(false);
        }

        return worker.HasExited;
    }

    private static async Task<bool> WaitForRunningAsync(AsrWorkerSupervisor supervisor)
    {
        for (var index = 0; index < 200; index++)
        {
            if (supervisor.State == AsrWorkerSupervisorState.Running)
            {
                return true;
            }

            await Task.Delay(10).ConfigureAwait(false);
        }

        return supervisor.State == AsrWorkerSupervisorState.Running;
    }

    private sealed record ProcessTestContext(
        ProcessAsrWorkerTransport Worker,
        AsrWorkerSupervisor Supervisor) : IDisposable
    {
        public void Dispose()
        {
            Supervisor.Dispose();
            Worker.Dispose();
        }
    }
}
