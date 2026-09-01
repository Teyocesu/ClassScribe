import Foundation

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case online = "Clase online"
    case inPerson = "Clase presencial"

    var id: String { rawValue }
}

/// Online capture has two explicit sources while the durable capture mode
/// remains only `online` or `inPerson`.
enum OnlineCaptureSource: CaseIterable, Hashable, Identifiable, Sendable {
    case application
    case systemOutput

    var id: Self { self }

    var displayName: String {
        switch self {
        case .application: "Una aplicación"
        case .systemOutput: "Audio del equipo"
        }
    }
}

enum CaptureRecoverySuggestion: Equatable, Sendable {
    case systemOutput
}

enum CaptureTerminalFailureCategory: Equatable, Sendable {
    case source
    case durableMaster
    case storage
    case finalization
}

struct CaptureTerminalFailure: Equatable, Sendable {
    var message: String
    var category: CaptureTerminalFailureCategory
    var recoverySuggestion: CaptureRecoverySuggestion?

    init(
        message: String,
        category: CaptureTerminalFailureCategory = .source,
        recoverySuggestion: CaptureRecoverySuggestion? = nil,
    ) {
        self.message = message
        self.category = category
        self.recoverySuggestion = recoverySuggestion
    }
}

enum CaptureRecoveryPolicy {
    static func suggestion(
        for category: CaptureTerminalFailureCategory,
        scope: CaptureScope?,
    ) -> CaptureRecoverySuggestion? {
        guard category == .source, scope == .application else { return nil }
        return .systemOutput
    }
}

enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case spanish = "es"
    case english = "en"
    case french = "fr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spanish: "Español"
        case .english: "English"
        case .french: "Français"
        }
    }
}

enum ProcessingState: String, Codable {
    case ready = "Lista"
    case startingCapture = "Esperando audio de la fuente"
    case loadingModel = "Preparando transcripción"
    case recording = "Grabando"
    case transcriptionPaused = "Grabando · transcripción pausada"
    case stopping = "Guardando transcripción"
    case finalizingAudio = "Validando audio"
    case finalTranscription = "Retranscribiendo con máxima calidad"
    case diarizing = "Identificando hablantes"
    case complete = "Transcripción final lista"
    case cancelled = "Procesamiento cancelado"
    case failed = "Error"
    case recoverable = "Sesión recuperable"
}

struct RunningApplication: Identifiable, Hashable {
    let identity: ApplicationIdentity
    let name: String
    let processID: pid_t

    /// UI row identity for one observed process incarnation. This is never
    /// used as the selected application's logical identity.
    var id: String { "\(logicalIdentityID)|pid:\(processID)" }
    var logicalIdentityID: String { identity.stableKey }
    var bundleIdentifier: String { identity.bundleIdentifier ?? "" }
    var bundleURL: URL? { identity.bundleURL }
    var executableURL: URL? { identity.executableURL }

    init(
        identity: ApplicationIdentity,
        name: String,
        processID: pid_t,
    ) {
        self.identity = identity
        self.name = name
        self.processID = processID
    }

    /// Compatibility initializer for existing physical fixtures. The PID is
    /// retained only as the observed incarnation; the logical identity is
    /// derived from the supplied identity fields.
    init(
        id: pid_t,
        name: String,
        bundleIdentifier: String,
        bundleURL: URL?,
    ) {
        self.init(
            identity: ApplicationIdentity(
                bundleIdentifier: bundleIdentifier,
                bundleURL: bundleURL,
            ),
            name: name,
            processID: id,
        )
    }
}

struct MicrophoneOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Word-level timing already produced by Parakeet. It is optional on the
/// persisted segment so sessions written before this field remain readable.
struct TranscriptWordTiming: Codable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    static func renderedText(_ words: [TranscriptWordTiming]) -> String {
        words.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " !", with: "!")
    }
}

struct TranscriptSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var speakerID: String
    var confidence: Double
    var provisional: Bool = false
    var overlappingVoices: Bool = false
    var wordTimings: [TranscriptWordTiming]? = nil

    var formattedTimestamp: String { Timecode.display(start) }
}

struct DiarizationSpan: Codable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var speakerID: String
    var quality: Double
}

struct SpeakerRecord: Identifiable, Codable, Equatable {
    var id: String
    var displayName: String
    var totalSpeakingTime: TimeInterval
    var recentFragments: [String]
    var confidence: Double
    var embedding: [Float]?
}

struct ReviewItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var segment: TranscriptSegment
    var reason: String
    var manuallyAssignedToProfessor = false
}

struct ProfessorVoiceReference: Codable, Equatable {
    var subject: String
    var createdAt: Date
    var sourceSpeakerID: String
    var embedding: [Float]
}

struct ClassMetadata: Identifiable, Equatable {
    var id: UUID
    var subject: String
    var startedAt: Date
    var duration: TimeInterval
    var mode: CaptureMode
    var source: String
    var professorSpeakerID: String?
    var professorSelectionIsAutomatic: Bool
    var speakerCount: Int
    var state: ProcessingState
    var folderPath: String
    var technicalVocabulary: String
    /// Optional keeps metadata from versions before multilingual support decodable.
    var language: TranscriptionLanguage? = nil
    var schemaVersion: Int = 2
    var sessionPhase: SessionPhase = .draft
    var capturePhase: CapturePhase = .idle
    var asrPhase: AsrPhase = .idle
    var captureScope: CaptureScope? = nil
    var audioFormat: String = "legacy_unknown"
    var formatVersion: Int = 1
    var platform: String = "macos"
    var attemptID: SessionAttemptID? = nil
    var asrOriginalReference: ASRTranscriptReference? = nil
    var audioManifestReference: AudioManifestReference? = nil
    var diarizationProposalReferences: [DiarizationProposalReference] = []
    var humanCorrectionOverlayReference: HumanCorrectionOverlayReference? = nil

    init(
        id: UUID,
        subject: String,
        startedAt: Date,
        duration: TimeInterval,
        mode: CaptureMode,
        source: String,
        professorSpeakerID: String?,
        professorSelectionIsAutomatic: Bool,
        speakerCount: Int,
        state: ProcessingState,
        folderPath: String,
        technicalVocabulary: String,
        language: TranscriptionLanguage? = nil,
        schemaVersion: Int = 2,
        sessionPhase: SessionPhase? = nil,
        capturePhase: CapturePhase? = nil,
        asrPhase: AsrPhase? = nil,
        captureScope: CaptureScope? = nil,
        audioFormat: String = "legacy_unknown",
        formatVersion: Int = 1,
        platform: String = "macos",
        attemptID: SessionAttemptID? = nil,
        asrOriginalReference: ASRTranscriptReference? = nil,
        audioManifestReference: AudioManifestReference? = nil,
        diarizationProposalReferences: [DiarizationProposalReference] = [],
        humanCorrectionOverlayReference: HumanCorrectionOverlayReference? = nil,
    ) {
        self.id = id
        self.subject = subject
        self.startedAt = startedAt
        self.duration = duration
        self.mode = mode
        self.source = source
        self.professorSpeakerID = professorSpeakerID
        self.professorSelectionIsAutomatic = professorSelectionIsAutomatic
        self.speakerCount = speakerCount
        self.state = state
        self.folderPath = folderPath
        self.technicalVocabulary = technicalVocabulary
        self.language = language
        self.schemaVersion = schemaVersion
        self.sessionPhase = sessionPhase ?? state.sessionPhase
        self.capturePhase = capturePhase ?? state.defaultCapturePhase
        self.asrPhase = asrPhase ?? state.defaultAsrPhase
        self.captureScope = captureScope
        self.audioFormat = audioFormat
        self.formatVersion = formatVersion
        self.platform = platform
        self.attemptID = attemptID
        self.asrOriginalReference = asrOriginalReference
        self.audioManifestReference = audioManifestReference
        self.diarizationProposalReferences = diarizationProposalReferences
        self.humanCorrectionOverlayReference = humanCorrectionOverlayReference
    }
}

enum Timecode {
    static func display(_ seconds: TimeInterval) -> String {
        let total = safeInteger(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours):\(padded(minutes)):\(padded(secs))" }
        return "\(padded(minutes)):\(padded(secs))"
    }

    static func srt(_ seconds: TimeInterval) -> String {
        let milliseconds = safeInteger((seconds * 1_000).rounded())
        return "\(padded(milliseconds / 3_600_000)):\(padded((milliseconds / 60_000) % 60)):"
            + "\(padded((milliseconds / 1_000) % 60)),\(padded(milliseconds % 1_000, width: 3))"
    }

    private static func safeInteger(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        guard value < Double(Int.max) else { return Int.max }
        return Int(value)
    }

    private static func padded(_ value: Int, width: Int = 2) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

extension String {
    var filenameSlug: String {
        let normalized = precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "es"))
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var result = ""
        for character in normalized {
            let candidate = result + String(character)
            if candidate.utf8.count > 120 {
                break
            }
            result = candidate
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
