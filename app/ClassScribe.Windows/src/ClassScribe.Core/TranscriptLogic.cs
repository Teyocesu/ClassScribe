using System.Globalization;
using System.Text;

namespace ClassScribe.Core;

public static class OverlapDeduplicator
{
    public static string NovelText(string stable, string incoming, int maximumWords = 80)
    {
        var oldWords = Words(stable);
        var newWords = Words(incoming);
        if (newWords.Length == 0)
        {
            return string.Empty;
        }

        var maximumOverlap = Math.Min(maximumWords, Math.Min(oldWords.Length, newWords.Length));
        var overlap = 0;
        for (var count = maximumOverlap; count >= 1; count--)
        {
            var matches = true;
            for (var index = 0; index < count; index++)
            {
                if (!string.Equals(
                        Normalize(oldWords[oldWords.Length - count + index]),
                        Normalize(newWords[index]),
                        StringComparison.Ordinal))
                {
                    matches = false;
                    break;
                }
            }

            if (matches)
            {
                overlap = count;
                break;
            }
        }

        return string.Join(' ', newWords.Skip(overlap));
    }

    public static string Merge(string stable, string incoming)
    {
        var novel = NovelText(stable, incoming);
        if (novel.Length == 0)
        {
            return stable;
        }

        return stable.Length == 0 ? novel : $"{stable} {novel}";
    }

    private static string[] Words(string value) =>
        value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static string Normalize(string value) =>
        value.ToLowerInvariant().Trim().TrimEnd('.', ',', ';', ':', '?', '!', '…');
}

public static class SpeakerAssignment
{
    public static (IReadOnlyList<TranscriptSegment> Segments, IReadOnlyList<ReviewItem> Review) Assign(
        IReadOnlyList<TranscriptSegment> transcript,
        IReadOnlyList<DiarizationSpan> diarization,
        double confidenceThreshold = 0.55)
    {
        var assigned = new List<TranscriptSegment>(transcript.Count);
        var review = new List<ReviewItem>();

        foreach (var original in transcript)
        {
            var duration = Math.Max(0.05, original.End - original.Start);
            var bySpeaker = new Dictionary<string, double>(StringComparer.Ordinal);
            foreach (var span in diarization)
            {
                var amount = Math.Max(0, Math.Min(original.End, span.End) - Math.Max(original.Start, span.Start));
                if (amount > 0)
                {
                    bySpeaker[span.SpeakerID] = bySpeaker.GetValueOrDefault(span.SpeakerID) + amount;
                }
            }

            string speaker;
            double confidence;
            if (bySpeaker.Count > 0)
            {
                var best = bySpeaker.MaxBy(static item => item.Value);
                speaker = best.Key;
                confidence = Math.Min(1, best.Value / duration);
            }
            else if (diarization.Count > 0)
            {
                speaker = diarization.MinBy(span => Gap(original, span))!.SpeakerID;
                confidence = 0.25;
            }
            else
            {
                speaker = "Persona desconocida";
                confidence = 0;
            }

            var segment = original with
            {
                SpeakerID = speaker,
                Confidence = confidence,
                OverlappingVoices = bySpeaker.Count > 1,
            };
            assigned.Add(segment);

            if (segment.Confidence < confidenceThreshold || segment.OverlappingVoices)
            {
                review.Add(new ReviewItem
                {
                    Segment = segment,
                    Reason = segment.OverlappingVoices
                        ? "Voces superpuestas; confirmar manualmente"
                        : $"Confianza de hablante baja ({segment.Confidence:P0})",
                });
            }
        }

        return (assigned, review);
    }

    public static string? ProvisionalProfessor(IReadOnlyList<SpeakerRecord> speakers) =>
        speakers.Count == 0 ? null : speakers.MaxBy(static speaker => speaker.TotalSpeakingTime)!.Id;

    public static IReadOnlyList<TranscriptSegment> ProfessorSegments(
        IReadOnlyList<TranscriptSegment> segments,
        string? professorID,
        IReadOnlyList<ReviewItem> review)
    {
        if (professorID is null)
        {
            return [];
        }

        var manualIds = review
            .Where(static item => item.ManuallyAssignedToProfessor)
            .Select(static item => item.Segment.Id)
            .ToHashSet();
        return segments.Where(segment =>
                (segment.SpeakerID == professorID && segment.Confidence >= 0.55 && !segment.OverlappingVoices)
                || manualIds.Contains(segment.Id))
            .ToArray();
    }

    public static IReadOnlyList<SpeakerRecord> BuildSpeakers(
        IReadOnlyList<TranscriptSegment> segments,
        IReadOnlyDictionary<string, float[]>? embeddings = null)
    {
        return segments
            .Where(static segment => segment.SpeakerID != "Persona desconocida")
            .GroupBy(static segment => segment.SpeakerID, StringComparer.Ordinal)
            .Select(group => new SpeakerRecord
            {
                Id = group.Key,
                DisplayName = group.Key,
                TotalSpeakingTime = group.Sum(static segment => Math.Max(0, segment.End - segment.Start)),
                RecentFragments = group.Select(static segment => segment.Text).TakeLast(3).ToArray(),
                Confidence = group.Average(static segment => segment.Confidence),
                Embedding = embeddings?.GetValueOrDefault(group.Key),
            })
            .OrderByDescending(static speaker => speaker.TotalSpeakingTime)
            .ToArray();
    }

    private static double Gap(TranscriptSegment segment, DiarizationSpan span)
    {
        if (segment.End < span.Start)
        {
            return span.Start - segment.End;
        }

        return segment.Start > span.End ? segment.Start - span.End : 0;
    }
}

public static class TranscriptExporter
{
    public static string PlainText(IReadOnlyList<TranscriptSegment> segments) =>
        PlainText(segments, new Dictionary<string, string>(StringComparer.Ordinal));

    public static string PlainText(
        IReadOnlyList<TranscriptSegment> segments,
        IReadOnlyList<SpeakerRecord> speakers) =>
        PlainText(
            segments,
            speakers.ToDictionary(
                static speaker => speaker.Id,
                static speaker => speaker.DisplayName,
                StringComparer.Ordinal));

    private static string PlainText(
        IReadOnlyList<TranscriptSegment> segments,
        IReadOnlyDictionary<string, string> speakerNames) =>
        string.Join("\n\n", Paragraphs(segments).Select(paragraph =>
        {
            var speakerName = speakerNames.GetValueOrDefault(paragraph.SpeakerID) ?? paragraph.SpeakerID;
            return $"[{Timecode.Display(paragraph.Start)}] {speakerName}: {paragraph.Text}";
        }));

    public static string Markdown(
        string subject,
        DateTimeOffset date,
        IReadOnlyList<TranscriptSegment> segments)
    {
        var body = string.Join("\n\n", Paragraphs(segments).Select(paragraph =>
            $"- **[{Timecode.Display(paragraph.Start)}] {paragraph.SpeakerID}:** {paragraph.Text}"));
        return Markdown(subject, date, body);
    }

    public static string Markdown(
        string subject,
        DateTimeOffset date,
        IReadOnlyList<TranscriptSegment> segments,
        IReadOnlyList<SpeakerRecord> speakers)
    {
        var names = speakers.ToDictionary(
            static speaker => speaker.Id,
            static speaker => speaker.DisplayName,
            StringComparer.Ordinal);
        var body = string.Join("\n\n", Paragraphs(segments).Select(paragraph =>
        {
            var speakerName = names.GetValueOrDefault(paragraph.SpeakerID) ?? paragraph.SpeakerID;
            return $"- **[{Timecode.Display(paragraph.Start)}] {speakerName}:** {paragraph.Text}";
        }));
        return Markdown(subject, date, body);
    }

    public static string Markdown(string subject, DateTimeOffset date, string text) =>
        $"# {subject}\n\n_{date.ToLocalTime():D} {date.ToLocalTime():t}_\n\n{text}\n";

    public static string Srt(IReadOnlyList<TranscriptSegment> segments)
    {
        var builder = new StringBuilder();
        for (var index = 0; index < segments.Count; index++)
        {
            var segment = segments[index];
            builder.Append(index + 1).Append('\n')
                .Append(Timecode.Srt(segment.Start)).Append(" --> ")
                .Append(Timecode.Srt(Math.Max(segment.End, segment.Start + 0.2))).Append('\n')
                .Append(segment.Text.Trim()).Append("\n\n");
        }

        return builder.ToString();
    }

    private static List<Paragraph> Paragraphs(IReadOnlyList<TranscriptSegment> segments)
    {
        var result = new List<Paragraph>();
        foreach (var segment in segments)
        {
            var clean = segment.Text.Trim();
            if (clean.Length == 0)
            {
                continue;
            }

            if (result.Count > 0)
            {
                var current = result[^1];
                var speakerChanged = current.LastSegment.SpeakerID != segment.SpeakerID;
                var longPause = Math.Max(0, segment.Start - current.LastSegment.End) >= 4;
                if (!speakerChanged && !longPause)
                {
                    result[^1] = current with { Text = $"{current.Text} {clean}", LastSegment = segment };
                    continue;
                }
            }

            result.Add(new Paragraph(segment.Start, segment.SpeakerID, clean, segment));
        }

        return result;
    }

    private sealed record Paragraph(double Start, string SpeakerID, string Text, TranscriptSegment LastSegment);
}

public sealed record TranscriptMetadataLabels(
    string Subject,
    string Date,
    string Duration,
    string Mode,
    string Source,
    string Transcript,
    string OnlineMode,
    string InPersonMode)
{
    public static TranscriptMetadataLabels Spanish { get; } = new(
        "Materia",
        "Fecha",
        "Duración",
        "Modo",
        "Fuente",
        "Transcripción",
        "Clase online",
        "Clase presencial");

    public string ModeName(CaptureMode mode) => mode == CaptureMode.Online ? OnlineMode : InPersonMode;
}

public static class TranscriptActions
{
    public static string BestAvailable(params string?[] candidates) => candidates
        .Select(static candidate => candidate?.Trim())
        .FirstOrDefault(static candidate => !string.IsNullOrWhiteSpace(candidate)) ?? string.Empty;

    public static string FullTranscript(string? allText, string? liveText) =>
        BestAvailable(allText, liveText);

    public static string ChatEnvelope(
        string subject,
        DateTimeOffset date,
        double duration,
        CaptureMode mode,
        string source,
        string transcript,
        TranscriptMetadataLabels? labels = null,
        CultureInfo? culture = null)
    {
        labels ??= TranscriptMetadataLabels.Spanish;
        var localDate = date.ToLocalTime();
        var dateText = culture is null
            ? $"{localDate:D} {localDate:t}"
            : $"{localDate.ToString("D", culture)} {localDate.ToString("t", culture)}";
        return $"{labels.Subject}: {subject}\n"
            + $"{labels.Date}: {dateText}\n"
            + $"{labels.Duration}: {Timecode.Display(duration)}\n"
            + $"{labels.Mode}: {labels.ModeName(mode)}\n"
            + $"{labels.Source}: {source}\n\n{labels.Transcript}:\n\n{transcript}";
    }
}
