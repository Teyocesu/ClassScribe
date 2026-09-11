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
