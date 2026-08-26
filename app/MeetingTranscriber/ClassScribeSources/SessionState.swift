import Foundation

/// Stable identity for one start/session attempt. The generation is owned by
/// the application model and is deliberately separate from any capture or ASR
/// implementation UUID. A callback is valid only when the complete value still
/// matches the active attempt.
struct SessionAttemptID: Codable, Equatable, Hashable, Sendable {
    let sessionID: UUID
    let generation: UInt64
    let nonce: UUID

    init(sessionID: UUID = UUID(), generation: UInt64, nonce: UUID = UUID()) {
        self.sessionID = sessionID
        self.generation = generation
        self.nonce = nonce
    }

    var token: String {
        "\(sessionID.uuidString.lowercased()):\(generation):\(nonce.uuidString.lowercased())"
    }
}

/// Small, synchronous ownership gate used by the main-actor model. It is
/// intentionally not a boolean such as `isRecording`: old work remains
/// distinguishable after a new attempt starts.
struct SessionGenerationGate: Sendable {
    private(set) var activeAttempt: SessionAttemptID?
    private var nextGeneration: UInt64 = 0

    mutating func begin(sessionID: UUID = UUID()) -> SessionAttemptID {
        nextGeneration &+= 1
        let attempt = SessionAttemptID(sessionID: sessionID, generation: nextGeneration)
        activeAttempt = attempt
        return attempt
    }

    mutating func invalidate() {
        nextGeneration &+= 1
        activeAttempt = nil
    }

    mutating func invalidate(_ attempt: SessionAttemptID) {
        guard activeAttempt == attempt else { return }
        invalidate()
    }

    func accepts(_ attempt: SessionAttemptID) -> Bool {
        activeAttempt == attempt
    }
}

enum SessionMetadataDecodeError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case unknownToken(field: String, value: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "La versión de metadata \(version) no es compatible con esta versión de ClassScribe."
        case let .unknownToken(field, value):
            "El campo de metadata \(field) contiene un token desconocido: \(value)."
        }
    }
}

/// Persisted domain token. Do not use a localized label as a storage value.
enum CaptureScope: String, Codable, CaseIterable, Sendable {
    case microphone
    case application
    case systemOutput
}

/// Capture and ASR intentionally remain independent concurrent axes.
enum CapturePhase: String, Codable, CaseIterable, Sendable {
    case idle
    case validatingSource
    case connecting
    case waitingForFrames
    case framesSilent
    case audioAudible
    case recording
    case stopping
    case failedRecoverable
    case failedTerminal
}

enum AsrPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case preparingDownload
    case preparingLoad
    case waitingForSpeech
    case transcribing
    case retryScheduled
    case unavailableForSession
    case failedRecoverable
}

enum SessionPhase: String, Codable, CaseIterable, Sendable {
    case draft
    case starting
    case recording
    case stopping
    case processing
    case complete
    case cancelled
    case recoverable
    case failed
}

extension CaptureScope {
    static func fromPersistentToken(_ value: String) -> Self? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "microphone", "inperson", "in_person", "in person", "clase presencial": return .microphone
        case "application", "online", "clase online": return .application
        case "systemoutput", "system_output", "system output": return .systemOutput
        default: return nil
        }
    }
}

extension CaptureMode {
    var captureScope: CaptureScope {
        switch self {
        case .online: .application
        case .inPerson: .microphone
        }
    }

    var persistentToken: String {
        switch self {
        case .online: "online"
        case .inPerson: "inPerson"
        }
    }

    static func fromPersistentToken(_ value: String) -> Self? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "application", "online", "clase online": return .online
        case "microphone", "inperson", "in_person", "in person", "clase presencial": return .inPerson
        case "systemoutput", "system_output", "system output": return .online
        default: return nil
        }
    }
}

extension ProcessingState {
    var persistentToken: String {
        switch self {
        case .ready: "ready"
        case .startingCapture: "startingCapture"
        case .loadingModel: "loadingModel"
        case .recording: "recording"
        case .transcriptionPaused: "transcriptionPaused"
        case .stopping: "stopping"
        case .finalizingAudio: "finalizingAudio"
        case .finalTranscription: "finalTranscription"
        case .diarizing: "diarizing"
        case .complete: "complete"
        case .cancelled: "cancelled"
        case .failed: "failed"
        case .recoverable: "recoverable"
        }
    }

    static func fromPersistentToken(_ value: String) -> Self? {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch token {
        case "ready", "lista": return .ready
        case "startingcapture", "starting", "esperando audio de la fuente": return .startingCapture
        case "loadingmodel", "preparingload", "preparando transcripción": return .loadingModel
        case "recording", "grabando": return .recording
        case "transcriptionpaused", "grabando · transcripción pausada": return .transcriptionPaused
        case "stopping", "guardando transcripción": return .stopping
        case "finalizingaudio", "validando audio": return .finalizingAudio
        case "finaltranscription", "retranscribiendo con máxima calidad": return .finalTranscription
        case "diarizing", "identificando hablantes": return .diarizing
        case "complete", "transcripción final lista": return .complete
        case "cancelled", "canceled", "procesamiento cancelado": return .cancelled
        case "failed", "error": return .failed
        case "recoverable", "sesión recuperable": return .recoverable
        default: return nil
        }
    }

    var sessionPhase: SessionPhase {
        switch self {
        case .ready: .draft
        case .startingCapture, .loadingModel: .starting
        case .recording, .transcriptionPaused: .recording
        case .stopping, .finalizingAudio: .stopping
        case .finalTranscription, .diarizing: .processing
        case .complete: .complete
        case .cancelled: .cancelled
        case .recoverable: .recoverable
        case .failed: .failed
        }
    }

    var defaultCapturePhase: CapturePhase {
        switch self {
        case .ready: .idle
        case .startingCapture: .connecting
        case .loadingModel: .recording
        case .recording, .transcriptionPaused: .recording
        case .stopping, .finalizingAudio: .stopping
        case .finalTranscription, .diarizing, .complete, .cancelled: .idle
        case .recoverable: .failedRecoverable
        case .failed: .failedTerminal
        }
    }

    var defaultAsrPhase: AsrPhase {
        switch self {
        case .ready: .idle
        case .startingCapture: .idle
        case .loadingModel, .finalTranscription: .preparingLoad
        case .recording: .waitingForSpeech
        case .transcriptionPaused: .waitingForSpeech
        case .stopping, .finalizingAudio, .diarizing, .complete, .cancelled: .idle
        case .recoverable: .failedRecoverable
        case .failed: .failedRecoverable
        }
    }
}

extension SessionPhase {
    static func fromPersistentToken(_ value: String) -> Self? {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch token {
        case "draft", "ready", "lista": return .draft
        case "starting", "startingcapture", "esperando audio de la fuente", "preparando transcripción": return .starting
        case "recording", "grabando", "grabando · transcripción pausada": return .recording
        case "stopping", "guardando transcripción", "validando audio": return .stopping
        case "processing", "finaltranscription", "diarizing", "retranscribiendo con máxima calidad", "identificando hablantes": return .processing
        case "complete", "transcripción final lista": return .complete
        case "cancelled", "canceled", "procesamiento cancelado": return .cancelled
        case "recoverable", "sesión recuperable": return .recoverable
        case "failed", "error": return .failed
        default: return nil
        }
    }
}

extension CapturePhase {
    static func fromPersistentToken(_ value: String) -> Self? {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.rawValue.lowercased() == token }
    }
}

extension AsrPhase {
    static func fromPersistentToken(_ value: String) -> Self? {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.rawValue.lowercased() == token }
    }
}

struct AudioFormatMetadata: Codable, Equatable, Sendable {
    var formatVersion: Int = 1
    var master: String?
    var asr: String?
}

struct ASRTranscriptReference: Codable, Equatable, Sendable {
    var runID: UUID
    var relativePath: String
    var language: TranscriptionLanguage
    var attemptID: SessionAttemptID?
}

struct ASRTranscriptArtifact: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var runID: UUID
    var createdAt: Date
    var language: TranscriptionLanguage
    var attemptID: SessionAttemptID?
    var segments: [TranscriptSegment]
}

struct DiarizationProposalReference: Codable, Equatable, Sendable {
    var proposalID: UUID
    var relativePath: String
}

struct DiarizationProposal: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var proposalID: UUID
    var createdAt: Date
    var engineVersion: String?
    var asrRunID: UUID?
    var spans: [DiarizationSpan]
}

struct DiarizationProposalDocument: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var proposals: [DiarizationProposal]
}

enum SpeakerCorrectionKind: String, Codable, Sendable {
    case rename
    case merge
    case reassign
    case professorConfirmation
    case review
}

struct SpeakerCorrectionOperation: Codable, Equatable, Sendable {
    var id: UUID
    var kind: SpeakerCorrectionKind
    var speakerID: String?
    var targetSpeakerID: String?
    var displayName: String?
    var segmentIDs: [UUID]
    var createdAt: Date
}

struct HumanCorrectionOverlay: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var operations: [SpeakerCorrectionOperation] = []
    var editedAllText: String?
    var editedProfessorText: String?
}

struct HumanCorrectionUpdate: Equatable, Sendable {
    var operations: [SpeakerCorrectionOperation] = []
    var allText: String?
    var professorText: String?
}

struct HumanCorrectionOverlayReference: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var relativePath: String
}

struct AudioManifestReference: Codable, Equatable, Sendable {
    var relativePath = "audio-manifest.json"
}

extension ClassMetadata {
    var effectiveTranscriptionLanguage: TranscriptionLanguage {
        language ?? .spanish
    }
}

extension ClassMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case subject
        case startedAt
        case duration
        case mode
        case captureScope
        case source
        case professorSpeakerID
        case professorSelectionIsAutomatic
        case speakerCount
        case state
        case sessionPhase
        case capturePhase
        case asrPhase
        case folderPath
        case technicalVocabulary
        case language
        case transcriptionLanguage
        case audioFormat
        case formatVersion
        case platform
        case sessionAttemptID
        case asrOriginalReference
        case audioManifestReference
        case diarizationProposals
        case humanCorrectionOverlay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decodeToken<T>(
            _ key: CodingKeys,
            field: String,
            parser: (String) -> T?,
        ) throws -> T? {
            guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard let value = parser(raw) else {
                throw SessionMetadataDecodeError.unknownToken(field: field, value: raw)
            }
            return value
        }

        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1 ... 2).contains(decodedSchemaVersion) else {
            throw SessionMetadataDecodeError.unsupportedSchemaVersion(decodedSchemaVersion)
        }
        let decodedState = try decodeToken(
            .state,
            field: "state",
            parser: ProcessingState.fromPersistentToken,
        ) ?? .ready
        let decodedSessionPhase = try decodeToken(
            .sessionPhase,
            field: "sessionPhase",
            parser: SessionPhase.fromPersistentToken,
        ) ?? decodedState.sessionPhase
        let decodedCapturePhase = try decodeToken(
            .capturePhase,
            field: "capturePhase",
            parser: CapturePhase.fromPersistentToken,
        ) ?? decodedState.defaultCapturePhase
        let decodedAsrPhase = try decodeToken(
            .asrPhase,
            field: "asrPhase",
            parser: AsrPhase.fromPersistentToken,
        ) ?? decodedState.defaultAsrPhase
        let scopeToken = try container.decodeIfPresent(String.self, forKey: .captureScope)
        let modeToken = try container.decodeIfPresent(String.self, forKey: .mode)
        let decodedScope: CaptureScope
        let decodedMode: CaptureMode
        if let scopeToken {
            guard let scope = CaptureScope.fromPersistentToken(scopeToken) else {
                throw SessionMetadataDecodeError.unknownToken(field: "captureScope", value: scopeToken)
            }
            decodedScope = scope
            decodedMode = try decodeToken(
                .mode,
                field: "mode",
                parser: CaptureMode.fromPersistentToken,
            ) ?? (scope == .microphone ? .inPerson : .online)
        } else if let modeToken {
            guard let mode = CaptureMode.fromPersistentToken(modeToken) else {
                throw SessionMetadataDecodeError.unknownToken(field: "mode", value: modeToken)
            }
            decodedMode = mode
            decodedScope = mode.captureScope
        } else {
            decodedMode = .inPerson
            decodedScope = .microphone
        }
        let decodedLanguage = try container.decodeIfPresent(TranscriptionLanguage.self, forKey: .transcriptionLanguage)
            ?? (try container.decodeIfPresent(TranscriptionLanguage.self, forKey: .language))
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            subject: try container.decodeIfPresent(String.self, forKey: .subject) ?? "",
            startedAt: try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? .distantPast,
            duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0,
            mode: decodedMode,
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? "",
            professorSpeakerID: try container.decodeIfPresent(String.self, forKey: .professorSpeakerID),
            professorSelectionIsAutomatic: try container.decodeIfPresent(Bool.self, forKey: .professorSelectionIsAutomatic) ?? true,
            speakerCount: try container.decodeIfPresent(Int.self, forKey: .speakerCount) ?? 0,
            state: decodedState,
            folderPath: try container.decodeIfPresent(String.self, forKey: .folderPath) ?? "",
            technicalVocabulary: try container.decodeIfPresent(String.self, forKey: .technicalVocabulary) ?? "",
            language: decodedLanguage,
            schemaVersion: decodedSchemaVersion,
            sessionPhase: decodedSessionPhase,
            capturePhase: decodedCapturePhase,
            asrPhase: decodedAsrPhase,
            captureScope: decodedScope,
            audioFormat: try container.decodeIfPresent(String.self, forKey: .audioFormat) ?? "legacy_unknown",
            formatVersion: try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1,
            platform: try container.decodeIfPresent(String.self, forKey: .platform) ?? "macos",
            attemptID: try container.decodeIfPresent(SessionAttemptID.self, forKey: .sessionAttemptID),
            asrOriginalReference: try container.decodeIfPresent(ASRTranscriptReference.self, forKey: .asrOriginalReference),
            audioManifestReference: try container.decodeIfPresent(AudioManifestReference.self, forKey: .audioManifestReference),
            diarizationProposalReferences: try container.decodeIfPresent([DiarizationProposalReference].self, forKey: .diarizationProposals) ?? [],
            humanCorrectionOverlayReference: try container.decodeIfPresent(HumanCorrectionOverlayReference.self, forKey: .humanCorrectionOverlay),
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let scope = captureScope ?? mode.captureScope
        try container.encode(2, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(subject, forKey: .subject)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(duration, forKey: .duration)
        // Keep the old field names as stable aliases so a future reader can
        // migrate without treating a localized label as a domain token.
        try container.encode(mode.persistentToken, forKey: .mode)
        try container.encode(scope, forKey: .captureScope)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(professorSpeakerID, forKey: .professorSpeakerID)
        try container.encode(professorSelectionIsAutomatic, forKey: .professorSelectionIsAutomatic)
        try container.encode(speakerCount, forKey: .speakerCount)
        try container.encode(state.persistentToken, forKey: .state)
        try container.encode(sessionPhase, forKey: .sessionPhase)
        try container.encode(capturePhase, forKey: .capturePhase)
        try container.encode(asrPhase, forKey: .asrPhase)
        try container.encode(folderPath, forKey: .folderPath)
        try container.encode(technicalVocabulary, forKey: .technicalVocabulary)
        let persistedLanguage = language ?? .spanish
        try container.encode(persistedLanguage, forKey: .transcriptionLanguage)
        try container.encode(persistedLanguage, forKey: .language)
        try container.encode(audioFormat, forKey: .audioFormat)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(platform, forKey: .platform)
        try container.encodeIfPresent(attemptID, forKey: .sessionAttemptID)
        try container.encodeIfPresent(asrOriginalReference, forKey: .asrOriginalReference)
        try container.encodeIfPresent(audioManifestReference, forKey: .audioManifestReference)
        try container.encode(diarizationProposalReferences, forKey: .diarizationProposals)
        try container.encodeIfPresent(humanCorrectionOverlayReference, forKey: .humanCorrectionOverlay)
    }
}
