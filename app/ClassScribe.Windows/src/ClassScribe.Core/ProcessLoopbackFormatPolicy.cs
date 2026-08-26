namespace ClassScribe.Core;

/// Explicit format contract for Windows process-loopback capture.
///
/// NAudio's process-loopback virtual endpoint does not expose a per-process
/// GetMixFormat boundary. The product therefore derives its request from the
/// default render endpoint mix that it can observe. This is an observable
/// shared-mix contract, not a claim about an application's private native
/// render format when Windows routes it to another endpoint.
public static class ProcessLoopbackFormatPolicy
{
    public static AudioPcmFormat FromObservedRenderMix(AudioPcmFormat observedRenderMix)
    {
        ArgumentNullException.ThrowIfNull(observedRenderMix);
        observedRenderMix.EnsureValid();
        return AudioPcmFormat.Create(
            observedRenderMix.SampleRate,
            Math.Min(observedRenderMix.Channels, 2),
            observedRenderMix.Encoding);
    }

    /// System-output capture is built from the selected render endpoint, so
    /// its effective contract remains the endpoint's actual observed mix.
    public static AudioPcmFormat PreserveSystemOutputActualFormat(
        AudioPcmFormat actualRenderMix)
    {
        ArgumentNullException.ThrowIfNull(actualRenderMix);
        actualRenderMix.EnsureValid();
        return actualRenderMix;
    }
}
