using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class ApplicationSourceLivenessTests
{
    [TestMethod]
    public void currentRootPresentResetsObservationWithoutFault()
    {
        var clock = new FakeMonotonicClock();
        var tracker = NewTracker(clock);
        var attempt = NewAttempt();
        var generation = NewGeneration(attempt, 1);
        var identity = StrongIdentity().StableKey;
        tracker.Begin(attempt, generation, identity);

        clock.NowSeconds = 29;
        _ = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.Missing);
        clock.NowSeconds = 29.5;

        var result = tracker.ObserveResolvedCurrentRoot(
            attempt,
            generation,
            identity);

        Assert.AreEqual(ApplicationSourceLivenessState.ResolvedCurrentRoot, result.State);
        Assert.IsFalse(result.ShouldPublishSourceFailure);
    }

    [TestMethod]
    public void missingBeforeBudgetDoesNotFault()
    {
        var (tracker, clock, attempt, generation, identity) = NewState();
        clock.NowSeconds = 29.9;

        var result = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.Missing);

        Assert.AreEqual(ApplicationSourceLivenessState.Unresolved, result.State);
        Assert.IsFalse(result.ShouldPublishSourceFailure);
    }

    [TestMethod]
    public void missingThenVerifiedReplacementBeforeBudgetResetsObservation()
    {
        var (tracker, clock, attempt, firstGeneration, identity) = NewState();
        clock.NowSeconds = 29;
        _ = tracker.ObserveUnresolved(
            attempt,
            firstGeneration,
            identity,
            ApplicationResolutionState.Missing);

        var replacementGeneration = NewGeneration(attempt, 2);
        clock.NowSeconds = 29.5;
        var replacement = tracker.ObserveVerifiedReplacement(
            attempt,
            replacementGeneration,
            identity);

        Assert.AreEqual(ApplicationSourceLivenessState.ResolvedVerifiedReplacement, replacement.State);
        Assert.IsFalse(replacement.ShouldPublishSourceFailure);

        clock.NowSeconds = 59.4;
        var afterReset = tracker.ObserveUnresolved(
            attempt,
            replacementGeneration,
            identity,
            ApplicationResolutionState.Missing);
        Assert.AreEqual(ApplicationSourceLivenessState.Unresolved, afterReset.State);
        Assert.IsFalse(afterReset.ShouldPublishSourceFailure);
    }

    [TestMethod]
    public void missingAtBudgetPublishesOneSourceFailure()
    {
        var (tracker, clock, attempt, generation, identity) = NewState();
        _ = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.Missing);
        clock.NowSeconds = 30;

        var result = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.Missing);

        Assert.AreEqual(ApplicationSourceLivenessState.SourceFailure, result.State);
        Assert.IsTrue(result.ShouldPublishSourceFailure);
        Assert.AreEqual(ApplicationResolutionState.Missing, result.ResolutionState);
    }

    [TestMethod]
    public void repeatedProbesAfterTerminalSourceFailureDoNotDuplicateFault()
    {
        var (tracker, clock, attempt, generation, identity) = NewState();
        _ = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.Ambiguous);
        clock.NowSeconds = 30;
        var first = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.Ambiguous);
        clock.NowSeconds = 45;
        var second = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.Ambiguous);

        Assert.IsTrue(first.ShouldPublishSourceFailure);
        Assert.AreEqual(ApplicationSourceLivenessState.SourceFailure, second.State);
        Assert.IsFalse(second.ShouldPublishSourceFailure);
    }

    [TestMethod]
    public void ambiguousBeforeBudgetNeverSelectsCandidate()
    {
        var (tracker, clock, attempt, generation, identity) = NewState();
        clock.NowSeconds = 12;

        var result = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.Ambiguous);

        Assert.AreEqual(ApplicationSourceLivenessState.Unresolved, result.State);
        Assert.IsFalse(result.ShouldPublishSourceFailure);
    }

    [TestMethod]
    public void ambiguousAtBudgetBecomesSourceFailure()
    {
        var (tracker, clock, attempt, generation, identity) = NewState();
        _ = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.Ambiguous);
        clock.NowSeconds = 30;

        var result = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.Ambiguous);

        Assert.AreEqual(ApplicationSourceLivenessState.SourceFailure, result.State);
        Assert.IsTrue(result.ShouldPublishSourceFailure);
    }

    [TestMethod]
    public void weakOriginalIncarnationDisappearingEventuallyFailsWithoutSiblingGuess()
    {
        var clock = new FakeMonotonicClock();
        var tracker = NewTracker(clock);
        var attempt = NewAttempt();
        var generation = NewGeneration(attempt, 1);
        var identity = WindowsApplicationIdentity.FromObservation(null, "Class").StableKey;
        tracker.Begin(attempt, generation, identity);
        _ = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.UnsupportedWeakIdentity);
        clock.NowSeconds = 30;

        var result = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.UnsupportedWeakIdentity);

        Assert.AreEqual(ApplicationSourceLivenessState.SourceFailure, result.State);
        Assert.IsTrue(result.ShouldPublishSourceFailure);
        Assert.AreEqual(ApplicationResolutionState.UnsupportedWeakIdentity, result.ResolutionState);
    }

    [TestMethod]
    public void newAttemptDoesNotInheritPreviousUnresolvedObservation()
    {
        var (tracker, clock, firstAttempt, firstGeneration, identity) = NewState();
        clock.NowSeconds = 29;
        _ = tracker.ObserveUnresolved(
            firstAttempt,
            firstGeneration,
            identity,
            ApplicationResolutionState.Missing);

        var secondAttempt = NewAttempt();
        var secondGeneration = NewGeneration(secondAttempt, 1);
        tracker.Begin(secondAttempt, secondGeneration, identity);
        clock.NowSeconds = 30;

        var result = tracker.ObserveUnresolved(
            secondAttempt,
            secondGeneration,
            identity,
            ApplicationResolutionState.Missing);

        Assert.AreEqual(ApplicationSourceLivenessState.Unresolved, result.State);
        Assert.IsFalse(result.ShouldPublishSourceFailure);

        var stale = tracker.ObserveUnresolved(
            firstAttempt,
            firstGeneration,
            identity,
            ApplicationResolutionState.Missing);
        Assert.AreEqual(ApplicationSourceLivenessState.Ignored, stale.State);
    }

    [TestMethod]
    public void verifiedReplacementWithinSixSecondsRemainsValid()
    {
        var (tracker, clock, attempt, firstGeneration, identity) = NewState();
        clock.NowSeconds = 5.5;
        _ = tracker.ObserveUnresolved(
            attempt,
            firstGeneration,
            identity,
            ApplicationResolutionState.Missing);

        var replacement = tracker.ObserveVerifiedReplacement(
            attempt,
            NewGeneration(attempt, 2),
            identity);

        Assert.AreEqual(ApplicationSourceLivenessState.ResolvedVerifiedReplacement, replacement.State);
        Assert.IsFalse(replacement.ShouldPublishSourceFailure);
    }

    [TestMethod]
    public void staleGenerationCannotPublishSourceFailure()
    {
        var (tracker, clock, attempt, generation, identity) = NewState();
        var newerGeneration = NewGeneration(attempt, 2);
        _ = tracker.AdvanceGeneration(attempt, newerGeneration, identity);
        clock.NowSeconds = 30;

        var stale = tracker.ObserveUnresolved(
            attempt,
            generation,
            identity,
            ApplicationResolutionState.Missing);

        Assert.AreEqual(ApplicationSourceLivenessState.Ignored, stale.State);
        Assert.IsFalse(stale.ShouldPublishSourceFailure);
    }

    private static (ApplicationSourceLivenessTracker Tracker,
        FakeMonotonicClock Clock,
        SessionAttemptID Attempt,
        CaptureSourceGeneration Generation,
        string Identity) NewState()
    {
        var clock = new FakeMonotonicClock();
        var tracker = NewTracker(clock);
        var attempt = NewAttempt();
        var generation = NewGeneration(attempt, 1);
        var identity = StrongIdentity().StableKey;
        tracker.Begin(attempt, generation, identity);
        return (tracker, clock, attempt, generation, identity);
    }

    private static ApplicationSourceLivenessTracker NewTracker(FakeMonotonicClock clock) =>
        new(TimeSpan.FromSeconds(30), clock);

    private static SessionAttemptID NewAttempt() => SessionAttemptID.Create(Guid.NewGuid(), 1);

    private static CaptureSourceGeneration NewGeneration(SessionAttemptID attempt, long number) =>
        new(attempt, number);

    private static WindowsApplicationIdentity StrongIdentity() =>
        WindowsApplicationIdentity.FromObservation(
            @"C:\Apps\Class\Class.exe",
            "Class");

    private sealed class FakeMonotonicClock : IMonotonicClock
    {
        public double NowSeconds { get; set; }
    }
}
