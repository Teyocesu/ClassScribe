import Foundation

/// Keeps an ASR result separate from capture signal health. Energy/audibility
/// is not enough to publish `AsrPhase.transcribing`; the backend must return
/// non-whitespace text accepted by this gate.
enum LiveASRResultGate {
    static func acceptedText(_ result: String) -> String? {
        let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    static func shouldPublishTranscribing(_ result: String) -> Bool {
        acceptedText(result) != nil
    }
}

/// Advances only after an ASR window has produced a usable result. A failed
/// inference therefore retries the exact same audio range instead of silently
/// dropping 5.5 seconds of class content.
struct LiveTranscriptionCursor: Equatable, Sendable {
    let hopSamples: Int64
    private(set) var committedEnd: Int64 = 0
    private(set) var pendingEnd: Int64?

    init(hopSamples: Int64 = 88_000) {
        precondition(hopSamples > 0)
        self.hopSamples = hopSamples
    }

    mutating func nextWindowEnd(totalSamples: Int64, preferLatest: Bool = false) -> Int64? {
        if preferLatest {
            pendingEnd = nil
        } else if let pendingEnd {
            return totalSamples >= pendingEnd ? pendingEnd : nil
        }
        let next = preferLatest ? latestAlignedEnd(totalSamples: totalSamples) : committedEnd + hopSamples
        guard next >= hopSamples, next > committedEnd else { return nil }
        pendingEnd = next
        return totalSamples >= next ? next : nil
    }

    /// Replaces a pending end that has fallen out of the live buffer's retained
    /// range. The full WAV remains authoritative; live captions resume from the
    /// newest hop instead of remaining stuck on an index the ring no longer has.
    mutating func recoverFromExpiredWindow(totalSamples: Int64) -> (end: Int64, skippedSamples: Int64)? {
        guard let expired = pendingEnd else { return nil }
        let latest = latestAlignedEnd(totalSamples: totalSamples)
        guard latest >= hopSamples, latest > committedEnd else { return nil }
        pendingEnd = latest
        return (latest, max(0, latest - expired))
    }

    mutating func commit(windowEndingAt end: Int64) {
        guard end > committedEnd else { return }
        committedEnd = end
        if pendingEnd == end {
            pendingEnd = nil
        }
    }

    private func latestAlignedEnd(totalSamples: Int64) -> Int64 {
        totalSamples - max(0, totalSamples % hopSamples)
    }
}

/// Bounds repeated live-ASR failures. Final full-file transcription remains the
/// durable fallback, while the live loop retries at progressively wider gaps
/// instead of repeatedly reloading a missing/broken model.
struct LiveTranscriptionRetryPolicy: Equatable, Sendable {
    private static let delays: [TimeInterval] = [2, 4, 8, 15, 30]
    private(set) var consecutiveFailures = 0
    private(set) var retryAfterUptime: TimeInterval?

    func canAttempt(atUptime now: TimeInterval) -> Bool {
        retryAfterUptime.map { now >= $0 } ?? true
    }

    @discardableResult
    mutating func recordFailure(atUptime now: TimeInterval) -> TimeInterval {
        let index = min(consecutiveFailures, Self.delays.count - 1)
        let delay = Self.delays[index]
        consecutiveFailures += 1
        retryAfterUptime = now + delay
        return delay
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        retryAfterUptime = nil
    }
}

/// Bounded wait used after cancelling live inference. The underlying task is
/// intentionally not cancelled here (the caller already did so); this merely
/// prevents a Core ML call that ignores cancellation from freezing Stop.
enum TaskCompletionGracePeriod {
    static func wait(for task: Task<Void, Never>, timeout: TimeInterval) async -> Bool {
        guard timeout > 0 else { return false }
        let box = CompletionRaceBox()
        return await withCheckedContinuation { continuation in
            box.install(continuation)
            Task.detached(priority: .utility) {
                await task.value
                box.resolve(true)
            }
            Task.detached(priority: .utility) {
                let nanoseconds = UInt64(min(timeout, 86_400) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                box.resolve(false)
            }
        }
    }
}

private final class CompletionRaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var earlyResult: Bool?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        let result: Bool?
        lock.lock()
        precondition(self.continuation == nil && !finished)
        if let earlyResult {
            finished = true
            result = earlyResult
        } else {
            self.continuation = continuation
            result = nil
        }
        lock.unlock()
        if let result {
            continuation.resume(returning: result)
        }
    }

    func resolve(_ value: Bool) {
        let continuation: CheckedContinuation<Bool, Never>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if let waiting = self.continuation {
            finished = true
            self.continuation = nil
            continuation = waiting
        } else {
            earlyResult = value
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

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
    /// Optional for backwards-compatible decoding of version-2 live snapshots.
    var paragraphBreakBefore: Bool?
}

struct LiveTranscriptAccumulator: Codable, Equatable {
    private(set) var committedChunks: [LiveTranscriptChunk] = []
    private(set) var provisionalChunk: LiveTranscriptChunk?
    /// Optional so snapshots written before paragraph-aware rendering remain
    /// decodable. `true` is consumed by the next genuinely novel chunk.
    private var paragraphBreakPending: Bool?

    var stableText: String {
        Self.render(committedChunks)
    }

    var provisionalText: String {
        provisionalChunk?.text ?? ""
    }

    var visibleText: String {
        Self.render(committedChunks + [provisionalChunk].compactMap { $0 })
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
        pauseDuration: TimeInterval = 0,
    ) {
        let clean = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            if confirmedByPause {
                confirmProvisional()
            }
            if TranscriptParagraphPolicy.shouldBreakAfter(
                text: visibleText,
                trailingSilence: pauseDuration,
            ) {
                paragraphBreakPending = true
            }
            return
        }

        // A later sliding window may be a completely different hypothesis. The
        // previous tail is evidence already shown to the user, so commit it
        // before installing/revising the new tail. Minor repetition is safer
        // than erasing a paragraph from a class.
        confirmProvisional()
        let novel = OverlapDeduplicator.novelText(stable: stableText, incoming: clean)
        guard !novel.isEmpty else {
            if TranscriptParagraphPolicy.shouldBreakAfter(
                text: clean,
                trailingSilence: pauseDuration,
            ) {
                paragraphBreakPending = true
            }
            return
        }

        var chunk = LiveTranscriptChunk(
            start: start,
            end: end,
            text: novel,
            status: confirmedByPause ? .committed : .provisional,
            paragraphBreakBefore: paragraphBreakPending == true ? true : nil,
        )
        paragraphBreakPending = TranscriptParagraphPolicy.shouldBreakAfter(
            text: clean,
            trailingSilence: pauseDuration,
        ) ? true : nil
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

    private static func render(_ chunks: [LiveTranscriptChunk]) -> String {
        chunks.reduce(into: "") { result, chunk in
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if !result.isEmpty {
                result += chunk.paragraphBreakBefore == true ? "\n\n" : " "
            }
            result += text
        }
    }
}

/// A deliberately conservative layout policy. Hesitations of two or three
/// seconds are common while explaining a topic, so live text only starts a new
/// paragraph after at least four seconds of silence and a strong sentence end.
/// Final timed segments additionally use speaker changes as context changes.
enum TranscriptParagraphPolicy {
    static let longPause: TimeInterval = 4

    static func shouldBreakAfter(text: String, trailingSilence: TimeInterval) -> Bool {
        trailingSilence >= longPause && hasStrongSentenceEnding(text)
    }

    static func shouldBreak(
        previous: TranscriptSegment,
        next: TranscriptSegment,
    ) -> Bool {
        guard previous.speakerID == next.speakerID else { return true }
        return max(0, next.start - previous.end) >= longPause
    }

    private static func hasStrongSentenceEnding(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?…".contains(last)
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
        paragraphs(segments).map { paragraph in
            "[\(Timecode.display(paragraph.start))] \(paragraph.speakerID): \(paragraph.text)"
        }.joined(separator: "\n\n")
    }

    static func markdown(subject: String, date: Date, segments: [TranscriptSegment]) -> String {
        let dateText = date.formatted(date: .long, time: .shortened)
        return "# \(subject)\n\n_\(dateText)_\n\n" + paragraphs(segments).map { paragraph in
            "- **[\(Timecode.display(paragraph.start))] \(paragraph.speakerID):** \(paragraph.text)"
        }.joined(separator: "\n\n") + "\n"
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

    private struct Paragraph {
        var start: TimeInterval
        var speakerID: String
        var text: String
        var lastSegment: TranscriptSegment
    }

    private static func paragraphs(_ segments: [TranscriptSegment]) -> [Paragraph] {
        var result: [Paragraph] = []
        for segment in segments {
            let clean = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if var current = result.last,
               !TranscriptParagraphPolicy.shouldBreak(previous: current.lastSegment, next: segment) {
                // Final segments are already distinct timed ranges. Preserve
                // intentional repetitions ("no, no", names, formulas) rather
                // than applying the live-window overlap deduplicator here.
                current.text += " " + clean
                current.lastSegment = segment
                result[result.count - 1] = current
            } else {
                result.append(Paragraph(
                    start: segment.start,
                    speakerID: segment.speakerID,
                    text: clean,
                    lastSegment: segment,
                ))
            }
        }
        return result
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
