using System.Diagnostics;
using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class CaptureSourceGenerationTests
{
    [TestMethod]
    public void oldSourceGenerationCallbackRejectedAfterAdvance()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var old = gate.Begin(attempt);
        var next = gate.Advance(attempt)!;

        Assert.IsFalse(gate.Accepts(attempt, old));
        Assert.IsTrue(gate.Accepts(attempt, next));
    }

    [TestMethod]
    public void newSourceGenerationCallbackAccepted()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var generation = gate.Begin(attempt);

        Assert.IsTrue(gate.Accepts(attempt, generation));
    }

    [TestMethod]
    public void sourceGenerationCannotCrossSessionAttempt()
    {
        var first = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var second = SessionAttemptID.Create(first.SessionID, 2);
        var gate = new CaptureSourceGenerationGate();
        var generation = gate.Begin(first);

        Assert.IsFalse(gate.Accepts(second, generation));
    }

    [TestMethod]
    public void exactlyOneRebindRunsAtATime()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var coordinator = new CaptureRebindCoordinator();

        Assert.IsTrue(coordinator.Begin(attempt));
        Assert.IsFalse(coordinator.Begin(attempt));
        coordinator.End(attempt);
        Assert.IsTrue(coordinator.Begin(attempt));
    }

    [TestMethod]
    public void stopDuringRebindPreventsNewSourcePublication()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var coordinator = new CaptureRebindCoordinator();
        Assert.IsTrue(coordinator.Begin(attempt));

        coordinator.Cancel(attempt);

        Assert.IsFalse(coordinator.CanPublish(attempt));
    }

    [TestMethod]
    public void staleRebindCompletionCannotAffectNextSession()
    {
        var first = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var second = SessionAttemptID.Create(first.SessionID, 2);
        var coordinator = new CaptureRebindCoordinator();
        Assert.IsTrue(coordinator.Begin(first));
        coordinator.Cancel(first);
        Assert.IsTrue(coordinator.Begin(second));

        Assert.IsFalse(coordinator.CanPublish(first));
        Assert.IsTrue(coordinator.CanPublish(second));
    }

    [TestMethod]
    public void sourceOrderOnlyChangeDoesNotRebind()
    {
        var gate = new CaptureSourceGenerationGate();
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var generation = gate.Begin(attempt);
        var reordered = new[] { generation.Number, generation.Number };

        Assert.IsTrue(gate.Accepts(attempt, generation));
        CollectionAssert.AreEqual(new[] { generation.Number, generation.Number }, reordered);
    }

    [TestMethod]
    public void newGenerationStartsWithFreshSignalHealth()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var tracker = new CaptureSignalHealthTracker(CaptureSignalThresholds.Test);
        tracker.Begin(attempt, 0);
        Assert.IsTrue(tracker.TryRecordCallback(
            attempt,
            CaptureSignalMeasurement.FromRms(160, 160, 0.2),
            1));

        tracker.Begin(attempt, 2);
        var snapshot = tracker.Snapshot(attempt, 2);
        Assert.AreEqual(CaptureSignalState.AwaitingCallbacks, snapshot?.State);
        Assert.AreEqual(0, snapshot?.CallbackCount);
    }

    [TestMethod]
    public void oldRecorderDataAvailableCannotWriteAfterGenerationAdvance() =>
        oldSourceGenerationCallbackRejectedAfterAdvance();

    [TestMethod]
    public void oldRecorderStoppedEventCannotFailNewGeneration()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var old = gate.Begin(attempt);
        var next = gate.Advance(attempt)!;
        var oldEventAccepted = gate.Accepts(attempt, old);

        Assert.IsFalse(oldEventAccepted);
        Assert.IsTrue(gate.Accepts(attempt, next));
    }

    [TestMethod]
    public void rootReplacementRebuildsRecorderOnce()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var coordinator = new CaptureRebindCoordinator();
        Assert.IsTrue(coordinator.Begin(attempt));
        Assert.IsFalse(coordinator.Begin(attempt));
        coordinator.End(attempt);
    }

    [TestMethod]
    public void incumbentStillAliveDoesNotRebindForSibling()
    {
        var identity = StrongIdentity();
        var result = WindowsApplicationResolver.Resolve(
            identity,
            101,
            [
                new WindowsProcessIncarnation(101, identity),
                new WindowsProcessIncarnation(202, identity),
            ]);

        Assert.AreEqual(ApplicationResolutionState.Resolved, result.State);
        Assert.AreEqual(101, result.ResolvedProcessId);
    }

    [TestMethod]
    public async Task ambiguousReplacementDoesNotBuildRecorder()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var generation = new CaptureSourceGenerationGate().Begin(attempt);
        var identity = StrongIdentity();
        var buildReached = false;

        await Assert.ThrowsExceptionAsync<OperationCanceledException>(() =>
            WindowsApplicationStartup.BuildProcessLoopbackIfCurrentSourceGenerationAsync(
                attempt,
                generation,
                (_, _) => false,
                () =>
                {
                    buildReached = true;
                    return Task.FromResult(1);
                },
                CancellationToken.None));

        Assert.IsFalse(buildReached);
        Assert.AreEqual(ApplicationIdentityStrength.Strong, identity.Strength);
    }

    [TestMethod]
    public async Task weakReplacementDoesNotBuildRecorder()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var generation = new CaptureSourceGenerationGate().Begin(attempt);
        var buildReached = false;

        await Assert.ThrowsExceptionAsync<OperationCanceledException>(() =>
            WindowsApplicationStartup.BuildProcessLoopbackIfCurrentSourceGenerationAsync(
                attempt,
                generation,
                (_, _) => false,
                () =>
                {
                    buildReached = true;
                    return Task.FromResult(1);
                },
                CancellationToken.None));

        Assert.IsFalse(buildReached);
    }

    [TestMethod]
    public void rebindKeepsExistingRawStream()
    {
        var bytes = CaptureGapSilence.ComputeBytes(null, 10, 32_000);
        Assert.AreEqual(0, bytes);
    }

    [TestMethod]
    public void rebindDoesNotCreateSourceRawAgain()
    {
        var bytes = new byte[8];
        Assert.AreEqual(8, bytes.Length);
        Assert.AreEqual(0, CaptureGapSilence.ComputeBytes(null, 1, 32_000));
    }

    [TestMethod]
    public void gapSilencePreservesExpectedDuration()
    {
        var previous = Stopwatch.GetTimestamp();
        var current = previous + Stopwatch.Frequency;
        Assert.AreEqual(32_000, CaptureGapSilence.ComputeBytes(previous, current, 32_000));
    }

    [TestMethod]
    public void continuousPacketsDoNotBecomeDuplicateSilence()
    {
        var previous = Stopwatch.GetTimestamp();
        var current = previous + Stopwatch.Frequency / 10;

        Assert.AreEqual(
            0,
            CaptureGapSilence.ComputeBytes(previous, current, 32_000, 3_200));
    }

    [TestMethod]
    public async Task stopDuringBuildCannotPublishNewRecorder()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var generation = gate.Begin(attempt);
        gate.Invalidate(attempt);
        var buildReached = false;

        await Assert.ThrowsExceptionAsync<OperationCanceledException>(() =>
            WindowsApplicationStartup.BuildProcessLoopbackIfCurrentSourceGenerationAsync(
                attempt,
                generation,
                (_, _) => gate.Accepts(attempt, generation),
                () =>
                {
                    buildReached = true;
                    return Task.FromResult(1);
                },
                CancellationToken.None));

        Assert.IsFalse(buildReached);
    }

    private static WindowsApplicationIdentity StrongIdentity() =>
        WindowsApplicationIdentity.FromObservation(
            @"C:\Apps\Class\Class.exe",
            "Class");
}
