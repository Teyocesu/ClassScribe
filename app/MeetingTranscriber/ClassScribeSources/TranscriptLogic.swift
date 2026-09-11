import Foundation

/// Keeps an ASR result separate from capture signal health. Energy/audibility
/// is not enough to publish `AsrPhase.transcribing`; the backend must return
/// non-whitespace text accepted by this gate.
enum LiveASRResultGate {
    static func acceptedText(_ result: String) -> String? {
        let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    static func acceptedText(
        _ result: String,
        speechEvidence: SpeechPresenceEvidence,
    ) -> String? {
        guard speechEvidence.hasVoice else { return nil }
        return acceptedText(result)
    }

    static func shouldPublishTranscribing(_ result: String) -> Bool {
        acceptedText(result) != nil
    }

    static func shouldPublishTranscribing(
        _ result: String,
        speechEvidence: SpeechPresenceEvidence,
    ) -> Bool {
        acceptedText(result, speechEvidence: speechEvidence) != nil
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
    private(set) var isUnavailableForSession = false

    func canAttempt(atUptime now: TimeInterval) -> Bool {
        guard !isUnavailableForSession else { return false }
        return retryAfterUptime.map { now >= $0 } ?? true
    }

    @discardableResult
    mutating func recordFailure(atUptime now: TimeInterval) -> TimeInterval {
        guard !isUnavailableForSession else { return 0 }
        guard consecutiveFailures < Self.delays.count else {
            isUnavailableForSession = true
            retryAfterUptime = nil
            return 0
        }
        let index = min(consecutiveFailures, Self.delays.count - 1)
        let delay = Self.delays[index]
        consecutiveFailures += 1
        retryAfterUptime = now + delay
        return delay
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        retryAfterUptime = nil
        isUnavailableForSession = false
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
        var assigned: [TranscriptSegment] = []
        var review: [ReviewItem] = []
        for original in transcript {
            let projected = splitAtSpeakerBoundaries(original, diarization: diarization)
                ?? [assignWhole(original, diarization: diarization)]
            assigned.append(contentsOf: projected)
            for segment in projected where segment.confidence < confidenceThreshold || segment.overlappingVoices {
                let reason = segment.overlappingVoices
                    ? "Voces superpuestas; confirmar manualmente"
                    : "Confianza de hablante baja (\(Int(segment.confidence * 100)) %)"
                review.append(ReviewItem(segment: segment, reason: reason))
            }
        }
        return (assigned, review)
    }

    private struct Evidence {
        var speakerID: String
        var confidence: Double
        var overlappingVoices: Bool
    }

    private struct WordProjection {
        var timing: TranscriptWordTiming
        var evidence: Evidence
    }

    /// Splits only when the exact word sequence used to create the ASR segment
    /// is still available. Historical sessions and any text whose timing
    /// metadata no longer reproduces it keep the conservative whole-segment
    /// behavior instead of receiving invented timestamps.
    private static func splitAtSpeakerBoundaries(
        _ original: TranscriptSegment,
        diarization: [DiarizationSpan],
    ) -> [TranscriptSegment]? {
        guard let timings = original.wordTimings,
              timings.count > 1,
              TranscriptWordTiming.renderedText(timings) == original.text
        else { return nil }

        var words = timings.map {
            WordProjection(
                timing: $0,
                evidence: evidence(start: $0.start, end: $0.end, diarization: diarization),
            )
        }
        // Keep a standalone punctuation token with an adjacent spoken word so
        // a diarization boundary cannot manufacture a punctuation-only turn.
        for index in words.indices where isStandalonePunctuation(words[index].timing.text) {
            if index > words.startIndex {
                words[index].evidence = words[index - 1].evidence
            } else if index + 1 < words.endIndex {
                words[index].evidence = words[index + 1].evidence
            }
        }

        var groups: [[WordProjection]] = []
        for word in words {
            if let lastSpeaker = groups.last?.last?.evidence.speakerID,
               lastSpeaker == word.evidence.speakerID {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        guard groups.count > 1 else { return nil }

        return groups.enumerated().map { groupIndex, group in
            let groupTimings = group.map(\.timing)
            let duration = group.reduce(0.0) { partial, word in
                partial + max(0.05, word.timing.end - word.timing.start)
            }
            let confidence = group.reduce(0.0) { partial, word in
                let wordDuration = max(0.05, word.timing.end - word.timing.start)
                return partial + word.evidence.confidence * wordDuration
            } / max(0.05, duration)
            return TranscriptSegment(
                id: splitID(original.id, index: groupIndex),
                start: groupTimings[0].start,
                end: max(groupTimings[groupTimings.count - 1].end, groupTimings[0].start + 0.2),
                text: TranscriptWordTiming.renderedText(groupTimings),
                speakerID: group[0].evidence.speakerID,
                confidence: min(1, confidence),
                provisional: original.provisional,
                overlappingVoices: group.contains(where: \.evidence.overlappingVoices),
                wordTimings: groupTimings,
            )
        }
    }

    private static func assignWhole(
        _ original: TranscriptSegment,
        diarization: [DiarizationSpan],
    ) -> TranscriptSegment {
        var segment = original
        let value = evidence(start: segment.start, end: segment.end, diarization: diarization)
        segment.speakerID = value.speakerID
        segment.confidence = value.confidence
        segment.overlappingVoices = value.overlappingVoices
        return segment
    }

    private static func evidence(
        start: TimeInterval,
        end: TimeInterval,
        diarization: [DiarizationSpan],
    ) -> Evidence {
        let duration = max(0.05, end - start)
        var bySpeaker: [String: TimeInterval] = [:]
        for span in diarization {
            let amount = max(0, min(end, span.end) - max(start, span.start))
            if amount > 0 { bySpeaker[span.speakerID, default: 0] += amount }
        }
        if let best = bySpeaker.sorted(by: {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }).first {
            return Evidence(
                speakerID: best.key,
                confidence: min(1, best.value / duration),
                overlappingVoices: bySpeaker.count > 1,
            )
        }
        if let nearest = diarization.sorted(by: {
            let leftGap = gap(start: start, end: end, to: $0)
            let rightGap = gap(start: start, end: end, to: $1)
            if leftGap != rightGap { return leftGap < rightGap }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.speakerID < $1.speakerID
        }).first {
            return Evidence(speakerID: nearest.speakerID, confidence: 0.25, overlappingVoices: false)
        }
        return Evidence(speakerID: "Persona desconocida", confidence: 0, overlappingVoices: false)
    }

    private static func isStandalonePunctuation(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
    }

    /// The original ID remains attached to the first fragment. Later IDs are
    /// stable derivations, so retrying the same ASR run does not churn review
    /// or manual-assignment identity.
    private static func splitID(_ original: UUID, index: Int) -> UUID {
        guard index > 0 else { return original }
        var pieces = original.uuidString.split(separator: "-").map(String.init)
        guard pieces.count == 5, let tail = UInt64(pieces[4], radix: 16) else { return original }
        let mixed = (tail &+ (UInt64(index) &* 0x9E37_79B9_7F4A_7C15)) & 0x0000_FFFF_FFFF_FFFF
        pieces[4] = String(format: "%012llX", mixed)
        return UUID(uuidString: pieces.joined(separator: "-")) ?? original
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

    private static func gap(start: TimeInterval, end: TimeInterval, to span: DiarizationSpan) -> Double {
        if end < span.start {
            return span.start - end
        }
        if start > span.end {
            return start - span.end
        }
        return 0
    }
}

enum TranscriptExporter {
    static func plainText(_ segments: [TranscriptSegment]) -> String {
        plainText(segments, speakerNames: [:])
    }

    static func plainText(_ segments: [TranscriptSegment], speakerNames: [String: String]) -> String {
        paragraphs(segments).map { paragraph in
            let speakerName = speakerNames[paragraph.speakerID] ?? paragraph.speakerID
            return "[\(Timecode.display(paragraph.start))] \(speakerName): \(paragraph.text)"
        }.joined(separator: "\n\n")
    }

    static func markdown(subject: String, date: Date, segments: [TranscriptSegment]) -> String {
        markdown(subject: subject, date: date, segments: segments, speakerNames: [:])
    }

    static func markdown(
        subject: String,
        date: Date,
        segments: [TranscriptSegment],
        speakerNames: [String: String],
    ) -> String {
        let dateText = date.formatted(date: .long, time: .shortened)
        return "# \(subject)\n\n_\(dateText)_\n\n" + paragraphs(segments).map { paragraph in
            let speakerName = speakerNames[paragraph.speakerID] ?? paragraph.speakerID
            return "- **[\(Timecode.display(paragraph.start))] \(speakerName):** \(paragraph.text)"
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
    /// Resolves a generic Copy/Export action without consulting the selected
    /// transcript tab. A present final value wins, followed by a live edit and
    /// then live ASR. A non-nil empty edit is intentional deletion.
    static func fullTranscript(
        finalText: String?,
        liveEdit: String?,
        live: String,
    ) -> String {
        if let finalText {
            return readable(finalText)
        }
        if let liveEdit {
            return readable(liveEdit)
        }
        return readable(live)
    }

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
        interfaceLanguage: ResolvedInterfaceLanguage = .spanish,
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: interfaceLanguage.localeIdentifier)
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        let modeText = switch mode {
        case .online:
            ClassScribeLocalization.text(.modeOnlineMetadata, language: interfaceLanguage)
        case .inPerson:
            ClassScribeLocalization.text(.modeInPersonMetadata, language: interfaceLanguage)
        }
        return """
        \(ClassScribeLocalization.text(.exportSubject, language: interfaceLanguage)): \(subject)
        \(ClassScribeLocalization.text(.exportDate, language: interfaceLanguage)): \(formatter.string(from: date))
        \(ClassScribeLocalization.text(.exportDuration, language: interfaceLanguage)): \(Timecode.display(duration))
        \(ClassScribeLocalization.text(.exportMode, language: interfaceLanguage)): \(modeText)
        \(ClassScribeLocalization.text(.exportSource, language: interfaceLanguage)): \(source)

        \(ClassScribeLocalization.text(.exportTranscript, language: interfaceLanguage)):

        \(transcript)
        """
    }

    private static func resolved(edit: String?, base: String) -> String? {
        edit ?? base
    }

    private static func readable(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
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
