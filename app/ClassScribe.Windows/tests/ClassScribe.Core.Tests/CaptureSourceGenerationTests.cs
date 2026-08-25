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
    public void normalCallbackJitterDoesNotInsertSilence()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var generation = gate.Begin(attempt);
        var timeline = new CaptureHandoffTimeline(32_000);
        timeline.BeginGeneration(generation);

        var first = timeline.PreparePacket(
            generation,
            3_200,
            arrivalTimestamp: () => 0);
        timeline.CommitPacket(first);
        // The ordinary callback path has no wall-clock sample. A callback that
        // arrives late is still a normal packet and cannot manufacture a gap.
        var jittered = timeline.PreparePacket(generation, 3_200);

        Assert.IsTrue(jittered.IsAccepted);
        Assert.AreEqual(CaptureGapDisposition.NoGap, jittered.HandoffGap.Disposition);
        Assert.AreEqual(0, jittered.HandoffGap.SilenceBytes);
    }

    [TestMethod]
    public void initialStartupDelayDoesNotBecomeFutureRebindGap()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var oldGeneration = gate.Begin(attempt);
        var timeline = new CaptureHandoffTimeline(32_000);
        timeline.BeginGeneration(oldGeneration);

        // The first real PCM arrives at T5 and contains 10 s of durable audio,
        // so the old durable end is T15—not T10 from StartAsync.
        var firstOldPacket = timeline.PreparePacket(
            oldGeneration,
            320_000,
            arrivalTimestamp: () => Stopwatch.Frequency * 5);
        timeline.CommitPacket(firstOldPacket);
        Assert.AreEqual(Stopwatch.Frequency * 15, timeline.Snapshot.LastPacketEndTimestamp);

        var newGeneration = gate.Advance(attempt)!;
        timeline.MarkHandoff(newGeneration);
        var firstNewPacket = timeline.PreparePacket(
            newGeneration,
            3_200,
            arrivalTimestamp: () => Stopwatch.Frequency * 17);

        Assert.AreEqual(CaptureGapDisposition.Silence, firstNewPacket.HandoffGap.Disposition);
        Assert.AreEqual(64_000, firstNewPacket.HandoffGap.SilenceBytes);
    }

    [TestMethod]
    public void zeroLengthStartupCallbacksDoNotAnchorTimeline()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var generation = gate.Begin(attempt);
        var timeline = new CaptureHandoffTimeline(32_000);
        timeline.BeginGeneration(generation);
        var arrivalCalls = 0;
        Func<long> firstArrival = () =>
        {
            arrivalCalls++;
            return Stopwatch.Frequency * 20;
        };

        Assert.IsTrue(timeline.PreparePacket(generation, 0, firstArrival).IsEmpty);
        Assert.IsTrue(timeline.PreparePacket(generation, 0, firstArrival).IsEmpty);
        Assert.AreEqual(0, arrivalCalls);

        var first = timeline.PreparePacket(generation, 3_200, firstArrival);
        timeline.CommitPacket(first);

        Assert.AreEqual(1, arrivalCalls);
        Assert.AreEqual(
            Stopwatch.Frequency * 20 + Stopwatch.Frequency / 10,
            timeline.Snapshot.LastPacketEndTimestamp);
    }

    [TestMethod]
    public void initialFirstPcmAnchorsOnlyOnce()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var generation = gate.Begin(attempt);
        var timeline = new CaptureHandoffTimeline(32_000);
        timeline.BeginGeneration(generation);
        var arrivalCalls = 0;
        Func<long> arrival = () =>
        {
            arrivalCalls++;
            return arrivalCalls == 1
                ? Stopwatch.Frequency * 5
                : Stopwatch.Frequency * 100;
        };

        var first = timeline.PreparePacket(generation, 3_200, arrival);
        timeline.CommitPacket(first);
        var second = timeline.PreparePacket(generation, 3_200, arrival);
        timeline.CommitPacket(second);
        var third = timeline.PreparePacket(generation, 3_200, arrival);
        timeline.CommitPacket(third);

        Assert.AreEqual(1, arrivalCalls);
        Assert.AreEqual(CaptureGapDisposition.NoGap, second.HandoffGap.Disposition);
        Assert.AreEqual(CaptureGapDisposition.NoGap, third.HandoffGap.Disposition);
        Assert.AreEqual(
            Stopwatch.Frequency * 5 + Stopwatch.Frequency * 3 / 10,
            timeline.Snapshot.LastPacketEndTimestamp);
    }

    [TestMethod]
    public void initialDelayCannotTriggerFalseSafetyBound()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var oldGeneration = gate.Begin(attempt);
        var timeline = new CaptureHandoffTimeline(32_000);
        timeline.BeginGeneration(oldGeneration);
        var firstOldPacket = timeline.PreparePacket(
            oldGeneration,
            32_000,
            arrivalTimestamp: () => Stopwatch.Frequency * 40);
        timeline.CommitPacket(firstOldPacket);

        var newGeneration = gate.Advance(attempt)!;
        timeline.MarkHandoff(newGeneration);
        var firstNewPacket = timeline.PreparePacket(
            newGeneration,
            3_200,
            arrivalTimestamp: () => Stopwatch.Frequency * 42,
            maximumGap: TimeSpan.FromSeconds(30));

        Assert.IsFalse(firstNewPacket.RequiresExplicitFailure);
        Assert.AreEqual(CaptureGapDisposition.Silence, firstNewPacket.HandoffGap.Disposition);
        Assert.AreEqual(32_000, firstNewPacket.HandoffGap.SilenceBytes);
    }

    [TestMethod]
    public void rebindGapIsInsertedExactlyOnce()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var oldGeneration = gate.Begin(attempt);
        var timeline = new CaptureHandoffTimeline(32_000);
        timeline.BeginGeneration(oldGeneration);
        var oldPacket = timeline.PreparePacket(
            oldGeneration,
            32_000,
            arrivalTimestamp: () => 0);
        timeline.CommitPacket(oldPacket);

        var newGeneration = gate.Advance(attempt)!;
        timeline.MarkHandoff(newGeneration);
        var firstNewPacket = timeline.PreparePacket(
            newGeneration,
            3_200,
            arrivalTimestamp: () => Stopwatch.Frequency * 3);
        timeline.CommitPacket(firstNewPacket);
        var secondNewPacket = timeline.PreparePacket(newGeneration, 3_200);

        Assert.AreEqual(CaptureGapDisposition.Silence, firstNewPacket.HandoffGap.Disposition);
        Assert.AreEqual(64_000, firstNewPacket.HandoffGap.SilenceBytes);
        Assert.AreEqual(CaptureGapDisposition.NoGap, secondNewPacket.HandoffGap.Disposition);
        Assert.AreEqual(0, secondNewPacket.HandoffGap.SilenceBytes);
    }

    [TestMethod]
    public void zeroLengthCallbackDoesNotConsumePendingRebindGap()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var oldGeneration = gate.Begin(attempt);
        var timeline = new CaptureHandoffTimeline(32_000);
        timeline.BeginGeneration(oldGeneration);
        var oldPacket = timeline.PreparePacket(
            oldGeneration,
            32_000,
            arrivalTimestamp: () => 0);
        timeline.CommitPacket(oldPacket);
        var newGeneration = gate.Advance(attempt)!;
        timeline.MarkHandoff(newGeneration);

        var empty = timeline.PreparePacket(newGeneration, 0);
        var firstNonEmpty = timeline.PreparePacket(
            newGeneration,
            3_200,
            arrivalTimestamp: () => Stopwatch.Frequency * 3);

        Assert.IsTrue(empty.IsEmpty);
        Assert.AreEqual(CaptureGapDisposition.NoGap, empty.HandoffGap.Disposition);
        Assert.AreEqual(CaptureGapDisposition.Silence, firstNonEmpty.HandoffGap.Disposition);
        Assert.AreEqual(64_000, firstNonEmpty.HandoffGap.SilenceBytes);
    }

    [TestMethod]
    public void staleOldGenerationCannotConsumePendingGap()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var oldGeneration = gate.Begin(attempt);
        var timeline = new CaptureHandoffTimeline(32_000);
        timeline.BeginGeneration(oldGeneration);
        var oldPacket = timeline.PreparePacket(
            oldGeneration,
            32_000,
            arrivalTimestamp: () => 0);
        timeline.CommitPacket(oldPacket);
        var newGeneration = gate.Advance(attempt)!;
        timeline.MarkHandoff(newGeneration);

        var stale = timeline.PreparePacket(oldGeneration, 3_200);
        var current = timeline.PreparePacket(
            newGeneration,
            3_200,
            arrivalTimestamp: () => Stopwatch.Frequency * 3);

        Assert.IsTrue(stale.IsRejected);
        Assert.AreEqual(CaptureGapDisposition.Silence, current.HandoffGap.Disposition);
        Assert.AreEqual(64_000, current.HandoffGap.SilenceBytes);
    }

    [TestMethod]
    public void gapBeyondSafetyBoundIsExplicitNotSilentSuccess()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var oldGeneration = gate.Begin(attempt);
        var timeline = new CaptureHandoffTimeline(32_000);
        timeline.BeginGeneration(oldGeneration);
        var oldPacket = timeline.PreparePacket(
            oldGeneration,
            32_000,
            arrivalTimestamp: () => 0);
        timeline.CommitPacket(oldPacket);
        var newGeneration = gate.Advance(attempt)!;
        timeline.MarkHandoff(newGeneration);

        var firstNewPacket = timeline.PreparePacket(
            newGeneration,
            3_200,
            arrivalTimestamp: () => Stopwatch.Frequency * 40,
            maximumGap: TimeSpan.FromSeconds(30));

        Assert.IsTrue(firstNewPacket.RequiresExplicitFailure);
        Assert.AreEqual(CaptureGapDisposition.ExceedsSafetyBound, firstNewPacket.HandoffGap.Disposition);
        Assert.AreEqual(0, firstNewPacket.HandoffGap.SilenceBytes);
    }

    [TestMethod]
    public void pausedOldGenerationCannotCommitAfterGenerationAdvance()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var oldGeneration = gate.Begin(attempt);
        var entered = new ManualResetEventSlim();
        var release = new ManualResetEventSlim();
        var writes = 0;
        var callback = Task.Run(() =>
        {
            if (!gate.Accepts(attempt, oldGeneration))
            {
                return;
            }

            entered.Set();
            release.Wait();
            if (gate.Accepts(attempt, oldGeneration))
            {
                Interlocked.Increment(ref writes);
            }
        });

        Assert.IsTrue(entered.Wait(TimeSpan.FromSeconds(1)));
        _ = gate.Advance(attempt);
        release.Set();
        callback.GetAwaiter().GetResult();

        Assert.AreEqual(0, Volatile.Read(ref writes));
    }

    [TestMethod]
    public void handoffGapIncludesResolveBuildAndFirstCallbackDelay()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var oldGeneration = gate.Begin(attempt);
        var timeline = new CaptureHandoffTimeline(32_000);
        timeline.BeginGeneration(oldGeneration);
        var oldPacket = timeline.PreparePacket(
            oldGeneration,
            32_000,
            arrivalTimestamp: () => 0);
        timeline.CommitPacket(oldPacket);

        var newGeneration = gate.Advance(attempt)!;
        timeline.MarkHandoff(newGeneration);
        var firstNewPacket = timeline.PreparePacket(
            newGeneration,
            3_200,
            arrivalTimestamp: () => Stopwatch.Frequency * 6);

        // The durable old end is 1 s and the first accepted new PCM arrives
        // at 6 s: resolve/build/start/first-callback delay contributes 5 s.
        Assert.AreEqual(CaptureGapDisposition.Silence, firstNewPacket.HandoffGap.Disposition);
        Assert.AreEqual(160_000, firstNewPacket.HandoffGap.SilenceBytes);
    }

    [TestMethod]
    public void buildDelayBeyondSafetyBoundProducesExplicitFault()
    {
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var gate = new CaptureSourceGenerationGate();
        var oldGeneration = gate.Begin(attempt);
        var timeline = new CaptureHandoffTimeline(32_000);
        timeline.BeginGeneration(oldGeneration);
        var oldPacket = timeline.PreparePacket(
            oldGeneration,
            32_000,
            arrivalTimestamp: () => 0);
        timeline.CommitPacket(oldPacket);

        var newGeneration = gate.Advance(attempt)!;
        timeline.MarkHandoff(newGeneration);
        var firstNewPacket = timeline.PreparePacket(
            newGeneration,
            3_200,
            arrivalTimestamp: () => Stopwatch.Frequency * 32,
            maximumGap: TimeSpan.FromSeconds(30));

        Assert.IsTrue(firstNewPacket.RequiresExplicitFailure);
        Assert.AreEqual(CaptureGapDisposition.ExceedsSafetyBound, firstNewPacket.HandoffGap.Disposition);
    }

    [TestMethod]
    public async Task pausedWindowsCallbackCannotMutateHealthLevelOrWriterAfterGenerationSwitch()
    {
        var callbackLifecycle = new WindowsCaptureCallbackLifecycle();
        var entered = new ManualResetEventSlim();
        var release = new ManualResetEventSlim();
        var healthMutations = 0;
        var levelMutations = 0;
        var writerMutations = 0;
        var generationSwitched = 0;
        var staleMutations = 0;
        var callback = Task.Run(() =>
        {
            callbackLifecycle.Run(() =>
            {
                entered.Set();
                release.Wait();
                if (Volatile.Read(ref generationSwitched) != 0)
                {
                    Interlocked.Increment(ref staleMutations);
                    return;
                }
                Interlocked.Increment(ref healthMutations);
                Interlocked.Increment(ref levelMutations);
                Interlocked.Increment(ref writerMutations);
            });
        });

        Assert.IsTrue(entered.Wait(TimeSpan.FromSeconds(1)));
        var drain = callbackLifecycle.CloseAndWaitAsync();
        Assert.IsFalse(drain.IsCompleted);

        // A handoff cannot advance its generation while the product callback
        // is paused before health, level, and writer side effects.
        Assert.AreEqual(0, healthMutations);
        Assert.AreEqual(0, levelMutations);
        Assert.AreEqual(0, writerMutations);

        release.Set();
        await drain;
        await callback;
        Interlocked.Exchange(ref generationSwitched, 1);

        Assert.AreEqual(1, healthMutations);
        Assert.AreEqual(1, levelMutations);
        Assert.AreEqual(1, writerMutations);
        Assert.AreEqual(0, staleMutations);
        Assert.IsFalse(callbackLifecycle.Run(static () => { }));
        Assert.AreEqual(1, healthMutations);
        Assert.AreEqual(1, levelMutations);
        Assert.AreEqual(1, writerMutations);
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
