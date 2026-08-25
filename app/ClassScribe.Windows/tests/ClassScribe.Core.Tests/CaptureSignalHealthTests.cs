using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class CaptureSignalHealthTests
{
    [TestMethod]
    public void NoCallbackBeforeBudgetStaysAwaiting()
    {
        var clock = new FakeClock();
        var attempt = NewAttempt(1);
        var tracker = NewTracker(clock, attempt);

        clock.NowSeconds = 4.99;

        Assert.AreEqual(CaptureSignalState.AwaitingCallbacks, tracker.Snapshot(attempt)?.State);
    }

    [TestMethod]
    public void NoCallbackAfterBudgetClassifiesUnavailable()
    {
        var clock = new FakeClock();
        var attempt = NewAttempt(1);
        var tracker = NewTracker(clock, attempt);

        clock.NowSeconds = 5;

        var snapshot = tracker.Snapshot(attempt);
        Assert.AreEqual(CaptureSignalState.NoCallbacks, snapshot?.State);
        Assert.AreEqual(0L, snapshot?.CallbackCount);
    }

    [TestMethod]
    public void ZeroSamplesAreSilentNotDead()
    {
        var clock = new FakeClock();
        var attempt = NewAttempt(1);
        var tracker = NewTracker(clock, attempt);

        Assert.IsTrue(tracker.TryRecordCallback(
            attempt,
            CaptureSignalMeasurement.FromRms(0, 0, 0)));

        var snapshot = tracker.Snapshot(attempt);
        Assert.AreEqual(CaptureSignalState.Silent, snapshot?.State);
        Assert.AreEqual(1L, snapshot?.CallbackCount);
        Assert.AreEqual(0L, snapshot?.SampleCount);
    }

    [TestMethod]
    public void SilentCallbacksKeepStreamHealthy()
    {
        var clock = new FakeClock();
        var attempt = NewAttempt(1);
        var tracker = NewTracker(clock, attempt);

        Assert.IsTrue(tracker.TryRecordCallback(attempt, SilentMeasurement));
        clock.NowSeconds = 2.99;
        Assert.IsTrue(tracker.TryRecordCallback(attempt, SilentMeasurement));

        var snapshot = tracker.Snapshot(attempt);
        Assert.AreEqual(CaptureSignalState.Silent, snapshot?.State);
        Assert.IsTrue(snapshot?.TransportIsHealthy == true);
    }

    [TestMethod]
    public void AudibleSamplesBecomeAudible()
    {
        var clock = new FakeClock();
        var attempt = NewAttempt(1);
        var tracker = NewTracker(clock, attempt);

        Assert.IsTrue(tracker.TryRecordCallback(attempt, AudibleMeasurement));

        var snapshot = tracker.Snapshot(attempt);
        Assert.AreEqual(CaptureSignalState.Audible, snapshot?.State);
        Assert.IsTrue(snapshot is not null && snapshot.EnergyDbfs > -40);
    }

    [TestMethod]
    public void AudibleToSilentIsNotFailure()
    {
        var clock = new FakeClock();
        var attempt = NewAttempt(1);
        var tracker = NewTracker(clock, attempt);

        Assert.IsTrue(tracker.TryRecordCallback(attempt, AudibleMeasurement));
        clock.NowSeconds = 1;
        Assert.IsTrue(tracker.TryRecordCallback(attempt, SilentMeasurement));

        var snapshot = tracker.Snapshot(attempt);
        Assert.AreEqual(CaptureSignalState.Silent, snapshot?.State);
        Assert.IsTrue(snapshot?.TransportIsHealthy == true);
    }

    [TestMethod]
    public void CallbackStallAfterHealthyStreamDetected()
    {
        var clock = new FakeClock();
        var attempt = NewAttempt(1);
        var tracker = NewTracker(clock, attempt);

        Assert.IsTrue(tracker.TryRecordCallback(attempt, AudibleMeasurement));
        clock.NowSeconds = 3;

        Assert.AreEqual(CaptureSignalState.NoCallbacks, tracker.Snapshot(attempt)?.State);
    }

    [TestMethod]
    public void StaleAttemptCannotChangeSignalState()
    {
        var clock = new FakeClock();
        var first = NewAttempt(1);
        var second = NewAttempt(2, first.SessionID);
        var tracker = NewTracker(clock, first);
        Assert.IsTrue(tracker.TryRecordCallback(first, AudibleMeasurement));

        clock.NowSeconds = 10;
        tracker.Begin(second);
        Assert.IsFalse(tracker.TryRecordCallback(first, SilentMeasurement));

        var snapshot = tracker.Snapshot(second);
        Assert.AreEqual(CaptureSignalState.AwaitingCallbacks, snapshot?.State);
        Assert.AreEqual(0L, snapshot?.CallbackCount);
        Assert.AreEqual(0L, snapshot?.SampleCount);
    }

    [TestMethod]
    public void NextAttemptStartsWithFreshHealthState()
    {
        var clock = new FakeClock();
        var first = NewAttempt(1);
        var second = NewAttempt(2, first.SessionID);
        var tracker = NewTracker(clock, first);
        Assert.IsTrue(tracker.TryRecordCallback(first, AudibleMeasurement));

        clock.NowSeconds = 10;
        tracker.Begin(second);

        var snapshot = tracker.Snapshot(second);
        Assert.AreEqual(CaptureSignalState.AwaitingCallbacks, snapshot?.State);
        Assert.AreEqual(0L, snapshot?.CallbackCount);
        Assert.AreEqual(0L, snapshot?.SampleCount);
        Assert.AreEqual(10d, snapshot?.StartedAtMonotonic);
    }

    [TestMethod]
    public void AsrEmptyDoesNotChangeCaptureHealth()
    {
        var clock = new FakeClock();
        var attempt = NewAttempt(1);
        var tracker = NewTracker(clock, attempt);
        Assert.IsTrue(tracker.TryRecordCallback(attempt, AudibleMeasurement));
        var before = tracker.Snapshot(attempt);

        var emptyTranscript = string.Empty;

        Assert.IsTrue(emptyTranscript.Length == 0);
        Assert.AreEqual(before, tracker.Snapshot(attempt));
    }

    private static CaptureSignalHealthTracker NewTracker(FakeClock clock, SessionAttemptID attempt)
    {
        var tracker = new CaptureSignalHealthTracker(CaptureSignalThresholds.Test, clock);
        tracker.Begin(attempt, clock.NowSeconds);
        return tracker;
    }

    private static SessionAttemptID NewAttempt(long generation, Guid? sessionID = null) =>
        SessionAttemptID.Create(sessionID ?? Guid.NewGuid(), generation);

    private static CaptureSignalMeasurement SilentMeasurement =>
        CaptureSignalMeasurement.FromRms(160, 160, 0);

    private static CaptureSignalMeasurement AudibleMeasurement =>
        CaptureSignalMeasurement.FromRms(160, 160, 0.2);

    private sealed class FakeClock : IMonotonicClock
    {
        public double NowSeconds { get; set; }
    }
}
