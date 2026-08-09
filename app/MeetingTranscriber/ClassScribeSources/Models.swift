import Foundation

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case online = "Clase online"
    case inPerson = "Clase presencial"

    var id: String { rawValue }
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
    let id: Int32
    let name: String
    let bundleIdentifier: String
    let bundleURL: URL?
}

struct MicrophoneOption: Identifiable, Hashable {
    let id: String
    let name: String
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

struct ClassMetadata: Identifiable, Codable, Equatable {
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
}

enum Timecode {
    static func display(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func srt(_ seconds: TimeInterval) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        return String(
            format: "%02d:%02d:%02d,%03d",
            milliseconds / 3_600_000,
            (milliseconds / 60_000) % 60,
            (milliseconds / 1_000) % 60,
            milliseconds % 1_000
        )
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
