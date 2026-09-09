import Darwin
import Foundation

enum SessionTextSource: Equatable {
    case professor
    case everyone
    case recovered
    case live
    case none
}

struct SessionSummary: Identifiable, Equatable {
    let id: String
    let folder: URL
    let metadata: ClassMetadata
    let isRecoverable: Bool
    let hasAudio: Bool
    let audioIsValid: Bool
    let hasRecoverableRawAudio: Bool
    let preferredTextURL: URL?
    let textSource: SessionTextSource
    let recoveryReason: String?

    var subject: String {
        metadata.subject
    }

    var startedAt: Date {
        metadata.startedAt
    }

    var duration: TimeInterval {
        metadata.duration
    }

    var mode: CaptureMode {
        metadata.mode
    }

    var source: String {
        metadata.source
    }

    var professorSpeakerID: String? {
        metadata.professorSpeakerID
    }

    var speakerCount: Int {
        metadata.speakerCount
    }

    var state: ProcessingState {
        isRecoverable ? .recoverable : metadata.state
    }

    var canRetryProcessing: Bool {
        isRecoverable && ((hasAudio && audioIsValid) || hasRecoverableRawAudio)
    }
}

struct RestoredSession {
    var summary: SessionSummary
    var metadata: ClassMetadata
    var liveAccumulator: LiveTranscriptAccumulator
    var allSegments: [TranscriptSegment]
    var speakers: [SpeakerRecord]
    var review: [ReviewItem]
    var preferredText: String
    var preferredTextSource: SessionTextSource
    var editedLiveText: String?
    var editedAllText: String?
    var editedProfessorText: String?
    var humanCorrectionOverlay: HumanCorrectionOverlay?
}

struct LiveTranscriptContext: Codable, Equatable {
    var subject: String
    var startedAt: Date
    var mode: CaptureMode
    var source: String
    var duration: TimeInterval
}

struct LiveTranscriptSnapshot: Codable, Equatable {
    var version = 2
    var accumulator: LiveTranscriptAccumulator
    var stable: String
    var provisional: String
    var updatedAt: Date

    init(accumulator: LiveTranscriptAccumulator, updatedAt: Date = Date()) {
        self.accumulator = accumulator
        stable = accumulator.stableText
        provisional = accumulator.provisionalText
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, accumulator, stable, provisional, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        stable = try container.decodeIfPresent(String.self, forKey: .stable) ?? ""
        provisional = try container.decodeIfPresent(String.self, forKey: .provisional) ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        accumulator = try container.decodeIfPresent(LiveTranscriptAccumulator.self, forKey: .accumulator)
            ?? LiveTranscriptAccumulator(legacyStable: stable, provisional: provisional)
    }
}

private struct LiveTranscriptJournalEntry: Codable {
    var id = UUID()
    var checkpoint: String
    var snapshot: LiveTranscriptSnapshot
}

/// Records the presence of a human-owned live edit independently from its
/// contents. An empty string is meaningful: the person deliberately cleared
/// the editor and the automatic transcript must not silently replace it.
private struct LiveTranscriptEditOverride: Codable {
    var version = 1
    var text: String
}

struct SessionStore {
    private static let maximumMetadataBytes: UInt64 = 1 * 1_024 * 1_024
    private static let maximumStructuredBytes: UInt64 = 64 * 1_024 * 1_024
    private static let maximumTextBytes: UInt64 = 64 * 1_024 * 1_024
    private static let maximumJournalBytes: UInt64 = 16 * 1_024 * 1_024
    let root: URL
    private let encoder: JSONEncoder
    private let journalEncoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClassScribe/Classes", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        journalEncoder = JSONEncoder()
        journalEncoder.outputFormatting = [.sortedKeys]
        journalEncoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func createFolder(subject: String, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let slug = subject.filenameSlug.isEmpty ? "Clase" : subject.filenameSlug
        let baseName = "\(formatter.string(from: date))_\(slug)"
        for suffix in 1 ... 10_000 {
            let name = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
            let folder = root.appendingPathComponent(name, isDirectory: true)
            if mkdir(folder.path, 0o700) == 0 {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
                return folder
            }
            if errno != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        throw SessionStoreError.cannotReserveUniqueFolder
    }

    func saveLive(
        accumulator: LiveTranscriptAccumulator,
        context: LiveTranscriptContext,
        folder: URL,
        checkpoint: String,
        visibleTextOverride: String? = nil,
    ) throws {
        let snapshot = LiveTranscriptSnapshot(accumulator: accumulator)
        try appendJournal(
            LiveTranscriptJournalEntry(checkpoint: checkpoint, snapshot: snapshot),
            to: folder.appendingPathComponent("live-transcript-journal.jsonl"),
        )
        try writeJSON(snapshot, to: folder.appendingPathComponent("live-transcript.json"))
        let readableText = visibleTextOverride ?? snapshot.accumulator.visibleText
        try saveReadableLiveText(
            text: readableText,
            context: context,
            folder: folder,
            recordsEditOverride: visibleTextOverride != nil,
        )
    }

    func loadLive(folder: URL) -> LiveTranscriptAccumulator? {
        let url = folder.appendingPathComponent("live-transcript.json")
        if let data = readRegularData(url, maximumBytes: Self.maximumStructuredBytes),
           let snapshot = try? decoder.decode(LiveTranscriptSnapshot.self, from: data) {
            return snapshot.accumulator
        }
        let journalURL = folder.appendingPathComponent("live-transcript-journal.jsonl")
        guard let data = readRegularData(journalURL, maximumBytes: Self.maximumJournalBytes) else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            if let entry = try? decoder.decode(LiveTranscriptJournalEntry.self, from: Data(line)) {
                return entry.snapshot.accumulator
            }
        }
        return nil
    }

    func saveFinal(
        metadata: ClassMetadata,
        all: [TranscriptSegment],
        professor: [TranscriptSegment],
        review: [ReviewItem],
        speakers: [SpeakerRecord],
        folder: URL,
        humanCorrection: HumanCorrectionUpdate? = nil,
        diarizationProposal: DiarizationProposal? = nil,
    ) throws {
        try saveProjection(
            metadata: metadata,
            all: all,
            professor: professor,
            review: review,
            speakers: speakers,
            folder: folder,
            automaticAllText: nil,
            automaticProfessorText: nil,
            humanCorrection: humanCorrection,
            diarizationProposal: diarizationProposal,
        )
    }

    func saveAutomaticProjection(
        metadata: ClassMetadata,
        all: [TranscriptSegment],
        professor: [TranscriptSegment],
        review: [ReviewItem],
        speakers: [SpeakerRecord],
        folder: URL,
        automaticAllText: String,
        automaticProfessorText: String,
        diarizationProposal: DiarizationProposal? = nil,
    ) throws {
        try saveProjection(
            metadata: metadata,
            all: all,
            professor: professor,
            review: review,
            speakers: speakers,
            folder: folder,
            automaticAllText: automaticAllText,
            automaticProfessorText: automaticProfessorText,
            humanCorrection: nil,
            diarizationProposal: diarizationProposal,
        )
    }

    private func saveProjection(
        metadata: ClassMetadata,
        all: [TranscriptSegment],
        professor: [TranscriptSegment],
        review: [ReviewItem],
        speakers: [SpeakerRecord],
        folder: URL,
        automaticAllText: String?,
        automaticProfessorText: String?,
        humanCorrection: HumanCorrectionUpdate?,
        diarizationProposal: DiarizationProposal?,
    ) throws {
        var overlay = loadCorrectionOverlay(in: folder)
        if let humanCorrection {
            var humanOverlay = overlay ?? HumanCorrectionOverlay()
            humanOverlay.operations.append(contentsOf: humanCorrection.operations.filter { operation in
                !humanOverlay.operations.contains(where: { $0.id == operation.id })
            })
            if humanCorrection.clearAllText {
                humanOverlay.editedAllText = nil
            } else if let allText = humanCorrection.allText {
                humanOverlay.editedAllText = allText
            }
            if humanCorrection.clearProfessorText {
                humanOverlay.editedProfessorText = nil
            } else if let professorText = humanCorrection.professorText {
                humanOverlay.editedProfessorText = professorText
            }
            try writeJSON(humanOverlay, to: folder.appendingPathComponent("human-correction-overlay.json"))
            overlay = humanOverlay
        }

        var proposalDocument = loadDiarizationProposalDocument(in: folder)
            ?? DiarizationProposalDocument(proposals: [])
        if let diarizationProposal,
           !proposalDocument.proposals.contains(where: { $0.proposalID == diarizationProposal.proposalID }) {
            proposalDocument.proposals.append(diarizationProposal)
        }
        var metadataToSave = metadata
        if overlay != nil {
            metadataToSave.humanCorrectionOverlayReference = metadataToSave.humanCorrectionOverlayReference
                ?? HumanCorrectionOverlayReference(relativePath: "human-correction-overlay.json")
        }
        if let diarizationProposal {
            let reference = DiarizationProposalReference(
                proposalID: diarizationProposal.proposalID,
                relativePath: "diarization-proposals.json",
            )
            if !metadataToSave.diarizationProposalReferences.contains(where: { $0.proposalID == reference.proposalID }) {
                metadataToSave.diarizationProposalReferences.append(reference)
            }
        }
        for proposal in proposalDocument.proposals {
            if !metadataToSave.diarizationProposalReferences.contains(where: { $0.proposalID == proposal.proposalID }) {
                metadataToSave.diarizationProposalReferences.append(
                    DiarizationProposalReference(
                        proposalID: proposal.proposalID,
                        relativePath: "diarization-proposals.json",
                    ),
                )
            }
        }
        try writeJSON(proposalDocument, to: folder.appendingPathComponent("diarization-proposals.json"))
        try writeJSON(all, to: folder.appendingPathComponent("all-speakers.json"))
        try writeJSON(review, to: folder.appendingPathComponent("review.json"))
        try writeJSON(speakers, to: folder.appendingPathComponent("speakers.json"))
        let speakerNames = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        let readableAll = overlay?.editedAllText
            ?? automaticAllText
            ?? TranscriptExporter.plainText(all, speakerNames: speakerNames)
        let readableProfessor = overlay?.editedProfessorText
            ?? automaticProfessorText
            ?? TranscriptExporter.plainText(professor, speakerNames: speakerNames)
        try writeText(readableAll, to: folder.appendingPathComponent("all-speakers.txt"))
        try writeText(
            TranscriptExporter.markdown(subject: metadata.subject, date: metadata.startedAt, text: readableAll),
            to: folder.appendingPathComponent("all-speakers.md"),
        )
        try writeText(readableProfessor, to: folder.appendingPathComponent("professor.txt"))
        try writeText(
            TranscriptExporter.markdown(subject: metadata.subject, date: metadata.startedAt, text: readableProfessor),
            to: folder.appendingPathComponent("professor.md"),
        )
        try writeText(TranscriptExporter.srt(professor), to: folder.appendingPathComponent("professor.srt"))
        // Commit the successful state last. If any output above fails or the
        // process is interrupted, the prior metadata remains non-complete and
        // the scanner truthfully offers recovery/retry on the next launch.
        try writeJSON(metadataToSave, to: folder.appendingPathComponent("metadata.json"))
    }

    func saveMetadata(_ metadata: ClassMetadata, folder: URL) throws {
        try writeJSON(metadata, to: folder.appendingPathComponent("metadata.json"))
    }

    @discardableResult
    func saveFullTranscript(metadata: ClassMetadata, segments: [TranscriptSegment], folder: URL) throws -> ASRTranscriptReference {
        guard !segments.isEmpty else { throw SessionStoreError.emptyTranscript }
        let reference = try saveASROriginal(metadata: metadata, segments: segments, folder: folder)
        var metadataWithReference = metadata
        metadataWithReference.asrOriginalReference = reference
        if loadCorrectionOverlay(in: folder) != nil {
            metadataWithReference.humanCorrectionOverlayReference = metadataWithReference.humanCorrectionOverlayReference
                ?? HumanCorrectionOverlayReference(relativePath: "human-correction-overlay.json")
        }
        if let proposalDocument = loadDiarizationProposalDocument(in: folder) {
            for proposal in proposalDocument.proposals {
                if !metadataWithReference.diarizationProposalReferences.contains(where: { $0.proposalID == proposal.proposalID }) {
                    metadataWithReference.diarizationProposalReferences.append(
                        DiarizationProposalReference(
                            proposalID: proposal.proposalID,
                            relativePath: "diarization-proposals.json",
                        ),
                    )
                }
            }
        }
        try writeJSON(metadataWithReference, to: folder.appendingPathComponent("metadata.json"))
        try writeJSON(segments, to: folder.appendingPathComponent("all-speakers.json"))
        let overlay = loadCorrectionOverlay(in: folder)
        try writeText(
            overlay?.editedAllText ?? TranscriptExporter.plainText(segments),
            to: folder.appendingPathComponent("all-speakers.txt"),
        )
        try writeText(
            TranscriptExporter.markdown(
                subject: metadata.subject,
                date: metadata.startedAt,
                text: overlay?.editedAllText ?? TranscriptExporter.plainText(segments),
            ),
            to: folder.appendingPathComponent("all-speakers.md"),
        )
        return reference
    }

    func saveReadableLiveText(
        text: String,
        context: LiveTranscriptContext,
        folder: URL,
        recordsEditOverride: Bool = false,
    ) throws {
        if recordsEditOverride {
            try writeJSON(
                LiveTranscriptEditOverride(text: text),
                to: folder.appendingPathComponent("live-transcript-edit.json"),
            )
        }
        try writeText(liveText(text, context: context), to: folder.appendingPathComponent("live-transcript.txt"))
        try writeText(liveMarkdown(text, context: context), to: folder.appendingPathComponent("live-transcript.md"))
    }

    func materializeLegacyLiveText(
        accumulator: LiveTranscriptAccumulator,
        context: LiveTranscriptContext,
        folder: URL,
    ) throws {
        try saveReadableLiveText(text: accumulator.visibleText, context: context, folder: folder)
    }

    func saveTextOverrides(
        metadata: ClassMetadata,
        allText: String?,
        professorText: String?,
        folder: URL,
    ) throws {
        var overlay = loadCorrectionOverlay(in: folder) ?? HumanCorrectionOverlay()
        if let allText {
            overlay.editedAllText = allText
        }
        if let professorText {
            overlay.editedProfessorText = professorText
        }
        try writeJSON(overlay, to: folder.appendingPathComponent("human-correction-overlay.json"))
        if let allText {
            try writeText(allText, to: folder.appendingPathComponent("all-speakers.txt"))
            try writeText(
                TranscriptExporter.markdown(subject: metadata.subject, date: metadata.startedAt, text: allText),
                to: folder.appendingPathComponent("all-speakers.md"),
            )
        }
        if let professorText {
            try writeText(professorText, to: folder.appendingPathComponent("professor.txt"))
            try writeText(
                TranscriptExporter.markdown(subject: metadata.subject, date: metadata.startedAt, text: professorText),
                to: folder.appendingPathComponent("professor.md"),
            )
        }
        var metadataToSave = metadata
        metadataToSave.humanCorrectionOverlayReference = metadataToSave.humanCorrectionOverlayReference
            ?? HumanCorrectionOverlayReference(relativePath: "human-correction-overlay.json")
        try writeJSON(metadataToSave, to: folder.appendingPathComponent("metadata.json"))
    }

    func saveVoiceReference(_ reference: ProfessorVoiceReference, folder: URL) throws {
        try writeJSON(reference, to: folder.appendingPathComponent("professor-voice-reference.json"))
        let voices = root.deletingLastPathComponent().appendingPathComponent("ProfessorVoices", isDirectory: true)
        try FileManager.default.createDirectory(
            at: voices,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: voices.path)
        let name = reference.subject.filenameSlug.isEmpty ? "Profesor" : reference.subject.filenameSlug
        try writeJSON(reference, to: voices.appendingPathComponent("\(name).json"))
    }

    func loadVoiceReference(subject: String) -> ProfessorVoiceReference? {
        let name = subject.filenameSlug.isEmpty ? "Profesor" : subject.filenameSlug
        let url = root.deletingLastPathComponent().appendingPathComponent("ProfessorVoices/\(name).json")
        guard let data = readRegularData(url, maximumBytes: Self.maximumStructuredBytes) else { return nil }
        return try? decoder.decode(ProfessorVoiceReference.self, from: data)
    }

    func scanSessions(materializeLegacyText: Bool = false) -> [SessionSummary] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
        ) else { return [] }
        return folders.compactMap { folder in
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
            return inspectSession(folder: folder, materializeLegacyText: materializeLegacyText)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func history() -> [SessionSummary] {
        scanSessions(materializeLegacyText: false)
    }

    func restore(_ summary: SessionSummary) -> RestoredSession {
        let folder = summary.folder.standardizedFileURL
        let allSegments: [TranscriptSegment] = decodeFile("all-speakers.json", in: folder) ?? []
        let speakers: [SpeakerRecord] = decodeFile("speakers.json", in: folder) ?? []
        let review: [ReviewItem] = decodeFile("review.json", in: folder) ?? []
        let overlay: HumanCorrectionOverlay? = decodeFile("human-correction-overlay.json", in: folder)
        let accumulator = loadLive(folder: folder) ?? LiveTranscriptAccumulator()
        let speakerNames = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        let allBase = TranscriptExporter.plainText(allSegments, speakerNames: speakerNames)
        let professorSegments = SpeakerAssignment.professorSegments(
            from: allSegments,
            professorID: summary.metadata.professorSpeakerID,
            review: review,
        )
        let professorBase = TranscriptExporter.plainText(professorSegments, speakerNames: speakerNames)
        let allReadable = readNonemptyText(folder.appendingPathComponent("all-speakers.txt"))
        let professorReadable = readNonemptyText(folder.appendingPathComponent("professor.txt"))
        let preferred = preferredText(in: folder, accumulator: accumulator)
        let liveBody = readLiveTranscript(folder.appendingPathComponent("live-transcript.txt"))
        let explicitLiveEdit: LiveTranscriptEditOverride? = decodeFile(
            "live-transcript-edit.json",
            in: folder,
        )

        return RestoredSession(
            summary: summary,
            metadata: summary.metadata,
            liveAccumulator: accumulator,
            allSegments: allSegments,
            speakers: speakers,
            review: review,
            preferredText: preferred.text,
            preferredTextSource: preferred.source,
            editedLiveText: explicitLiveEdit?.text
                ?? liveBody.flatMap { $0 == accumulator.visibleText ? nil : $0 },
            editedAllText: overlay?.editedAllText ?? allReadable.flatMap { $0 == allBase ? nil : $0 },
            editedProfessorText: overlay?.editedProfessorText
                ?? professorReadable.flatMap { $0 == professorBase ? nil : $0 },
            humanCorrectionOverlay: overlay,
        )
    }

    private func inspectSession(folder: URL, materializeLegacyText: Bool) -> SessionSummary? {
        let fileManager = FileManager.default
        let metadataURL = folder.appendingPathComponent("metadata.json")
        let metadataData = readRegularData(metadataURL, maximumBytes: Self.maximumMetadataBytes)
        let decodedMetadata: ClassMetadata?
        var metadataWasCorrupt = false
        if let metadataData {
            do {
                guard let object = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any] else {
                    // Valid JSON with a non-object root is not metadata and
                    // must not be reinterpreted as a legacy session.
                    return nil
                }
                if let schemaValue = object["schemaVersion"] {
                    guard let schemaVersion = schemaValue as? Int else { return nil }
                    if schemaVersion > 2 {
                        // A future schema is unsupported, not a legacy
                        // document to reinterpret and later downgrade.
                        return nil
                    }
                }
                guard let decoded = try? decoder.decode(ClassMetadata.self, from: metadataData) else {
                    // Syntax-valid metadata with an explicit unknown token is
                    // unsupported; it must not receive inferred defaults.
                    return nil
                }
                decodedMetadata = decoded
            } catch {
                // v0.7 could leave metadata partially written. Recover from
                // the surviving artifacts without rewriting this file.
                metadataWasCorrupt = true
                decodedMetadata = nil
            }
        } else {
            decodedMetadata = nil
        }
        let audioURL = folder.appendingPathComponent("source.wav")
        let hasAudio = fileManager.fileExists(atPath: audioURL.path)
        let audioDuration = hasAudio ? try? WavFile.validate(audioURL) : nil
        let audioIsValid = audioDuration != nil
        let rawURL = folder.appendingPathComponent("source.raw")
        let masterURL = folder.appendingPathComponent("master.raw")
        let manifestURL = folder.appendingPathComponent("audio-manifest.json")
        let masterDuration = (try? WavFile.validateMaster(masterURL, manifestURL: manifestURL))
        let hasRecoverableMasterAudio = masterDuration != nil
        let hasRecoverableLegacyAudio = (try? WavFile.validateFloat32Raw(rawURL)) != nil
        let hasRecoverableRawAudio = hasRecoverableMasterAudio || hasRecoverableLegacyAudio
        var metadata = decodedMetadata ?? inferredMetadata(for: folder, duration: audioDuration ?? masterDuration ?? 0)
        metadata.folderPath = folder.standardizedFileURL.path
        if let durableDuration = audioDuration ?? masterDuration, durableDuration > metadata.duration {
            metadata.duration = durableDuration
        }

        let accumulator = loadLive(folder: folder)
        let hasLegacyText = !(accumulator?.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let knownNames = [
            "live-transcript.txt", "live-transcript.json", "live-transcript-journal.jsonl",
            "live-transcript-edit.json", "recovered-transcript.txt", "all-speakers.txt",
            "all-speakers.json", "professor.txt", "source.raw", "master.raw", "audio-manifest.json",
            "asr-original.json", "diarization-proposals.json", "human-correction-overlay.json",
        ]
        let hasASROriginal = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
        ))?.contains { $0.lastPathComponent.hasPrefix("asr-original-") } == true
        let hasKnownContent = hasAudio || hasRecoverableMasterAudio || metadataData != nil || hasASROriginal || knownNames.contains {
            fileManager.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        guard hasKnownContent else { return nil }

        let liveURL = folder.appendingPathComponent("live-transcript.txt")
        if materializeLegacyText,
           !fileManager.fileExists(atPath: liveURL.path),
           hasLegacyText,
           let accumulator {
            let context = LiveTranscriptContext(
                subject: metadata.subject,
                startedAt: metadata.startedAt,
                mode: metadata.mode,
                source: metadata.source,
                duration: metadata.duration,
            )
            try? materializeLegacyLiveText(accumulator: accumulator, context: context, folder: folder)
        }

        let preferred = preferredText(in: folder, accumulator: accumulator ?? LiveTranscriptAccumulator())
        let allSegments: [TranscriptSegment] = decodeFile("all-speakers.json", in: folder) ?? []
        let hasFullTranscript = readNonemptyText(folder.appendingPathComponent("all-speakers.txt")) != nil
            || !allSegments.isEmpty
        let missingMetadata = decodedMetadata == nil
        let incompleteState = metadata.state != .complete
        let missingAudio = !hasAudio
        let invalidAudio = hasAudio && !audioIsValid
        let needsAudioRecovery = !audioIsValid && hasRecoverableRawAudio
        let missingFinal = !hasFullTranscript
        let isRecoverable = metadataWasCorrupt
            || missingMetadata
            || incompleteState
            || missingAudio
            || invalidAudio
            || needsAudioRecovery
            || missingFinal
        let reason: String? = if needsAudioRecovery && hasRecoverableMasterAudio {
            "El WAV derivado falta o está incompleto, pero el master fiel puede reconstruirse."
        } else if needsAudioRecovery {
            "El WAV quedó incompleto, pero el audio crudo se conservó y puede recuperarse."
        } else if invalidAudio {
            "El audio no es válido; el texto disponible se conserva."
        } else if metadataWasCorrupt {
            "La metadata quedó truncada o corrupta; el audio y el texto disponibles se conservaron."
        } else if missingMetadata {
            "Faltaba metadata; la sesión se reconstruyó desde sus archivos."
        } else if missingFinal {
            "El procesamiento final quedó incompleto."
        } else if incompleteState {
            "La sesión terminó en estado \(metadata.state.rawValue.lowercased())."
        } else if missingAudio {
            "Falta el WAV original; el texto disponible se conserva."
        } else {
            nil
        }

        return SessionSummary(
            id: folder.standardizedFileURL.path,
            folder: folder.standardizedFileURL,
            metadata: metadata,
            isRecoverable: isRecoverable,
            hasAudio: hasAudio,
            audioIsValid: audioIsValid,
            hasRecoverableRawAudio: hasRecoverableRawAudio,
            preferredTextURL: preferred.url,
            textSource: preferred.source,
            recoveryReason: reason,
        )
    }

    private func preferredText(
        in folder: URL,
        accumulator: LiveTranscriptAccumulator,
    ) -> (text: String, source: SessionTextSource, url: URL?) {
        let professorURL = folder.appendingPathComponent("professor.txt")
        if let text = readNonemptyText(professorURL) {
            return (text, .professor, professorURL)
        }
        let everyoneURL = folder.appendingPathComponent("all-speakers.txt")
        if let text = readNonemptyText(everyoneURL) {
            return (text, .everyone, everyoneURL)
        }
        let recoveredURL = folder.appendingPathComponent("recovered-transcript.txt")
        if let text = readNonemptyText(recoveredURL) {
            return (text, .recovered, recoveredURL)
        }
        let liveURL = folder.appendingPathComponent("live-transcript.txt")
        if let text = readLiveTranscript(liveURL), !text.isEmpty {
            return (text, .live, liveURL)
        }
        let allSegments: [TranscriptSegment] = decodeFile("all-speakers.json", in: folder) ?? []
        let reconstructed = TranscriptExporter.plainText(allSegments)
        if !reconstructed.isEmpty {
            return (reconstructed, .everyone, nil)
        }
        if !accumulator.visibleText.isEmpty {
            return (accumulator.visibleText, .live, nil)
        }
        return ("", .none, nil)
    }

    private func readNonemptyText(_ url: URL) -> String? {
        guard let data = readRegularData(url, maximumBytes: Self.maximumTextBytes),
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readLiveTranscript(_ url: URL) -> String? {
        guard let raw = readNonemptyText(url) else { return nil }
        guard let marker = raw.range(of: "Transcripción:") else { return raw }
        let body = raw[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private func decodeFile<T: Decodable>(_ name: String, in folder: URL) -> T? {
        let url = folder.appendingPathComponent(name)
        guard let data = readRegularData(url, maximumBytes: Self.maximumStructuredBytes) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func loadCorrectionOverlay(in folder: URL) -> HumanCorrectionOverlay? {
        decodeFile("human-correction-overlay.json", in: folder)
    }

    private func loadDiarizationProposalDocument(in folder: URL) -> DiarizationProposalDocument? {
        decodeFile("diarization-proposals.json", in: folder)
    }

    private func saveASROriginal(
        metadata: ClassMetadata,
        segments: [TranscriptSegment],
        folder: URL,
    ) throws -> ASRTranscriptReference {
        let runID = UUID()
        let relativePath = "asr-original-\(runID.uuidString.lowercased()).json"
        let reference = ASRTranscriptReference(
            runID: runID,
            relativePath: relativePath,
            language: metadata.effectiveTranscriptionLanguage,
            attemptID: metadata.attemptID,
        )
        let artifact = ASRTranscriptArtifact(
            runID: runID,
            createdAt: Date(),
            language: metadata.effectiveTranscriptionLanguage,
            attemptID: metadata.attemptID,
            segments: segments,
        )
        try writeJSON(artifact, to: folder.appendingPathComponent(relativePath))
        return reference
    }

    private func readRegularData(_ url: URL, maximumBytes: UInt64) -> Data? {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              UInt64(status.st_size) <= maximumBytes
        else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func inferredMetadata(for folder: URL, duration: TimeInterval) -> ClassMetadata {
        let name = folder.lastPathComponent
        let prefix = String(name.prefix(17))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let date = formatter.date(from: prefix) ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        let subjectStart = name.index(name.startIndex, offsetBy: min(18, name.count))
        let inferredSubject = String(name[subjectStart...]).replacingOccurrences(of: "-", with: " ")
        return ClassMetadata(
            id: stableUUID(for: folder.standardizedFileURL.path),
            subject: inferredSubject.isEmpty ? "Clase recuperada" : inferredSubject.capitalized,
            startedAt: date,
            duration: duration,
            mode: .inPerson,
            source: "Fuente no registrada",
            professorSpeakerID: nil,
            professorSelectionIsAutomatic: true,
            speakerCount: 0,
            state: .recoverable,
            folderPath: folder.standardizedFileURL.path,
            technicalVocabulary: "",
        )
    }

    private func stableUUID(for value: String) -> UUID {
        var first: UInt64 = 14_695_981_039_346_656_037
        var second: UInt64 = 10_995_116_282_111
        for byte in value.utf8 {
            first = (first ^ UInt64(byte)) &* 1_099_511_628_211
            second = (second &* 1_099_511_628_211) ^ UInt64(byte)
        }
        let hex = String(format: "%016llx%016llx", first, second)
        let parts = [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12)),
        ]
        return UUID(uuidString: parts.joined(separator: "-")) ?? UUID()
    }

    private func writeJSON(_ value: some Encodable, to url: URL) throws {
        let data = try encoder.encode(value)
        try writePrivateData(data, to: url)
    }

    private func appendJournal(_ value: some Encodable, to url: URL) throws {
        var data = try journalEncoder.encode(value)
        data.append(0x0A)
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let currentSize = UInt64(max(0, status.st_size))
            if currentSize + UInt64(data.count) > Self.maximumJournalBytes {
                // live-transcript.json is the authoritative atomic snapshot.
                // Keep a fresh fallback entry without quadratic journal growth.
                try writePrivateData(data, to: url)
                return
            }
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeText(_ value: String, to url: URL) throws {
        try writePrivateData(Data(value.utf8), to: url)
    }

    private func writePrivateData(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".classscribe-write-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600],
        ) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            let result = temporary.path.withCString { source in
                destination.path.withCString { target in Darwin.rename(source, target) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func liveText(_ transcript: String, context: LiveTranscriptContext) -> String {
        """
        Materia: \(context.subject)
        Fecha: \(context.startedAt.formatted(date: .long, time: .shortened))
        Modo: \(context.mode.rawValue)
        Fuente: \(context.source)
        Duración provisional: \(Timecode.display(context.duration))

        Transcripción:

        \(transcript)
        """ + "\n"
    }

    private func liveMarkdown(_ transcript: String, context: LiveTranscriptContext) -> String {
        """
        # \(context.subject)

        - Fecha: \(context.startedAt.formatted(date: .long, time: .shortened))
        - Modo: \(context.mode.rawValue)
        - Fuente: \(context.source)
        - Duración provisional: \(Timecode.display(context.duration))

        ## Transcripción

        \(transcript)
        """ + "\n"
    }
}

enum SessionStoreError: LocalizedError {
    case emptyTranscript
    case cannotReserveUniqueFolder

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "La transcripción final no produjo texto; se conserva la versión en vivo."
        case .cannotReserveUniqueFolder:
            "No se pudo reservar una carpeta única para esta clase."
        }
    }
}
