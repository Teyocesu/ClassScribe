using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class SystemOutputCaptureTests
{
    [TestMethod]
    public void AuthorizationCannotCrossAttemptOrSurviveInvalidation()
    {
        var authority = new SystemOutputCaptureAuthorizationAuthority();
        var first = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var second = SessionAttemptID.Create(first.SessionID, 2);
        var authorization = authority.IssueForTesting(first);

        Assert.IsTrue(authority.Accepts(authorization, first));
        Assert.IsFalse(authority.Accepts(authorization, second));

        authority.Invalidate(first);

        Assert.IsFalse(authority.Accepts(authorization, first));
    }

    [TestMethod]
    public void ReissuingReplacesThePreviousEphemeralCapability()
    {
        var authority = new SystemOutputCaptureAuthorizationAuthority();
        var attempt = SessionAttemptID.Create(Guid.NewGuid(), 1);
        var first = authority.IssueForTesting(attempt);
        var second = authority.IssueForTesting(attempt);

        Assert.IsFalse(authority.Accepts(first, attempt));
        Assert.IsTrue(authority.Accepts(second, attempt));
    }

    [TestMethod]
    public void EndpointIdentityChangeRequiresARebind()
    {
        Assert.IsFalse(SystemOutputEndpointPolicy.ShouldRestart("render-a", "render-a"));
        Assert.IsTrue(SystemOutputEndpointPolicy.ShouldRestart("render-a", "render-b"));
        Assert.IsFalse(SystemOutputEndpointPolicy.ShouldRestart("render-a", ""));
        Assert.IsFalse(SystemOutputEndpointPolicy.ShouldRestart("render-a", null));
    }
}
