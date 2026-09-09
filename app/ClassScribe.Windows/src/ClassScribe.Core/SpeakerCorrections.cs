using System.Globalization;

namespace ClassScribe.Core;

public sealed record SpeakerCorrectionProjectionResult
{
    public IReadOnlyList<TranscriptSegment> Segments { get; init; } = [];
    public IReadOnlyList<SpeakerRecord> Speakers { get; init; } = [];
    public IReadOnlyList<ReviewItem> Review { get; init; } = [];
    public string? ProfessorSpeakerID { get; init; }
    public bool ProfessorSelectionIsAutomatic { get; init; }
    public IReadOnlyList<Guid> UnresolvedOperationIDs { get; init; } = [];
}

/// Projects an automatic result through a small, session-owned human overlay.
/// The ASR artifact and diarization proposal remain untouched; this result is
/// only the visible projection used by the editor and exporters.
public static class SpeakerCorrectionProjection
{
    public static bool CanMerge(
        string sourceID,
        string targetID,
        IEnumerable<SpeakerCorrectionOperation> existingOperations,
        ISet<string> knownSpeakerIDs)
    {
        if (string.IsNullOrWhiteSpace(sourceID)
            || string.IsNullOrWhiteSpace(targetID)
            || string.Equals(sourceID, targetID, StringComparison.Ordinal)
            || !knownSpeakerIDs.Contains(sourceID)
            || !knownSpeakerIDs.Contains(targetID))
        {
            return false;
        }

        var map = MakeMergeMap(existingOperations, knownSpeakerIDs, out _);
        return !WouldCreateCycle(sourceID, targetID, map);
    }

    public static SpeakerCorrectionProjectionResult Apply(
        IReadOnlyList<TranscriptSegment> segments,
        IReadOnlyList<SpeakerRecord> speakers,
        IReadOnlyList<ReviewItem> review,
        string? professorSpeakerID,
        bool professorSelectionIsAutomatic,
        HumanCorrectionOverlay overlay)
    {
        var knownSpeakerIDs = segments.Select(static segment => segment.SpeakerID)
            .Concat(speakers.Select(static speaker => speaker.Id))
            .Where(static id => !string.IsNullOrWhiteSpace(id))
            .ToHashSet(StringComparer.Ordinal);
        var mergeMap = MakeMergeMap(overlay.Operations, knownSpeakerIDs, out var unresolved);
        var projectedSegments = segments
            .Select(segment => segment with { SpeakerID = Resolve(segment.SpeakerID, mergeMap) })
            .ToList();
        var splitChildren = new Dictionary<Guid, IReadOnlyList<TranscriptSegment>>();

        // Keep operation order for segment edits. This lets a later action
        // intentionally target a fragment created by an earlier split.
        foreach (var operation in overlay.Operations)
        {
            switch (operation.Kind)
            {
                case SpeakerCorrectionKind.Reassign:
                    if (string.IsNullOrWhiteSpace(operation.TargetSpeakerID)
                        || !knownSpeakerIDs.Contains(Resolve(operation.TargetSpeakerID!, mergeMap))
                        || MatchingIndex(operation, projectedSegments) is not { } reassignIndex)
                    {
                        unresolved.Add(operation.Id);
                        continue;
                    }

                    projectedSegments[reassignIndex] = projectedSegments[reassignIndex] with
                    {
                        SpeakerID = Resolve(operation.TargetSpeakerID!, mergeMap),
                    };
                    break;

                case SpeakerCorrectionKind.Split:
                    if (HasSplitFragments(operation, projectedSegments))
                    {
                        continue;
                    }

                    if (MatchingIndex(operation, projectedSegments) is not { } splitIndex
                        || Split(projectedSegments[splitIndex], operation) is not { } fragments)
                    {
                        unresolved.Add(operation.Id);
                        continue;
                    }

                    var source = projectedSegments[splitIndex];
                    splitChildren[source.Id] = fragments;
                    projectedSegments.RemoveAt(splitIndex);
                    projectedSegments.InsertRange(splitIndex, fragments);
                    break;
            }
        }

        var projectedReview = new List<ReviewItem>();
        foreach (var item in review)
        {
            if (splitChildren.TryGetValue(item.Segment.Id, out var children))
            {
                for (var index = 0; index < children.Count; index++)
                {
                    projectedReview.Add(item with
                    {
                        Id = DerivedID(item.Id, index),
                        Segment = children[index],
                    });
                }
            }
            else if (projectedSegments.FirstOrDefault(segment => segment.Id == item.Segment.Id) is { } current)
            {
                projectedReview.Add(item with { Segment = current });
            }
        }

        foreach (var operation in overlay.Operations.Where(static operation =>
                     operation.Kind == SpeakerCorrectionKind.Review))
        {
            var active = operation.IsActive ?? true;
            var matched = false;
            for (var index = 0; index < projectedReview.Count; index++)
            {
                var idMatch = operation.SegmentIDs.Contains(projectedReview[index].Segment.Id);
                var splitParentMatch = splitChildren.Any(pair =>
                    operation.SegmentIDs.Contains(pair.Key)
                    && pair.Value.Any(child => child.Id == projectedReview[index].Segment.Id));
                var anchorMatch = !idMatch
                    && !splitParentMatch
                    && MatchingIndex(operation, [projectedReview[index].Segment]) is not null;
                if (idMatch || splitParentMatch || anchorMatch)
                {
                    projectedReview[index] = projectedReview[index] with
                    {
                        ManuallyAssignedToProfessor = active,
                    };
                    matched = true;
                }
            }

            if (!matched && (operation.SegmentIDs.Count > 0 || operation.AnchorText is not null))
            {
                unresolved.Add(operation.Id);
            }
        }

        var names = DisplayNames(speakers, overlay.Operations);
        var projectedSpeakers = BuildSpeakers(
            projectedSegments,
            speakers,
            names,
            mergeMap);
        var knownIDs = projectedSpeakers.Select(static speaker => speaker.Id)
            .Concat(projectedSegments.Select(static segment => segment.SpeakerID))
            .ToHashSet(StringComparer.Ordinal);
        foreach (var operation in overlay.Operations.Where(static operation =>
                     operation.Kind == SpeakerCorrectionKind.Rename))
        {
            var speakerID = operation.SpeakerID?.Trim();
            var displayName = operation.DisplayName?.Trim();
            if (string.IsNullOrWhiteSpace(speakerID)
                || string.IsNullOrWhiteSpace(displayName)
                || !knownIDs.Contains(Resolve(speakerID, mergeMap)))
            {
                unresolved.Add(operation.Id);
            }
        }
        var projectedProfessor = professorSpeakerID is null
            ? null
            : Resolve(professorSpeakerID, mergeMap);
        var projectedProfessorIsAutomatic = professorSelectionIsAutomatic;
        foreach (var operation in overlay.Operations.Where(static operation =>
                     operation.Kind == SpeakerCorrectionKind.ProfessorConfirmation))
        {
            if (string.IsNullOrWhiteSpace(operation.SpeakerID))
            {
                unresolved.Add(operation.Id);
                continue;
            }

            var resolved = Resolve(operation.SpeakerID!, mergeMap);
            if (!knownIDs.Contains(resolved))
            {
                unresolved.Add(operation.Id);
                continue;
            }

            projectedProfessor = resolved;
            projectedProfessorIsAutomatic = false;
        }

        return new SpeakerCorrectionProjectionResult
        {
            Segments = projectedSegments,
            Speakers = projectedSpeakers,
            Review = projectedReview,
            ProfessorSpeakerID = projectedProfessor,
            ProfessorSelectionIsAutomatic = projectedProfessorIsAutomatic,
            UnresolvedOperationIDs = unresolved.Distinct().ToArray(),
        };
    }

    public static bool CanSplit(TranscriptSegment segment) =>
        segment.WordTimings is { Count: > 1 } timings
        && TranscriptWordTiming.RenderedText(timings) == segment.Text
        && timings.Take(timings.Count - 1).All(static timing =>
            double.IsFinite(timing.Start)
            && double.IsFinite(timing.End)
            && timing.End > timing.Start);

    public static string NormalizeText(string value) =>
        string.Join(' ', value.Split((char[]?)null,
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .ToLowerInvariant();

    private static Dictionary<string, string> MakeMergeMap(
        IEnumerable<SpeakerCorrectionOperation> operations,
        ISet<string> knownSpeakerIDs,
        out List<Guid> unresolved)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        unresolved = [];
        var mergeOperations = operations.Where(static operation =>
                operation.Kind == SpeakerCorrectionKind.Merge)
            .ToArray();
        var mergeSources = mergeOperations
            .Select(static operation => operation.SpeakerID?.Trim())
            .Where(static source => !string.IsNullOrWhiteSpace(source))
            .ToHashSet(StringComparer.Ordinal);
        foreach (var operation in mergeOperations)
        {
            var source = operation.SpeakerID?.Trim();
            var target = operation.TargetSpeakerID?.Trim();
            if (string.IsNullOrWhiteSpace(source)
                || string.IsNullOrWhiteSpace(target)
                || string.Equals(source, target, StringComparison.Ordinal)
                || (!knownSpeakerIDs.Contains(target) && !mergeSources.Contains(target))
                || WouldCreateCycle(source, target, map))
            {
                unresolved.Add(operation.Id);
                continue;
            }

            map[source] = target;
        }

        // A corrected projection may no longer contain intermediate merge
        // identities. Accept a chain only when its final root is still known;
        // otherwise retain the operation as unresolved and do not invent a
        // speaker that the current automatic result did not produce.
        var invalidSources = map.Keys
            .Where(source => !knownSpeakerIDs.Contains(Resolve(source, map)))
            .ToHashSet(StringComparer.Ordinal);
        if (invalidSources.Count > 0)
        {
            foreach (var operation in mergeOperations)
            {
                var source = operation.SpeakerID?.Trim();
                if (source is not null && invalidSources.Contains(source))
                {
                    unresolved.Add(operation.Id);
                }
            }

            foreach (var source in invalidSources)
            {
                map.Remove(source);
            }
        }

        return map;
    }

    private static bool WouldCreateCycle(string source, string target, IReadOnlyDictionary<string, string> map)
    {
        var current = target;
        var visited = new HashSet<string>(StringComparer.Ordinal);
        while (map.TryGetValue(current, out var next))
        {
            if (string.Equals(next, source, StringComparison.Ordinal))
            {
                return true;
            }

            if (!visited.Add(current))
            {
                return true;
            }

            current = next;
        }

        return string.Equals(current, source, StringComparison.Ordinal);
    }

    private static string Resolve(string id, IReadOnlyDictionary<string, string> map)
    {
        var current = id;
        var visited = new HashSet<string>(StringComparer.Ordinal);
        while (map.TryGetValue(current, out var next) && visited.Add(current))
        {
            current = next;
        }

        return current;
    }

    private static int? MatchingIndex(
        SpeakerCorrectionOperation operation,
        IReadOnlyList<TranscriptSegment> segments)
    {
        if (operation.SegmentIDs.FirstOrDefault() is { } segmentID
            && segmentID != Guid.Empty)
        {
            var exact = segments.Select((segment, index) => (segment, index))
                .FirstOrDefault(pair => pair.segment.Id == segmentID);
            if (exact.segment is not null)
            {
                if (operation.Kind != SpeakerCorrectionKind.Split
                    || operation.AnchorText is null
                    || NormalizeText(exact.segment.Text) == NormalizeText(operation.AnchorText))
                {
                    return exact.index;
                }

                return null;
            }
        }

        if (operation.AnchorText is null)
        {
            return null;
        }

        var textMatches = segments.Select((segment, index) => (segment, index))
            .Where(pair => NormalizeText(pair.segment.Text) == NormalizeText(operation.AnchorText))
            .ToArray();
        if (textMatches.Length == 0)
        {
            return null;
        }

        var timedMatches = operation.AnchorStart is { } start
            && operation.AnchorEnd is { } end
            ? textMatches.Where(pair => OverlapFraction(
                pair.segment.Start,
                pair.segment.End,
                start,
                end) >= 0.5).ToArray()
            : textMatches;
        return timedMatches.Length == 1 ? timedMatches[0].index : null;
    }

    private static double OverlapFraction(double start, double end, double otherStart, double otherEnd)
    {
        var overlap = Math.Max(0, Math.Min(end, otherEnd) - Math.Max(start, otherStart));
        var shortest = Math.Min(Math.Max(0.05, end - start), Math.Max(0.05, otherEnd - otherStart));
        return overlap / shortest;
    }

    private static IReadOnlyList<TranscriptSegment>? Split(
        TranscriptSegment segment,
        SpeakerCorrectionOperation operation)
    {
        if (!CanSplit(segment)
            || segment.WordTimings is not { } timings
            || operation.SplitAfterWordIndex is not { } after
            || after <= 0
            || after >= timings.Count)
        {
            return null;
        }

        var left = timings.Take(after).ToArray();
        var right = timings.Skip(after).ToArray();
        var first = MakeFragment(segment, left, DerivedID(operation.Id, 0));
        var second = MakeFragment(segment, right, DerivedID(operation.Id, 1));
        return first is null || second is null ? null : [first, second];
    }

    private static TranscriptSegment? MakeFragment(
        TranscriptSegment segment,
        IReadOnlyList<TranscriptWordTiming> timings,
        Guid id)
    {
        if (timings.Count == 0)
        {
            return null;
        }

        var first = timings[0];
        var last = timings[^1];
        if (!double.IsFinite(first.Start)
            || !double.IsFinite(last.End)
            || last.End <= first.Start)
        {
            return null;
        }

        return segment with
        {
            Id = id,
            Start = first.Start,
            End = last.End,
            Text = TranscriptWordTiming.RenderedText(timings),
            WordTimings = timings,
        };
    }

    private static bool HasSplitFragments(
        SpeakerCorrectionOperation operation,
        IReadOnlyList<TranscriptSegment> segments)
    {
        var first = DerivedID(operation.Id, 0);
        var second = DerivedID(operation.Id, 1);
        return segments.Any(segment => segment.Id == first)
            && segments.Any(segment => segment.Id == second);
    }

    private static Dictionary<string, string> DisplayNames(
        IReadOnlyList<SpeakerRecord> speakers,
        IEnumerable<SpeakerCorrectionOperation> operations)
    {
        var names = speakers.ToDictionary(static speaker => speaker.Id, static speaker => speaker.DisplayName,
            StringComparer.Ordinal);
        foreach (var operation in operations.Where(static operation =>
                     operation.Kind == SpeakerCorrectionKind.Rename))
        {
            if (!string.IsNullOrWhiteSpace(operation.SpeakerID)
                && !string.IsNullOrWhiteSpace(operation.DisplayName))
            {
                names[operation.SpeakerID!] = operation.DisplayName!.Trim();
            }
        }

        return names;
    }

    private static IReadOnlyList<SpeakerRecord> BuildSpeakers(
        IReadOnlyList<TranscriptSegment> segments,
        IReadOnlyList<SpeakerRecord> existing,
        IReadOnlyDictionary<string, string> names,
        IReadOnlyDictionary<string, string> mergeMap)
    {
        var existingByID = existing.ToDictionary(static speaker => speaker.Id, StringComparer.Ordinal);
        return segments.GroupBy(static segment => segment.SpeakerID, StringComparer.Ordinal)
            .Where(group => !IsUnknown(group.Key))
            .Select(group =>
            {
                var sourceIDs = existingByID.Keys
                    .Where(id => Resolve(id, mergeMap) == group.Key)
                    .ToArray();
                existingByID.TryGetValue(group.Key, out var rootSpeaker);
                var baseSpeaker = rootSpeaker ?? sourceIDs.Select(id => existingByID[id]).FirstOrDefault();
                return new SpeakerRecord
                {
                    Id = group.Key,
                    DisplayName = PreferredDisplayName(group.Key, sourceIDs, names, existingByID),
                    TotalSpeakingTime = group.Sum(segment => Math.Max(0, segment.End - segment.Start)),
                    RecentFragments = group.Select(static segment => segment.Text).TakeLast(3).ToArray(),
                    Confidence = group.Average(static segment => segment.Confidence),
                    Embedding = baseSpeaker?.Embedding,
                };
            })
            .OrderByDescending(static speaker => speaker.TotalSpeakingTime)
            .ThenBy(static speaker => speaker.Id, StringComparer.Ordinal)
            .ToArray();
    }

    private static string PreferredDisplayName(
        string rootID,
        IEnumerable<string> sourceIDs,
        IReadOnlyDictionary<string, string> names,
        IReadOnlyDictionary<string, SpeakerRecord> existing)
    {
        foreach (var id in new[] { rootID }.Concat(sourceIDs))
        {
            var name = names.GetValueOrDefault(id) ?? existing.GetValueOrDefault(id)?.DisplayName ?? id;
            if (!IsAutomaticName(name, id))
            {
                return name;
            }
        }

        return names.GetValueOrDefault(rootID) ?? existing.GetValueOrDefault(rootID)?.DisplayName ?? rootID;
    }

    private static bool IsAutomaticName(string value, string id)
    {
        if (string.Equals(value, id, StringComparison.Ordinal))
        {
            return true;
        }

        var parts = value.Split([' ', '_', '-'], StringSplitOptions.RemoveEmptyEntries);
        return parts.Length == 2
            && int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out _)
            && parts[0].ToLowerInvariant() is "persona" or "person" or "personne" or "speaker";
    }

    private static bool IsUnknown(string id) => id.ToLowerInvariant() is
        "persona desconocida" or "person unknown" or "personne inconnue" or "unknown person" or "unknown speaker";

    private static Guid DerivedID(Guid seed, int index)
    {
        var bytes = seed.ToByteArray();
        bytes[14] ^= unchecked((byte)(index * 53));
        bytes[15] ^= unchecked((byte)(index * 97));
        return new Guid(bytes);
    }
}
