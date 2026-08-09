import AVFoundation
import Foundation
import Testing
@testable import ClassScribe

@Test("Las ventanas solapadas no duplican palabras")
func overlapDeduplication() {
    let stable = "Hoy estudiaremos el método de Newton Raphson para resolver ecuaciones"
    let incoming = "para resolver ecuaciones no lineales con varias iteraciones"
    #expect(OverlapDeduplicator.merge(stable: stable, incoming: incoming)
        == "Hoy estudiaremos el método de Newton Raphson para resolver ecuaciones no lineales con varias iteraciones")
}

@Test("Una pausa confirma la hipótesis provisional")
func liveConfirmation() {
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept("vamos a definir una función continua", confirmedByPause: false)
    #expect(accumulator.stableText.isEmpty)
    #expect(!accumulator.provisionalText.isEmpty)
    accumulator.accept("vamos a definir una función continua en este intervalo", confirmedByPause: true)
    #expect(accumulator.stableText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        == "vamos a definir una función continua en este intervalo")
    #expect(accumulator.provisionalText.isEmpty)
}

@Test("Cambiar el profesor regenera el filtro sin borrar a otros hablantes")
func speakerFiltering() {
    let first = TranscriptSegment(start: 0, end: 2, text: "Explicación", speakerID: "Persona 1", confidence: 0.9)
    let second = TranscriptSegment(start: 2, end: 3, text: "Pregunta", speakerID: "Persona 2", confidence: 0.9)
    let all = [first, second]
    #expect(SpeakerAssignment.professorSegments(from: all, professorID: "Persona 1", review: []).map(\.text) == ["Explicación"])
    #expect(SpeakerAssignment.professorSegments(from: all, professorID: "Persona 2", review: []).map(\.text) == ["Pregunta"])
    #expect(all.count == 2)
}

@Test("Baja confianza y superposición van a Revisar")
func lowConfidenceReview() {
    let transcript = [TranscriptSegment(start: 0, end: 4, text: "Dos voces", speakerID: "", confidence: 0)]
    let spans = [
        DiarizationSpan(start: 0, end: 2.2, speakerID: "Persona 1", quality: 0.9),
        DiarizationSpan(start: 1.8, end: 4, speakerID: "Persona 2", quality: 0.8),
    ]
    let result = SpeakerAssignment.assign(transcript: transcript, diarization: spans)
    #expect(result.segments.count == 1)
    #expect(result.review.count == 1)
    #expect(result.segments[0].overlappingVoices)
}

@Test("TXT, Markdown y SRT contienen la transcripción")
func exports() {
    let segments = [TranscriptSegment(start: 1.2, end: 3.4, text: "Hola, clase.", speakerID: "Persona 1", confidence: 1)]
    #expect(TranscriptExporter.plainText(segments).contains("Hola, clase."))
    #expect(TranscriptExporter.markdown(subject: "Análisis", date: Date(), segments: segments).contains("# Análisis"))
    #expect(TranscriptExporter.srt(segments).contains("00:00:01,200 --> 00:00:03,400"))
}

@Test("La transcripción final agrupa pausas naturales y separa cambios claros")
func finalTranscriptParagraphs() {
    let segments = [
        TranscriptSegment(start: 0, end: 2, text: "Primera idea.", speakerID: "Persona 1", confidence: 1),
        // A 2.8-second hesitation is still the same explanation.
        TranscriptSegment(start: 4.8, end: 7, text: "La idea continúa.", speakerID: "Persona 1", confidence: 1),
        // Four seconds of silence is a clear paragraph boundary.
        TranscriptSegment(start: 11, end: 13, text: "Nuevo punto.", speakerID: "Persona 1", confidence: 1),
        // A speaker change is a context boundary even without a long pause.
        TranscriptSegment(start: 13.1, end: 15, text: "Tengo una pregunta.", speakerID: "Persona 2", confidence: 1),
    ]

    let text = TranscriptExporter.plainText(segments)
    let paragraphs = text.components(separatedBy: "\n\n")
    #expect(paragraphs.count == 3)
    #expect(paragraphs[0].contains("Primera idea. La idea continúa."))
    #expect(!paragraphs[0].contains("[00:04]"))
    #expect(paragraphs[1].contains("Nuevo punto."))
    #expect(paragraphs[2].contains("Persona 2"))
}

@Test("El WAV Float32 generado es legible y no está vacío")
func wavValidation() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("known.wav")
    let samples = (0 ..< 16_000).map { index in Float(sin(2 * .pi * 440 * Double(index) / 16_000) * 0.2) }
    try WavFile.writeFloat32(samples, to: url)
    let duration = try WavFile.validate(url)
    #expect(abs(duration - 1) < 0.02)
    #expect((try Data(contentsOf: url)).count > 64_000)
}

@Test("La similitud de voz usa coseno y rechaza dimensiones incompatibles")
func voiceSimilarity() {
    #expect(SpeakerAssignment.cosineSimilarity([1, 0], [1, 0]) == 1)
    #expect(SpeakerAssignment.cosineSimilarity([1, 0], [0, 1]) == 0)
    #expect(SpeakerAssignment.cosineSimilarity([1], [1, 0]) == nil)
}
