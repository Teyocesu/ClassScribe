@testable import ClassScribe
import Foundation
import Testing

@Test
func copyUsesBestAvailableTranscriptInPriorityOrder() {
    let edited = TranscriptActions.bestAvailable(
        preferredEdit: "edición visible",
        professorEdit: nil,
        professor: "profesor",
        everyoneEdit: nil,
        everyone: "todos",
        liveEdit: nil,
        live: "vivo",
    )
    #expect(edited == "edición visible")
    #expect(TranscriptActions.bestAvailable(
        preferredEdit: nil, professorEdit: nil, professor: "profesor",
        everyoneEdit: nil, everyone: "todos", liveEdit: nil, live: "vivo",
    ) == "profesor")
    #expect(TranscriptActions.bestAvailable(
        preferredEdit: nil, professorEdit: nil, professor: "",
        everyoneEdit: nil, everyone: "todos", liveEdit: nil, live: "vivo",
    ) == "todos")
    #expect(TranscriptActions.bestAvailable(
        preferredEdit: nil, professorEdit: nil, professor: "",
        everyoneEdit: nil, everyone: "", liveEdit: nil, live: "vivo",
    ) == "vivo")
}

@Test
func chatGPTCopyIncludesContextAndTranscript() {
    let output = TranscriptActions.chatEnvelope(
        subject: "Métodos numéricos",
        date: Date(timeIntervalSince1970: 1_750_000_000),
        duration: 65,
        mode: .online,
        source: "Google Chrome",
        transcript: "contenido recuperado",
    )
    #expect(output.contains("Materia: Métodos numéricos"))
    #expect(output.contains("Duración: 01:05"))
    #expect(output.contains("Modo: Clase online"))
    #expect(output.contains("Fuente: Google Chrome"))
    #expect(output.contains("Transcripción:\n\ncontenido recuperado"))
}

@Test
func textExportsUseEditsAndSRTWarnsAboutSegments() throws {
    let segment = TranscriptSegment(
        start: 1.2,
        end: 2.5,
        text: "versión segmentada",
        speakerID: "Persona 1",
        confidence: 0.9,
    )
    let txt = try TranscriptExportPolicy.make(
        format: .txt,
        subject: "Álgebra",
        date: Date(),
        text: "versión editada",
        timedSegments: [segment],
        hasFreeformEdit: true,
    )
    #expect(txt.content == "versión editada")
    let markdown = try TranscriptExportPolicy.make(
        format: .markdown,
        subject: "Álgebra",
        date: Date(),
        text: "versión editada",
        timedSegments: [segment],
        hasFreeformEdit: true,
    )
    #expect(markdown.content.contains("versión editada"))
    #expect(!markdown.content.contains("versión segmentada"))
    let srt = try TranscriptExportPolicy.make(
        format: .srt,
        subject: "Álgebra",
        date: Date(),
        text: "versión editada",
        timedSegments: [segment],
        hasFreeformEdit: true,
    )
    #expect(srt.content.contains("versión segmentada"))
    #expect(srt.warning != nil)
}

@Test
func emptyAndUntimedExportsAreRejected() {
    do {
        _ = try TranscriptExportPolicy.make(
            format: .srt, subject: "Clase", date: Date(), text: "texto",
            timedSegments: [], hasFreeformEdit: false,
        )
        Issue.record("Se esperaba rechazo de SRT sin tiempos")
    } catch let error as TranscriptExportPolicyError {
        #expect(error == .missingTimedSegments)
    } catch {
        Issue.record("Error inesperado: \(error)")
    }
    do {
        _ = try TranscriptExportPolicy.make(
            format: .txt, subject: "Clase", date: Date(), text: "   ",
            timedSegments: [], hasFreeformEdit: false,
        )
        Issue.record("Se esperaba rechazo de texto vacío")
    } catch let error as TranscriptExportPolicyError {
        #expect(error == .emptyTranscript)
    } catch {
        Issue.record("Error inesperado: \(error)")
    }
}

@Test
func filenamesSupportUnicodeAndSafeLength() {
    let slug = "Álgebra 中文 / Diseño — 2026".filenameSlug
    #expect(slug.contains("álgebra"))
    #expect(slug.contains("中文"))
    #expect(!slug.contains("/"))
    #expect(slug.utf8.count <= 120)
    let long = String(repeating: "á", count: 200).filenameSlug
    #expect(long.utf8.count <= 120)
    #expect(!long.isEmpty)
}

@MainActor
@Test
func selectedTabControlsCopyAndExportSource() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-selection-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ClassScribeModel(store: SessionStore(root: root))
    model.finalReplacedLive = true
    model.allSegments = [
        TranscriptSegment(start: 0, end: 1, text: "explicación", speakerID: "Persona 1", confidence: 0.9),
        TranscriptSegment(start: 1, end: 2, text: "pregunta", speakerID: "Persona 2", confidence: 0.9),
    ]
    model.professorSpeakerID = "Persona 1"
    #expect(!model.availableTranscriptTabs.contains(.liveEdit))

    model.selectedTab = .everyone
    #expect(model.bestAvailableText.contains("pregunta"))
    #expect(model.selectedExportSegments.count == 2)

    model.selectedTab = .professor
    #expect(model.bestAvailableText.contains("explicación"))
    #expect(!model.bestAvailableText.contains("pregunta"))
    #expect(model.selectedExportSegments.map(\.speakerID) == ["Persona 1"])

    model.professorSpeakerID = nil
    model.editedAllText = "texto completo corregido"
    #expect(model.bestAvailableText == "texto completo corregido")
    #expect(model.selectedExportHasFreeformEdit)
    #expect(model.selectedExportSegments.count == 2)

    model.selectedTab = .review
    #expect(model.bestAvailableText == "texto completo corregido")
    #expect(model.selectedExportSegments.count == 2)

    model.editedLiveText = "explicación corregida durante la clase"
    #expect(model.availableTranscriptTabs.contains(.liveEdit))
    model.selectedTab = .liveEdit
    #expect(model.bestAvailableText == "explicación corregida durante la clase")
    #expect(model.selectedExportHasFreeformEdit)
    #expect(model.selectedExportSegments.count == 2)
}
