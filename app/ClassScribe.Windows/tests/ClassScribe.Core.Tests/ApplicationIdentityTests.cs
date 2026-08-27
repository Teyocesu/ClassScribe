using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class ApplicationIdentityTests
{
    private static readonly int[] AmbiguousCandidateProcessIds = [202, 303];

    [TestMethod]
    public void sameIdentitySameRootResolves()
    {
        var identity = StrongIdentity();
        var result = WindowsApplicationResolver.Resolve(
            identity,
            101,
            [new WindowsProcessIncarnation(101, identity)]);

        Assert.AreEqual(ApplicationResolutionState.Resolved, result.State);
        Assert.AreEqual(101, result.ResolvedProcessId);
    }

    [TestMethod]
    public void expiredRootWithUniqueStrongReplacementResolves()
    {
        var identity = StrongIdentity();
        var result = WindowsApplicationResolver.Resolve(
            identity,
            101,
            [new WindowsProcessIncarnation(202, identity)]);

        Assert.AreEqual(ApplicationResolutionState.Resolved, result.State);
        Assert.AreEqual(202, result.ResolvedProcessId);
        Assert.AreEqual(101, result.PreviousProcessId);
    }

    [TestMethod]
    public void sameNameDifferentExecutableDoesNotMatch()
    {
        var selected = WindowsApplicationIdentity.FromObservation(
            @"C:\Apps\Teams\Teams.exe",
            "Teams");
        var differentExecutable = WindowsApplicationIdentity.FromObservation(
            @"C:\Apps\Other\Teams.exe",
            "Teams");
        var result = WindowsApplicationResolver.Resolve(
            selected,
            101,
            [new WindowsProcessIncarnation(202, differentExecutable)]);

        Assert.AreEqual(ApplicationResolutionState.Missing, result.State);
        Assert.IsNull(result.ResolvedProcessId);
    }

    [TestMethod]
    public void expiredRootWithMultipleStrongReplacementsIsAmbiguous()
    {
        var identity = StrongIdentity();
        var result = WindowsApplicationResolver.Resolve(
            identity,
            101,
            [
                new WindowsProcessIncarnation(202, identity),
                new WindowsProcessIncarnation(303, identity),
            ]);

        Assert.AreEqual(ApplicationResolutionState.Ambiguous, result.State);
        Assert.IsNull(result.ResolvedProcessId);
        CollectionAssert.AreEqual(AmbiguousCandidateProcessIds, result.CandidateProcessIds.ToArray());
    }

    [TestMethod]
    public void incumbentRootWinsWhenSiblingProcessesShareStrongIdentity()
    {
        var identity = StrongIdentity();
        var result = WindowsApplicationResolver.Resolve(
            identity,
            101,
            [
                new WindowsProcessIncarnation(101, identity),
                new WindowsProcessIncarnation(102, identity),
                new WindowsProcessIncarnation(103, identity),
            ]);

        Assert.AreEqual(ApplicationResolutionState.Resolved, result.State);
        Assert.AreEqual(101, result.ResolvedProcessId);
    }

    [TestMethod]
    public void incumbentPidWithDifferentIdentityIsNotAccepted()
    {
        var selected = StrongIdentity();
        var different = WindowsApplicationIdentity.FromObservation(
            @"C:\Apps\Other\Other.exe",
            "Other");
        var result = WindowsApplicationResolver.Resolve(
            selected,
            101,
            [
                new WindowsProcessIncarnation(101, different),
                new WindowsProcessIncarnation(202, selected),
            ]);

        Assert.AreEqual(ApplicationResolutionState.Resolved, result.State);
        Assert.AreEqual(202, result.ResolvedProcessId);
    }

    [TestMethod]
    public void weakIdentityDoesNotAutoRebind()
    {
        var weak = WindowsApplicationIdentity.FromObservation(null, "Teams");
        var result = WindowsApplicationResolver.Resolve(
            weak,
            101,
            [new WindowsProcessIncarnation(
                202,
                WindowsApplicationIdentity.FromObservation(null, "Teams"))]);

        Assert.AreEqual(ApplicationResolutionState.UnsupportedWeakIdentity, result.State);
        Assert.IsNull(result.ResolvedProcessId);
    }

    [TestMethod]
    public void staleAttemptCannotPublishReplacement()
    {
        var identity = StrongIdentity();
        var resolution = WindowsApplicationResolver.Resolve(
            identity,
            101,
            [new WindowsProcessIncarnation(202, identity)]);
        var stale = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var current = SessionAttemptID.Create(stale.SessionID, 2);

        var published = WindowsApplicationStartup.TryPublishResolution(
            stale,
            current,
            resolution,
            out _);

        Assert.IsFalse(published);
    }

    [TestMethod]
    public async Task resolvedPidIsRevalidatedBeforeBuildAsync()
    {
        var identity = StrongIdentity();
        var resolved = await WindowsApplicationStartup.ResolveBeforeBuildAsync(
            identity,
            101,
            () => [new WindowsProcessIncarnation(202, identity)],
            CancellationToken.None);

        Assert.AreEqual(202, resolved);
    }

    [TestMethod]
    public async Task staleAttemptCannotReachProcessLoopbackBuildBoundary()
    {
        var stale = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var current = SessionAttemptID.Create(stale.SessionID, 2);
        var buildReached = false;

        await Assert.ThrowsExactlyAsync<OperationCanceledException>(() =>
            WindowsApplicationStartup.BuildProcessLoopbackIfCurrentAttemptAsync(
                stale,
                attempt => attempt == current,
                () =>
                {
                    buildReached = true;
                    return Task.FromResult(101);
                },
                CancellationToken.None));

        Assert.IsFalse(buildReached);
    }

    private static WindowsApplicationIdentity StrongIdentity() =>
        WindowsApplicationIdentity.FromObservation(
            @"C:\Apps\Class\Class.exe",
            "Class");
}
