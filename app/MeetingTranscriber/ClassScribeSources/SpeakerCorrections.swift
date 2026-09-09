import Foundation

/// Applies human speaker corrections to an automatic projection without
/// touching the ASR artifact or the diarization proposal. The operation log
/// is intentionally small: IDs are preferred, while time and normalized text
/// are used only when a later run has issued new segment UUIDs.
struct SpeakerCorrectionProjectionResult: Equatable {
    var segments: [TranscriptSegment]
    var speakers: [SpeakerRecord]
    var review: [ReviewItem]
    var professorSpeakerID: String?
    var professorSelectionIsAutomatic: Bool
    var unresolvedOperationIDs: [UUID]
}

struct SpeakerSplitBoundary: Identifiable, Equatable {
    let afterWordIndex: Int
    let word: String

    var id: Int { afterWordIndex }
}

enum SpeakerCorrectionProjection {
    static func canMerge(
        sourceID: String,
        targetID: String,
        existingOperations: [SpeakerCorrectionOperation],
        knownSpeakerIDs: Set<String>,
    ) -> Bool {
        guard !sourceID.isEmpty,
              !targetID.isEmpty,
              sourceID != targetID,
              knownSpeakerIDs.contains(sourceID),
              knownSpeakerIDs.contains(targetID)
        else { return false }
        let map = makeMergeMap(
            operations: existingOperations,
            knownSpeakerIDs: knownSpeakerIDs,
        ).map
        return !wouldCreateCycle(source: sourceID, target: targetID, map: map)
    }

    static func apply(
        segments: [TranscriptSegment],
        speakers: [SpeakerRecord],
        review: [ReviewItem],
        professorSpeakerID: String?,
        professorSelectionIsAutomatic: Bool,
        overlay: HumanCorrectionOverlay,
    ) -> SpeakerCorrectionProjectionResult {
        let knownSpeakerIDs = Set(segments.map(\.speakerID).filter { !$0.isEmpty } + speakers.map(\.id))
        let mergeMap = makeMergeMap(
            operations: overlay.operations,
            knownSpeakerIDs: knownSpeakerIDs,
        )
        var unresolved = mergeMap.unresolved
        var projectedSegments = segments.map { segment in
            var projected = segment
            projected.speakerID = resolve(segment.speakerID, using: mergeMap.map)
            return projected
        }
        var splitChildren: [UUID: [TranscriptSegment]] = [:]

        // Reassign and split in user-action order. A later reassignment can
        // therefore target a fragment created by an earlier split.
        for operation in overlay.operations {
            switch operation.kind {
            case .reassign:
                guard let target = operation.targetSpeakerID,
                      !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      knownSpeakerIDs.contains(resolve(target, using: mergeMap.map)),
                      let index = matchingIndex(for: operation, in: projectedSegments)
                else {
                    if operation.kind == .reassign { unresolved.append(operation.id) }
                    continue
                }
                projectedSegments[index].speakerID = resolve(target, using: mergeMap.map)

            case .split:
                if hasSplitFragments(for: operation, in: projectedSegments) {
                    continue
                }
                guard let index = matchingIndex(for: operation, in: projectedSegments),
                      let fragments = split(projectedSegments[index], operation: operation)
                else {
                    unresolved.append(operation.id)
                    continue
                }
                let source = projectedSegments[index]
                splitChildren[source.id] = fragments
                projectedSegments.replaceSubrange(index ... index, with: fragments)

            default:
                continue
            }
        }

        var projectedReview: [ReviewItem] = []
        for item in review {
            if let children = splitChildren[item.segment.id] {
                for (index, child) in children.enumerated() {
                    projectedReview.append(
                        ReviewItem(
                            id: derivedID(item.id, index: index),
                            segment: child,
                            reason: item.reason,
                            manuallyAssignedToProfessor: item.manuallyAssignedToProfessor,
                        ),
                    )
                }
            } else if let current = projectedSegments.first(where: { $0.id == item.segment.id }) {
                var updated = item
                updated.segment = current
                projectedReview.append(updated)
            }
        }

        for operation in overlay.operations where operation.kind == .review {
            let active = operation.isActive ?? true
            var matched = false
            for index in projectedReview.indices {
                let isIDMatch = operation.segmentIDs.contains(projectedReview[index].segment.id)
                let isSplitParentMatch = splitChildren.contains { parentID, children in
                    operation.segmentIDs.contains(parentID)
                        && children.contains(where: { $0.id == projectedReview[index].segment.id })
                }
                let isAnchorMatch = !isIDMatch
                    && !isSplitParentMatch
                    && matchingIndex(for: operation, in: [projectedReview[index].segment]) != nil
                if isIDMatch || isSplitParentMatch || isAnchorMatch {
                    projectedReview[index].manuallyAssignedToProfessor = active
                    matched = true
                }
            }
            if !matched, !operation.segmentIDs.isEmpty || operation.anchorText != nil {
                unresolved.append(operation.id)
            }
        }

        let names = displayNames(
            speakers: speakers,
            operations: overlay.operations,
        )
        let projectedSpeakers = buildSpeakers(
            segments: projectedSegments,
            existing: speakers,
            names: names,
            mergeMap: mergeMap.map,
        )
        let knownIDs = Set(projectedSpeakers.map(\.id) + projectedSegments.map(\.speakerID))
        for operation in overlay.operations where operation.kind == .rename {
            guard let speakerID = operation.speakerID,
                  let displayName = operation.displayName,
                  !speakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  knownIDs.contains(resolve(speakerID, using: mergeMap.map))
            else {
                unresolved.append(operation.id)
                continue
            }
        }
        var projectedProfessor = professorSpeakerID.map { resolve($0, using: mergeMap.map) }
        var projectedProfessorIsAutomatic = professorSelectionIsAutomatic
        for operation in overlay.operations where operation.kind == .professorConfirmation {
            guard let id = operation.speakerID else {
                unresolved.append(operation.id)
                continue
            }
            let resolved = resolve(id, using: mergeMap.map)
            guard knownIDs.contains(resolved) else {
                unresolved.append(operation.id)
                continue
            }
            projectedProfessor = resolved
            projectedProfessorIsAutomatic = false
        }

        return SpeakerCorrectionProjectionResult(
            segments: projectedSegments,
            speakers: projectedSpeakers,
            review: projectedReview,
            professorSpeakerID: projectedProfessor,
            professorSelectionIsAutomatic: projectedProfessorIsAutomatic,
            unresolvedOperationIDs: stableUnique(unresolved),
        )
    }

    static func canSplit(_ segment: TranscriptSegment) -> Bool {
        guard let timings = segment.wordTimings,
              timings.count > 1,
              TranscriptWordTiming.renderedText(timings) == segment.text
        else { return false }
        return timings.dropLast().allSatisfy { timing in
            timing.start.isFinite && timing.end.isFinite && timing.end > timing.start
        }
    }

    static func normalizedText(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .joined(separator: " ")
            .lowercased()
    }

    private struct MergeMap {
        var map: [String: String]
        var unresolved: [UUID]
    }

    private static func makeMergeMap(
        operations: [SpeakerCorrectionOperation],
        knownSpeakerIDs: Set<String>,
    ) -> MergeMap {
        var map: [String: String] = [:]
        var unresolved: [UUID] = []
        let mergeOperations = operations.filter { $0.kind == .merge }
        let mergeSources = Set(mergeOperations.compactMap { operation in
            operation.speakerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        for operation in mergeOperations {
            guard let source = operation.speakerID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let target = operation.targetSpeakerID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty,
                  !target.isEmpty,
                  source != target,
                  (knownSpeakerIDs.contains(target) || mergeSources.contains(target)),
                  !wouldCreateCycle(source: source, target: target, map: map)
            else {
                unresolved.append(operation.id)
                continue
            }
            map[source] = target
        }

        // A corrected projection may no longer contain intermediate merge
        // identities. Accept a chain only when its final root is still known;
        // otherwise retain the operation as unresolved and do not invent a
        // speaker that the current automatic result did not produce.
        let invalidSources = Set(map.keys.filter { source in
            !knownSpeakerIDs.contains(resolve(source, using: map))
        })
        if !invalidSources.isEmpty {
            for operation in mergeOperations {
                if let source = operation.speakerID,
                   invalidSources.contains(source.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    unresolved.append(operation.id)
                }
            }
            for source in invalidSources {
                map.removeValue(forKey: source)
            }
        }
        return MergeMap(map: map, unresolved: unresolved)
    }

    private static func wouldCreateCycle(source: String, target: String, map: [String: String]) -> Bool {
        var current = target
        var visited: Set<String> = []
        while let next = map[current] {
            if next == source { return true }
            guard visited.insert(current).inserted else { return true }
            current = next
        }
        return current == source
    }

    private static func resolve(_ id: String, using map: [String: String]) -> String {
        var current = id
        var visited: Set<String> = []
        while let next = map[current], visited.insert(current).inserted {
            current = next
        }
        return current
    }

    private static func matchingIndex(
        for operation: SpeakerCorrectionOperation,
        in segments: [TranscriptSegment],
    ) -> Int? {
        if let id = operation.segmentIDs.first,
           let exactIndex = segments.firstIndex(where: { $0.id == id }) {
            if operation.kind != .split || operation.anchorText == nil
                || normalizedText(segments[exactIndex].text) == normalizedText(operation.anchorText!) {
                return exactIndex
            }
            return nil
        }
        guard let anchorText = operation.anchorText else { return nil }
        let normalizedAnchor = normalizedText(anchorText)
        let textMatches = segments.indices.filter {
            normalizedText(segments[$0].text) == normalizedAnchor
        }
        guard !textMatches.isEmpty else { return nil }
        let timedMatches: [Int]
        if let anchorStart = operation.anchorStart, let anchorEnd = operation.anchorEnd {
            timedMatches = textMatches.filter { index in
                overlapFraction(
                    start: segments[index].start,
                    end: segments[index].end,
                    otherStart: anchorStart,
                    otherEnd: anchorEnd,
                ) >= 0.5
            }
        } else {
            timedMatches = textMatches
        }
        return timedMatches.count == 1 ? timedMatches[0] : nil
    }

    private static func overlapFraction(
        start: TimeInterval,
        end: TimeInterval,
        otherStart: TimeInterval,
        otherEnd: TimeInterval,
    ) -> Double {
        let overlap = max(0, min(end, otherEnd) - max(start, otherStart))
        let shortest = min(max(0.05, end - start), max(0.05, otherEnd - otherStart))
        return overlap / shortest
    }

    private static func split(
        _ segment: TranscriptSegment,
        operation: SpeakerCorrectionOperation,
    ) -> [TranscriptSegment]? {
        guard canSplit(segment),
              let timings = segment.wordTimings,
              let after = operation.splitAfterWordIndex,
              after > 0,
              after < timings.count
        else { return nil }
        let leftTimings = Array(timings[..<after])
        let rightTimings = Array(timings[after...])
        guard let left = makeFragment(segment, timings: leftTimings, id: derivedID(operation.id, index: 0)),
              let right = makeFragment(segment, timings: rightTimings, id: derivedID(operation.id, index: 1))
        else { return nil }
        return [left, right]
    }

    private static func makeFragment(
        _ segment: TranscriptSegment,
        timings: [TranscriptWordTiming],
        id: UUID,
    ) -> TranscriptSegment? {
        guard let first = timings.first, let last = timings.last,
              first.start.isFinite,
              last.end.isFinite,
              last.end > first.start
        else { return nil }
        var fragment = segment
        fragment.id = id
        fragment.start = first.start
        fragment.end = last.end
        fragment.text = TranscriptWordTiming.renderedText(timings)
        fragment.wordTimings = timings
        return fragment
    }

    private static func hasSplitFragments(
        for operation: SpeakerCorrectionOperation,
        in segments: [TranscriptSegment],
    ) -> Bool {
        let first = derivedID(operation.id, index: 0)
        let second = derivedID(operation.id, index: 1)
        return segments.contains(where: { $0.id == first })
            && segments.contains(where: { $0.id == second })
    }

    private static func displayNames(
        speakers: [SpeakerRecord],
        operations: [SpeakerCorrectionOperation],
    ) -> [String: String] {
        var names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        for operation in operations where operation.kind == .rename {
            guard let speakerID = operation.speakerID,
                  let displayName = operation.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !displayName.isEmpty
            else { continue }
            names[speakerID] = displayName
        }
        return names
    }

    private static func buildSpeakers(
        segments: [TranscriptSegment],
        existing: [SpeakerRecord],
        names: [String: String],
        mergeMap: [String: String],
    ) -> [SpeakerRecord] {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let groups = Dictionary(grouping: segments, by: \.speakerID)
        return groups.compactMap { id, values in
            guard !isUnknown(id) else { return nil }
            let sourceIDs = Array(existingByID.keys.filter { resolve($0, using: mergeMap) == id })
            let base = existingByID[id] ?? sourceIDs.compactMap { existingByID[$0] }.first
            let displayName = preferredDisplayName(
                rootID: id,
                sourceIDs: sourceIDs,
                names: names,
                existing: existingByID,
            )
            let total = values.reduce(0) { $0 + max(0, $1.end - $1.start) }
            let confidence = values.reduce(0) { $0 + $1.confidence } / Double(max(1, values.count))
            return SpeakerRecord(
                id: id,
                displayName: displayName,
                totalSpeakingTime: total,
                recentFragments: values.suffix(3).map(\.text),
                confidence: confidence,
                embedding: base?.embedding,
            )
        }.sorted {
            if $0.totalSpeakingTime == $1.totalSpeakingTime { return $0.id < $1.id }
            return $0.totalSpeakingTime > $1.totalSpeakingTime
        }
    }

    private static func preferredDisplayName(
        rootID: String,
        sourceIDs: some Collection<String>,
        names: [String: String],
        existing: [String: SpeakerRecord],
    ) -> String {
        let candidates = [rootID] + Array(sourceIDs)
        for id in candidates {
            let name = names[id] ?? existing[id]?.displayName ?? id
            if !isAutomaticName(name, for: id) { return name }
        }
        return names[rootID] ?? existing[rootID]?.displayName ?? rootID
    }

    private static func isAutomaticName(_ value: String, for id: String) -> Bool {
        if value == id { return true }
        let parts = value.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" })
        return parts.count == 2
            && Int(parts[1]) != nil
            && ["persona", "person", "personne", "speaker"].contains(parts[0].lowercased())
    }

    private static func isUnknown(_ id: String) -> Bool {
        ["persona desconocida", "person unknown", "personne inconnue", "unknown person", "unknown speaker"]
            .contains(id.lowercased())
    }

    private static func derivedID(_ seed: UUID, index: Int) -> UUID {
        var bytes = seed.uuid
        withUnsafeMutableBytes(of: &bytes) { raw in
            raw[14] ^= UInt8(truncatingIfNeeded: index * 53)
            raw[15] ^= UInt8(truncatingIfNeeded: index * 97)
        }
        return UUID(uuid: bytes)
    }

    private static func stableUnique(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
