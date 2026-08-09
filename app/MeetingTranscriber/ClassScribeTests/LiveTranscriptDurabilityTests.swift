@testable import ClassScribe
import Foundation
import Testing

@Test
func incompatibleHypothesisPreservesPreviousProvisional() {
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept("primera explicación completa", start: 0, end: 7, confirmedByPause: false)
    let firstVisible = accumulator.visibleText
    accumulator.accept("tema totalmente diferente", start: 5.5, end: 12.5, confirmedByPause: false)

    #expect(accumulator.stableText.contains(firstVisible))
    #expect(accumulator.visibleText.contains("primera explicación completa"))
    #expect(accumulator.visibleText.contains("tema totalmente diferente"))
}

@Test
func continuousWindowsNeverShrinkCommittedText() {
    var accumulator = LiveTranscriptAccumulator()
    var previousCount = 0
    for index in 0 ..< 10 {
        accumulator.accept(
            "ventana \(index) explica contenido técnico número \(index)",
            start: Double(index) * 5.5,
            end: Double(index) * 5.5 + 7,
            confirmedByPause: false,
        )
        #expect(accumulator.stableText.count >= previousCount)
        previousCount = accumulator.stableText.count
    }
    accumulator.confirmProvisional()
    for index in 0 ..< 10 {
        #expect(accumulator.stableText.contains("ventana \(index)"))
    }
}

@Test
func exactOverlapDoesNotDuplicateTail() {
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept("hoy veremos el método de Newton para ecuaciones", confirmedByPause: false)
    accumulator.accept("para ecuaciones no lineales con iteraciones", confirmedByPause: false)
    accumulator.confirmProvisional()

    #expect(accumulator.stableText.components(separatedBy: "para ecuaciones").count - 1 == 1)
    #expect(accumulator.stableText.contains("no lineales con iteraciones"))
}

@Test
func emptyHypothesisAndExternalFailureDoNotMutateAccumulator() {
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept("contenido ya visible", confirmedByPause: false)
    let before = accumulator
    accumulator.accept("   ", confirmedByPause: false)
    #expect(accumulator == before)
    // An ASR error does not call accept; preserving the value proves that path's invariant.
    #expect(accumulator.visibleText == before.visibleText)
}

@Test
func pauseAndStopPreserveLastProvisional() {
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept("texto antes de la pausa", confirmedByPause: false)
    accumulator.accept("", confirmedByPause: true)
    #expect(accumulator.provisionalText.isEmpty)
    #expect(accumulator.stableText.contains("texto antes de la pausa"))

    accumulator.accept("último texto antes de detener", confirmedByPause: false)
    accumulator.confirmProvisional()
    #expect(accumulator.stableText.contains("último texto antes de detener"))
}

@Test
func ordinaryThinkingPauseKeepsLiveTranscriptInOneParagraph() {
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept(
        "La derivada nos indica la pendiente.",
        end: 4,
        confirmedByPause: true,
        pauseDuration: 2.8,
    )
    accumulator.accept(
        "Ahora podemos buscar el mínimo.",
        start: 6.8,
        confirmedByPause: false,
    )

    #expect(accumulator.visibleText
        == "La derivada nos indica la pendiente. Ahora podemos buscar el mínimo.")
    #expect(!accumulator.visibleText.contains("\n"))
}

@Test
func longCompletedThoughtStartsNewLiveParagraph() {
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept(
        "Con esto termina la primera demostración.",
        confirmedByPause: true,
        pauseDuration: 4.2,
    )
    accumulator.accept("Pasemos al siguiente teorema.", confirmedByPause: false)

    #expect(accumulator.visibleText
        == "Con esto termina la primera demostración.\n\nPasemos al siguiente teorema.")
}

@Test
func longSilenceWithoutSentenceClosureDoesNotForceLiveParagraph() {
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept(
        "si despejamos la variable",
        confirmedByPause: true,
        pauseDuration: 5,
    )
    accumulator.accept("obtenemos este resultado", confirmedByPause: false)

    #expect(!accumulator.visibleText.contains("\n"))
}

@Test
func oneHundredWindowsPreserveAllFragments() {
    var accumulator = LiveTranscriptAccumulator()
    var committedCounts: [Int] = []
    for index in 0 ..< 100 {
        accumulator.accept("fragmento técnico único ID\(index)", confirmedByPause: false)
        committedCounts.append(accumulator.stableText.count)
    }
    accumulator.confirmProvisional()

    #expect(zip(committedCounts, committedCounts.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
    for index in 0 ..< 100 {
        #expect(accumulator.stableText.contains("ID\(index)"))
    }
}

@Test
func punctuationVocabularyAndPartialWordsDoNotDropChunks() {
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept("Aplicamos Newton-Raphson a la fun", confirmedByPause: false)
    accumulator.accept("función objetivo; luego usamos PMBOK.", confirmedByPause: false)
    accumulator.accept("¿Qué ocurre con Runge-Kutta?", confirmedByPause: true)

    #expect(accumulator.stableText.contains("Newton-Raphson"))
    #expect(accumulator.stableText.contains("PMBOK"))
    #expect(accumulator.stableText.contains("Runge-Kutta"))
}

@Test
func durableRepresentationsStayConsistentAndPrivate() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-Live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let store = SessionStore(root: folder.deletingLastPathComponent())
    let context = LiveTranscriptContext(
        subject: "Análisis Numérico",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        mode: .inPerson,
        source: "Micrófono",
        duration: 12,
    )
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept("primera ventana", confirmedByPause: false)
    try store.saveLive(accumulator: accumulator, context: context, folder: folder, checkpoint: "window-1")
    accumulator.accept("segunda ventana", confirmedByPause: false)
    try store.saveLive(accumulator: accumulator, context: context, folder: folder, checkpoint: "window-2")

    let textURL = folder.appendingPathComponent("live-transcript.txt")
    let markdownURL = folder.appendingPathComponent("live-transcript.md")
    let jsonURL = folder.appendingPathComponent("live-transcript.json")
    let journalURL = folder.appendingPathComponent("live-transcript-journal.jsonl")
    let text = try String(contentsOf: textURL, encoding: .utf8)
    #expect(text.contains(accumulator.visibleText))
    #expect(try String(contentsOf: markdownURL, encoding: .utf8).contains(accumulator.visibleText))
    let restored = try #require(store.loadLive(folder: folder))
    #expect(restored.visibleText == accumulator.visibleText)
    #expect(restored.committedChunks.map(\.id) == accumulator.committedChunks.map(\.id))

    let lines = try Data(contentsOf: journalURL).split(separator: 0x0A)
    #expect(lines.count == 2)
    for line in lines {
        _ = try JSONSerialization.jsonObject(with: Data(line))
    }
    for url in [textURL, markdownURL, jsonURL, journalURL] {
        let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o077 == 0)
    }
    #expect(try (FileManager.default.contentsOfDirectory(atPath: folder.path)).allSatisfy { !$0.hasSuffix(".tmp") })
}

@Test
func legacySnapshotAndJournalRestoreAfterRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClassScribe-Recovery-\(UUID().uuidString)")
    let folder = root.appendingPathComponent("session")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root)

    let legacy = #"{"stable":"texto estable","provisional":"cola pendiente","updatedAt":"2026-08-06T14:37:58Z"}"#
    try Data(legacy.utf8).write(to: folder.appendingPathComponent("live-transcript.json"), options: .atomic)
    let restoredLegacy = try #require(store.loadLive(folder: folder))
    #expect(restoredLegacy.visibleText.contains("texto estable"))
    #expect(restoredLegacy.visibleText.contains("cola pendiente"))

    var current = LiveTranscriptAccumulator()
    current.accept("texto desde journal", confirmedByPause: false)
    try store.saveLive(
        accumulator: current,
        context: LiveTranscriptContext(subject: "Materia", startedAt: Date(), mode: .online, source: "Chrome", duration: 4),
        folder: folder,
        checkpoint: "journal",
    )
    try FileManager.default.removeItem(at: folder.appendingPathComponent("live-transcript.json"))
    let restoredJournal = try #require(store.loadLive(folder: folder))
    #expect(restoredJournal.visibleText == current.visibleText)
    #expect(restoredJournal.provisionalChunk?.id == current.provisionalChunk?.id)
}
