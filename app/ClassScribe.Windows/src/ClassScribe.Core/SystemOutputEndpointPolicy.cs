using System;

namespace ClassScribe.Core;

/// Pure endpoint identity policy for render-loopback lifecycle tests. Friendly
/// names are intentionally irrelevant: a source generation changes only when
/// the endpoint identity changes.
public static class SystemOutputEndpointPolicy
{
    public static bool ShouldRestart(string? activeEndpointId, string? observedEndpointId) =>
        !string.IsNullOrWhiteSpace(observedEndpointId)
        && !string.Equals(activeEndpointId, observedEndpointId, StringComparison.Ordinal);
}
