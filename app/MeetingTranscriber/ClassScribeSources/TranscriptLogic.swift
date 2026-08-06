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

enum LiveTranscriptChunkStatus: String, Codable {
    case committed
    case provisional
}

struct LiveTranscriptChunk: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: TimeInterval?
    var end: TimeInterval?
    var text: String
    var createdAt = Date()
    var status: LiveTranscriptChunkStatus
    var revision = 1
}

struct LiveTranscriptAccumulator: Codable, Equatable {
    private(set) var committedChunks: [LiveTranscriptChunk] = []
    private(set) var provisionalChunk: LiveTranscriptChunk?

    var stableText: String {
        committedChunks.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var provisionalText: String {
        provisionalChunk?.text ?? ""
    }

    var visibleText: String {
        [stableText, provisionalText].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    init() {}

    init(legacyStable: String, provisional: String) {
        let stable = legacyStable.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stable.isEmpty {
            committedChunks = [LiveTranscriptChunk(text: stable, status: .committed)]
        }
        let tail = provisional.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            provisionalChunk = LiveTranscriptChunk(text: tail, status: .provisional)
        }
    }

    mutating func accept(
        _ hypothesis: String,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil,
        confirmedByPause: Bool,
    ) {
        let clean = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            if confirmedByPause {
                confirmProvisional()
            }
            return
        }

        // A later sliding window may be a completely different hypothesis. The
        // previous tail is evidence already shown to the user, so commit it
        // before installing/revising the new tail. Minor repetition is safer
        // than erasing a paragraph from a class.
        confirmProvisional()
        let novel = OverlapDeduplicator.novelText(stable: stableText, incoming: clean)
        guard !novel.isEmpty else { return }

        var chunk = LiveTranscriptChunk(
            start: start,
            end: end,
            text: novel,
            status: confirmedByPause ? .committed : .provisional,
        )
        if confirmedByPause {
            chunk.status = .committed
            committedChunks.append(chunk)
            return
        }
        provisionalChunk = chunk
    }

    mutating func confirmProvisional() {
        guard var provisionalChunk else { return }
        provisionalChunk.status = .committed
        committedChunks.append(provisionalChunk)
        self.provisionalChunk = nil
    }
}

enum SpeakerAssignment {
    static func assign(
        transcript: [TranscriptSegment],
        diarization: [DiarizationSpan],
        confidenceThreshold: Double = 0.55,
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
        review: [ReviewItem],
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
        if segment.end < span.start {
            return span.start - segment.end
        }
        if segment.start > span.end {
            return segment.start - span.end
        }
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

    static func markdown(subject: String, date: Date, text: String) -> String {
        let dateText = date.formatted(date: .long, time: .shortened)
        return "# \(subject)\n\n_\(dateText)_\n\n\(text)\n"
    }

    static func srt(_ segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(Timecode.srt(segment.start)) --> \(Timecode.srt(max(segment.end, segment.start + 0.2)))\n\(segment.text)"
        }.joined(separator: "\n\n") + (segments.isEmpty ? "" : "\n")
    }
}

enum TranscriptActions {
    static func bestAvailable(
        preferredEdit: String?,
        professorEdit: String?,
        professor: String,
        everyoneEdit: String?,
        everyone: String,
        liveEdit: String?,
        live: String,
    ) -> String {
        let candidates: [String?] = [
            preferredEdit,
            resolved(edit: professorEdit, base: professor),
            resolved(edit: everyoneEdit, base: everyone),
            resolved(edit: liveEdit, base: live),
        ]
        return candidates.compactMap { candidate -> String? in
            guard let candidate else { return nil }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first ?? ""
    }

    static func chatEnvelope(
        subject: String,
        date: Date,
        duration: TimeInterval,
        mode: CaptureMode,
        source: String,
        transcript: String,
    ) -> String {
        """
        Materia: \(subject)
        Fecha: \(date.formatted(date: .long, time: .shortened))
        Duración: \(Timecode.display(duration))
        Modo: \(mode.rawValue)
        Fuente: \(source)

        Transcripción:

        \(transcript)
        """
    }

    private static func resolved(edit: String?, base: String) -> String? {
        edit ?? base
    }
}

enum TranscriptExportFormat {
    case txt
    case markdown
    case srt
}

struct TranscriptExportPlan: Equatable {
    var content: String
    var warning: String?
}

enum TranscriptExportPolicyError: LocalizedError, Equatable {
    case emptyTranscript
    case missingTimedSegments

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "No se puede exportar una transcripción vacía."
        case .missingTimedSegments:
            "SRT requiere segmentos con tiempos; el TXT y Markdown siguen disponibles."
        }
    }
}

enum TranscriptExportPolicy {
    static func make(
        format: TranscriptExportFormat,
        subject: String,
        date: Date,
        text: String,
        timedSegments: [TranscriptSegment],
        hasFreeformEdit: Bool,
    ) throws -> TranscriptExportPlan {
        let readable = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readable.isEmpty else { throw TranscriptExportPolicyError.emptyTranscript }
        switch format {
        case .txt:
            return TranscriptExportPlan(content: readable, warning: nil)
        case .markdown:
            return TranscriptExportPlan(
                content: TranscriptExporter.markdown(subject: subject, date: date, text: readable),
                warning: nil,
            )
        case .srt:
            guard !timedSegments.isEmpty else { throw TranscriptExportPolicyError.missingTimedSegments }
            return TranscriptExportPlan(
                content: TranscriptExporter.srt(timedSegments),
                warning: hasFreeformEdit
                    ? "La edición libre no puede conservar tiempos palabra por palabra. TXT y Markdown sí contienen tu edición."
                    : nil,
            )
        }
    }
}
