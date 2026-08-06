import Foundation

/// Removes the repeated prefix introduced by overlapping ASR windows.
enum OverlapDeduplicator {
    static func novelText(stable: String, incoming: String, maximumWords: Int = 80) -> String {
        let oldWords = words(stable)
        let newWords = words(incoming)
        guard !newWords.isEmpty else { return "" }
        let maxOverlap = min(maximumWords, oldWords.count, newWords.count)
        var overlap = 0
        if maxOverlap > 0 {
            for count in stride(from: maxOverlap, through: 1, by: -1) {
                let oldSuffix = oldWords.suffix(count).map(normalized)
                let newPrefix = newWords.prefix(count).map(normalized)
                if oldSuffix == newPrefix {
                    overlap = count
                    break
                }
            }
        }
        return newWords.dropFirst(overlap).joined(separator: " ")
    }

    static func merge(stable: String, incoming: String) -> String {
        let novel = novelText(stable: stable, incoming: incoming)
        guard !novel.isEmpty else { return stable }
        guard !stable.isEmpty else { return novel }
        return stable + " " + novel
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

struct LiveTranscriptAccumulator: Equatable {
    private(set) var stableText = ""
    private(set) var provisionalText = ""

    mutating func accept(_ hypothesis: String, confirmedByPause: Bool) {
        let clean = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            if confirmedByPause { confirmProvisional() }
            return
        }

        let base = stableText
        let novel = OverlapDeduplicator.novelText(stable: base, incoming: clean)
        if confirmedByPause {
            stableText = OverlapDeduplicator.merge(stable: stableText, incoming: clean)
            provisionalText = ""
            return
        }

        if !provisionalText.isEmpty {
            let common = Self.commonWordPrefix(provisionalText, novel)
            if common.count >= 2 {
                stableText = OverlapDeduplicator.merge(stable: stableText, incoming: common.joined(separator: " "))
            }
        }
        provisionalText = OverlapDeduplicator.novelText(stable: stableText, incoming: clean)
    }

    mutating func confirmProvisional() {
        stableText = OverlapDeduplicator.merge(stable: stableText, incoming: provisionalText)
        provisionalText = ""
    }

    private static func commonWordPrefix(_ lhs: String, _ rhs: String) -> [String] {
        let left = lhs.split(whereSeparator: \.isWhitespace).map(String.init)
        let right = rhs.split(whereSeparator: \.isWhitespace).map(String.init)
        var result: [String] = []
        for pair in zip(left, right) {
            let a = pair.0.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let b = pair.1.lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard a == b else { break }
            result.append(pair.1)
        }
        return result
    }
}

enum SpeakerAssignment {
    static func assign(
        transcript: [TranscriptSegment],
        diarization: [DiarizationSpan],
        confidenceThreshold: Double = 0.55
    ) -> (segments: [TranscriptSegment], review: [ReviewItem]) {
        var review: [ReviewItem] = []
        let assigned = transcript.map { original -> TranscriptSegment in
            var segment = original
            let duration = max(0.05, segment.end - segment.start)
            let overlaps = diarization.compactMap { span -> (DiarizationSpan, Double)? in
                let amount = max(0, min(segment.end, span.end) - max(segment.start, span.start))
                return amount > 0 ? (span, amount) : nil
            }
            let bySpeaker = Dictionary(grouping: overlaps, by: { $0.0.speakerID })
                .mapValues { $0.reduce(0) { $0 + $1.1 } }
            if let best = bySpeaker.max(by: { $0.value < $1.value }) {
                segment.speakerID = best.key
                segment.confidence = min(1, best.value / duration)
            } else if let nearest = diarization.min(by: {
                gap(from: segment, to: $0) < gap(from: segment, to: $1)
            }) {
                segment.speakerID = nearest.speakerID
                segment.confidence = 0.25
            } else {
                segment.speakerID = "Persona desconocida"
                segment.confidence = 0
            }
            segment.overlappingVoices = bySpeaker.count > 1
            if segment.confidence < confidenceThreshold || segment.overlappingVoices {
                let reason = segment.overlappingVoices
                    ? "Voces superpuestas; confirmar manualmente"
                    : "Confianza de hablante baja (\(Int(segment.confidence * 100)) %)"
                review.append(ReviewItem(segment: segment, reason: reason))
            }
            return segment
        }
        return (assigned, review)
    }

    static func provisionalProfessor(speakers: [SpeakerRecord]) -> String? {
        speakers.max(by: { $0.totalSpeakingTime < $1.totalSpeakingTime })?.id
    }

    static func professorSegments(
        from segments: [TranscriptSegment],
        professorID: String?,
        review: [ReviewItem]
    ) -> [TranscriptSegment] {
        guard let professorID else { return [] }
        let manualIDs = Set(review.filter(\.manuallyAssignedToProfessor).map(\.segment.id))
        return segments.filter {
            ($0.speakerID == professorID && $0.confidence >= 0.55 && !$0.overlappingVoices)
                || manualIDs.contains($0.id)
        }
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        var dot = 0.0
        var a2 = 0.0
        var b2 = 0.0
        for index in lhs.indices {
            let a = Double(lhs[index])
            let b = Double(rhs[index])
            dot += a * b
            a2 += a * a
            b2 += b * b
        }
        guard a2 > 0, b2 > 0 else { return nil }
        return dot / (a2.squareRoot() * b2.squareRoot())
    }

    private static func gap(from segment: TranscriptSegment, to span: DiarizationSpan) -> Double {
        if segment.end < span.start { return span.start - segment.end }
        if segment.start > span.end { return segment.start - span.end }
        return 0
    }
}

enum TranscriptExporter {
    static func plainText(_ segments: [TranscriptSegment]) -> String {
        segments.map { "[\($0.formattedTimestamp)] \($0.speakerID): \($0.text)" }
            .joined(separator: "\n")
    }

    static func markdown(subject: String, date: Date, segments: [TranscriptSegment]) -> String {
        let dateText = date.formatted(date: .long, time: .shortened)
        return "# \(subject)\n\n_\(dateText)_\n\n" + segments.map {
            "- **[\($0.formattedTimestamp)] \($0.speakerID):** \($0.text)"
        }.joined(separator: "\n") + "\n"
    }

    static func srt(_ segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(Timecode.srt(segment.start)) --> \(Timecode.srt(max(segment.end, segment.start + 0.2)))\n\(segment.text)"
        }.joined(separator: "\n\n") + (segments.isEmpty ? "" : "\n")
    }
}
