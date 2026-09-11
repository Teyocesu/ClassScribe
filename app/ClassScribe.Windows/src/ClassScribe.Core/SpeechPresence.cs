namespace ClassScribe.Core;

/// A time range where Silero found speech. Ranges stay on the original ASR
/// timeline; callers never replace the audio with only these ranges.
public readonly record struct SpeechPresenceRegion(double Start, double End);

/// Evidence returned by the speech-presence gate. A null evidence value in
/// the acceptance policy represents a VAD failure and therefore fails open.
public sealed record SpeechPresenceEvidence(IReadOnlyList<SpeechPresenceRegion> Regions)
{
    public bool HasSpeech => Regions is not null && Regions.Any(static region =>
        double.IsFinite(region.Start)
        && double.IsFinite(region.End)
        && region.End > region.Start);

    public static SpeechPresenceEvidence None => new(Array.Empty<SpeechPresenceRegion>());
}

/// Pure acceptance logic shared by live and final Windows transcription.
/// Padding is applied only to the decision; ASR output and timestamps are not
/// rewritten.
public static class SpeechPresenceAcceptancePolicy
{
    public const double AcceptancePaddingSeconds = 0.30;

    public static bool Intersects(
        double segmentStart,
        double segmentEnd,
        IReadOnlyList<SpeechPresenceRegion> regions,
        double paddingSeconds = AcceptancePaddingSeconds)
    {
        if (!double.IsFinite(segmentStart)
            || !double.IsFinite(segmentEnd)
            || segmentEnd < segmentStart
            || !double.IsFinite(paddingSeconds)
            || paddingSeconds < 0)
        {
            return false;
        }

        return regions.Any(region =>
        {
            if (!double.IsFinite(region.Start)
                || !double.IsFinite(region.End)
                || region.End <= region.Start)
            {
                return false;
            }

            var paddedStart = Math.Max(0, region.Start - paddingSeconds);
            var paddedEnd = region.End + paddingSeconds;
            // Inclusive endpoints intentionally keep a hypothesis that lands
            // exactly on a speech/padding boundary.
            return segmentStart <= paddedEnd && segmentEnd >= paddedStart;
        });
    }

    public static IReadOnlyList<TranscriptSegment> FilterSegments(
        IReadOnlyList<TranscriptSegment> segments,
        SpeechPresenceEvidence? evidence)
    {
        // VAD failure is fail-open: return the exact ASR result collection.
        if (evidence is null)
        {
            return segments;
        }

        if (!evidence.HasSpeech)
        {
            return Array.Empty<TranscriptSegment>();
        }

        return segments
            .Where(segment => Intersects(
                segment.Start,
                segment.End,
                evidence.Regions))
            .ToArray();
    }
}

public static class AsrResultAcceptancePolicy
{
    public static string? Accept(string? text)
    {
        var clean = text?.Trim() ?? string.Empty;
        return clean.Length == 0 ? null : clean;
    }

    public static string? Accept(string? text, SpeechPresenceEvidence speechEvidence) =>
        speechEvidence.HasSpeech ? Accept(text) : null;
}

/// Bounds live ASR failures per recording while leaving the durable audio path
/// running. A new session gets a new policy instance.
public struct LiveTranscriptionRetryPolicy : IEquatable<LiveTranscriptionRetryPolicy>
{
    private static readonly TimeSpan[] Delays =
    [
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(4),
        TimeSpan.FromSeconds(8),
        TimeSpan.FromSeconds(15),
        TimeSpan.FromSeconds(30),
    ];

    public int ConsecutiveFailures { get; private set; }

    public DateTimeOffset? RetryAfterUtc { get; private set; }

    public bool IsUnavailableForSession { get; private set; }

    public bool CanAttempt(DateTimeOffset now) => !IsUnavailableForSession
        && (!RetryAfterUtc.HasValue || now >= RetryAfterUtc.Value);

    public TimeSpan RecordFailure(DateTimeOffset now)
    {
        if (IsUnavailableForSession)
        {
            return TimeSpan.Zero;
        }

        if (ConsecutiveFailures >= Delays.Length)
        {
            IsUnavailableForSession = true;
            RetryAfterUtc = null;
            return TimeSpan.Zero;
        }

        var delay = Delays[ConsecutiveFailures];
        ConsecutiveFailures++;
        RetryAfterUtc = now + delay;
        return delay;
    }

    public void RecordSuccess()
    {
        ConsecutiveFailures = 0;
        RetryAfterUtc = null;
        IsUnavailableForSession = false;
    }

    public bool Equals(LiveTranscriptionRetryPolicy other) =>
        ConsecutiveFailures == other.ConsecutiveFailures
        && RetryAfterUtc == other.RetryAfterUtc
        && IsUnavailableForSession == other.IsUnavailableForSession;

    public override bool Equals(object? obj) => obj is LiveTranscriptionRetryPolicy other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(
        ConsecutiveFailures,
        RetryAfterUtc,
        IsUnavailableForSession);

    public static bool operator ==(LiveTranscriptionRetryPolicy left, LiveTranscriptionRetryPolicy right) =>
        left.Equals(right);

    public static bool operator !=(LiveTranscriptionRetryPolicy left, LiveTranscriptionRetryPolicy right) =>
        !left.Equals(right);
}
