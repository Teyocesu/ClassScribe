@testable import ClassScribe
import Foundation
import Testing

@Test
func correctedWordsRemainWhileNewASRTextIsAppended() {
    let previous = "La mitocondria es una célula"
    let edited = "La mitocondria es un orgánulo"
    let updated = previous + " y produce energía."

    let merged = LiveTranscriptEditMerger.merge(
        editedText: edited,
        previousASRText: previous,
        updatedASRText: updated,
    )

    #expect(merged == "La mitocondria es un orgánulo y produce energía.")
    #expect(!merged.contains("es una célula"))
}

@Test
func deletedASRWordsAreNotRestoredByLaterWindows() {
    let previous = "Inicio correcto texto equivocado"
    let edited = "Inicio correcto"
    let firstUpdate = previous + " Nueva explicación"
    let secondUpdate = firstUpdate + " Ejemplo final"

    let afterFirst = LiveTranscriptEditMerger.merge(
        editedText: edited,
        previousASRText: previous,
        updatedASRText: firstUpdate,
    )
    let afterSecond = LiveTranscriptEditMerger.merge(
        editedText: afterFirst,
        previousASRText: firstUpdate,
        updatedASRText: secondUpdate,
    )

    #expect(afterSecond == "Inicio correcto Nueva explicación Ejemplo final")
    #expect(!afterSecond.contains("texto equivocado"))
}

@Test
func humanTextAddedAtTheEndIsKeptAheadOfNewASRText() {
    let previous = "Explicación automática"
    let edited = "Explicación automática [anotación propia]"
    let updated = previous + " Siguiente fragmento automático"

    #expect(LiveTranscriptEditMerger.merge(
        editedText: edited,
        previousASRText: previous,
        updatedASRText: updated,
    ) == "Explicación automática [anotación propia] Siguiente fragmento automático")
}

@Test
func aNoteWrittenBeforeTheFirstASRWindowGetsAReadableSeparator() {
    #expect(LiveTranscriptEditMerger.merge(
        editedText: "Nota inicial:",
        previousASRText: "",
        updatedASRText: "comienza la explicación",
    ) == "Nota inicial: comienza la explicación")
}

@Test
func clearingTheEditorDoesNotBringBackOldASRText() {
    let previous = "Todo este contenido estaba mal"
    let updated = previous + " Este fragmento sí es nuevo"

    #expect(LiveTranscriptEditMerger.merge(
        editedText: "",
        previousASRText: previous,
        updatedASRText: updated,
    ) == "Este fragmento sí es nuevo")
}

@Test
func unchangedOrReplacedASRNeverOverwritesHumanText() {
    let edited = "Corrección humana importante"

    #expect(LiveTranscriptEditMerger.merge(
        editedText: edited,
        previousASRText: "versión automática",
        updatedASRText: "versión automática",
    ) == edited)
    #expect(LiveTranscriptEditMerger.merge(
        editedText: edited,
        previousASRText: "versión automática anterior",
        updatedASRText: "hipótesis automática reemplazada",
    ) == edited)
}

@Test
func reconcilerTracksASRBeforeAndAfterTheFirstHumanEdit() {
    var reconciler = LiveTranscriptEditReconciler()

    #expect(reconciler.reconcile(
        editedText: nil,
        updatedASRText: "El resultado es cuarenta y tres",
    ) == nil)
    #expect(reconciler.lastASRText == "El resultado es cuarenta y tres")

    let corrected = reconciler.reconcile(
        editedText: "El resultado es cuarenta y dos",
        updatedASRText: "El resultado es cuarenta y tres y concluye la prueba.",
    )
    #expect(corrected == "El resultado es cuarenta y dos y concluye la prueba.")
    #expect(reconciler.lastASRText == "El resultado es cuarenta y tres y concluye la prueba.")
}

@Test
func reconcilerResetPreventsTextFromAFormerSessionLeakingIntoTheNextOne() {
    var reconciler = LiveTranscriptEditReconciler()
    _ = reconciler.reconcile(editedText: nil, updatedASRText: "sesión anterior")

    reconciler.reset(asrText: "nueva sesión")

    #expect(reconciler.reconcile(
        editedText: "nueva sesión corregida",
        updatedASRText: "nueva sesión con más contenido",
    ) == "nueva sesión corregida con más contenido")
}

@Test
func confirmingAProvisionalChunkDoesNotDuplicateItInTheHumanEdit() {
    var accumulator = LiveTranscriptAccumulator()
    var reconciler = LiveTranscriptEditReconciler()
    accumulator.accept("primer fragmento automático", confirmedByPause: false)
    _ = reconciler.reconcile(editedText: nil, updatedASRText: accumulator.visibleText)

    let humanEdit = "primer fragmento corregido"
    accumulator.confirmProvisional()
    let afterConfirmation = reconciler.reconcile(
        editedText: humanEdit,
        updatedASRText: accumulator.visibleText,
    )
    #expect(afterConfirmation == humanEdit)

    accumulator.accept("segundo fragmento automático", confirmedByPause: false)
    let afterNextWindow = reconciler.reconcile(
        editedText: afterConfirmation,
        updatedASRText: accumulator.visibleText,
    )
    #expect(afterNextWindow == "primer fragmento corregido segundo fragmento automático")
}

@MainActor
@Test
func explicitFlushMakesTheLiveEditRecoverable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-live-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root)
    let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let folder = try store.createFolder(subject: "Biología", date: startedAt)
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept("La mitocondria es una célula", confirmedByPause: false)
    let context = LiveTranscriptContext(
        subject: "Biología",
        startedAt: startedAt,
        mode: .inPerson,
        source: "Micrófono",
        duration: 4,
    )
    try store.saveLive(
        accumulator: accumulator,
        context: context,
        folder: folder,
        checkpoint: "fixture",
    )
    try store.saveMetadata(
        ClassMetadata(
            id: UUID(), subject: context.subject, startedAt: startedAt, duration: 4,
            mode: context.mode, source: context.source, professorSpeakerID: nil,
            professorSelectionIsAutomatic: true, speakerCount: 0, state: .recording,
            folderPath: folder.path, technicalVocabulary: "",
        ),
        folder: folder,
    )
    let summary = try #require(store.scanSessions().first)
    let model = ClassScribeModel(store: store)
    model.openHistory(summary)

    model.updateEditedLiveText("La mitocondria es un orgánulo")
    model.flushEditedLiveText()

    let restoredSummary = try #require(store.scanSessions().first)
    let restored = store.restore(restoredSummary)
    #expect(restored.editedLiveText == "La mitocondria es un orgánulo")
    #expect(restored.preferredText == "La mitocondria es un orgánulo")
}

@MainActor
@Test
func emptyLiveEditSurvivesRestartAndNeverFallsBackToFinalText() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-empty-live-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root)
    let startedAt = Date(timeIntervalSince1970: 1_750_100_000)
    let folder = try store.createFolder(subject: "Física", date: startedAt)
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept("texto automático que la persona borró", confirmedByPause: true)
    let context = LiveTranscriptContext(
        subject: "Física", startedAt: startedAt, mode: .inPerson,
        source: "Micrófono", duration: 8,
    )
    try store.saveLive(
        accumulator: accumulator,
        context: context,
        folder: folder,
        checkpoint: "empty-human-edit",
        visibleTextOverride: "",
    )
    let metadata = ClassMetadata(
        id: UUID(), subject: context.subject, startedAt: startedAt, duration: 8,
        mode: context.mode, source: context.source, professorSpeakerID: "Persona 1",
        professorSelectionIsAutomatic: false, speakerCount: 1, state: .complete,
        folderPath: folder.path, technicalVocabulary: "",
    )
    let finalSegments = [
        TranscriptSegment(
            start: 0, end: 8, text: "texto automático final",
            speakerID: "Persona 1", confidence: 1,
        ),
    ]
    try store.saveFinal(
        metadata: metadata,
        all: finalSegments,
        professor: finalSegments,
        review: [],
        speakers: [],
        folder: folder,
    )

    let summary = try #require(store.scanSessions().first)
    let restored = store.restore(summary)
    #expect(restored.editedLiveText == "")

    let model = ClassScribeModel(store: store)
    model.openHistory(summary)
    #expect(model.selectedTab == .liveEdit)
    #expect(model.displayedText == "")
    #expect(model.bestAvailableText == "")
    #expect(!model.hasCopyableTranscript)
    #expect(model.currentReadableTextURL?.lastPathComponent == "live-transcript.txt")

    model.selectedTab = .professor
    #expect(model.currentReadableTextURL?.lastPathComponent == "professor.txt")
    model.selectedTab = .everyone
    #expect(model.currentReadableTextURL?.lastPathComponent == "all-speakers.txt")
}

@MainActor
@Test
func switchingHistoryFlushesThePendingEditFromThePreviousSession() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-switch-live-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root)

    func makeSession(subject: String, date: Date) throws -> SessionSummary {
        let folder = try store.createFolder(subject: subject, date: date)
        var accumulator = LiveTranscriptAccumulator()
        accumulator.accept("texto de \(subject)", confirmedByPause: true)
        let context = LiveTranscriptContext(
            subject: subject, startedAt: date, mode: .inPerson,
            source: "Micrófono", duration: 2,
        )
        try store.saveLive(
            accumulator: accumulator,
            context: context,
            folder: folder,
            checkpoint: "fixture",
        )
        try store.saveMetadata(
            ClassMetadata(
                id: UUID(), subject: subject, startedAt: date, duration: 2,
                mode: context.mode, source: context.source, professorSpeakerID: nil,
                professorSelectionIsAutomatic: true, speakerCount: 0, state: .recording,
                folderPath: folder.path, technicalVocabulary: "",
            ),
            folder: folder,
        )
        return try #require(store.scanSessions().first { $0.folder == folder })
    }

    let first = try makeSession(
        subject: "Primera",
        date: Date(timeIntervalSince1970: 1_750_200_000),
    )
    let second = try makeSession(
        subject: "Segunda",
        date: Date(timeIntervalSince1970: 1_750_200_100),
    )
    let model = ClassScribeModel(store: store)
    model.openHistory(first)
    model.updateEditedLiveText("corrección pendiente de la primera")

    // This switch happens before the 300 ms debounce can persist naturally.
    model.openHistory(second)

    #expect(store.restore(first).editedLiveText == "corrección pendiente de la primera")
}
