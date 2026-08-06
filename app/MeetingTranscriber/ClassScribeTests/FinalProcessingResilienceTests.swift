@testable import ClassScribe
import Foundation
import Testing

private enum FinalStubBehavior: Equatable, Sendable {
    case transcriptionFailure
    case diarizationFailure
    case success
}

private enum FinalStubError: LocalizedError, Sendable {
    case transcription
    case diarization

    var errorDescription: String? {
        switch self {
        case .transcription: "fallo ASR simulado"
        case .diarization: "fallo de diarización simulado"
        }
    }
}

private actor StubFinalProcessor: FinalProcessingProviding {
    let behavior: FinalStubBehavior

    init(_ behavior: FinalStubBehavior) {
        self.behavior = behavior
    }

    func configureVocabulary(file _: URL?) async throws {}

    func transcribe(_: URL) async throws -> [TranscriptSegment] {
        if behavior == .transcriptionFailure {
            throw FinalStubError.transcription
        }
        return [TranscriptSegment(
            start: 0,
            end: 1,
            text: "transcripción final persistida",
            speakerID: "Persona desconocida",
            confidence: 0.9,
        )]
    }

    func diarize(_: URL) async throws -> (spans: [DiarizationSpan], embeddings: [String: [Float]]) {
        if behavior == .diarizationFailure {
            throw FinalStubError.diarization
        }
        return (
            [DiarizationSpan(start: 0, end: 1, speakerID: "Persona 1", quality: 0.95)],
            ["Persona 1": [1, 0]],
        )
    }
}

private actor SlowCountingFinalProcessor: FinalProcessingProviding {
    private var transcriptionCalls = 0
    private var diarizationCalls = 0

    func configureVocabulary(file _: URL?) async throws {}

    func transcribe(_: URL) async throws -> [TranscriptSegment] {
        transcriptionCalls += 1
        try await Task.sleep(for: .milliseconds(150))
        return [TranscriptSegment(
            start: 0,
            end: 1,
            text: "resultado único",
            speakerID: "Persona desconocida",
            confidence: 0.9,
        )]
    }

    func diarize(_: URL) async throws -> (spans: [DiarizationSpan], embeddings: [String: [Float]]) {
        diarizationCalls += 1
        return (
            [DiarizationSpan(start: 0, end: 1, speakerID: "Persona 1", quality: 0.95)],
            ["Persona 1": [1, 0]],
        )
    }

    func counts() -> (transcription: Int, diarization: Int) {
        (transcriptionCalls, diarizationCalls)
    }
}

private actor CancellableFinalProcessor: FinalProcessingProviding {
    func configureVocabulary(file _: URL?) async throws {}

    func transcribe(_: URL) async throws -> [TranscriptSegment] {
        try await Task.sleep(for: .seconds(30))
        return []
    }

    func diarize(_: URL) async throws -> (spans: [DiarizationSpan], embeddings: [String: [Float]]) {
        Issue.record("La diarización no debe comenzar después de cancelar ASR")
        return ([], [:])
    }
}

@MainActor
@Test
func finalTranscriptionFailurePreservesRecovery() async throws {
    let fixture = try makeRecoverableProcessingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalAudio = try Data(contentsOf: fixture.audio)
    let model = ClassScribeModel(
        store: fixture.store,
        finalProcessor: StubFinalProcessor(.transcriptionFailure),
    )
    let summary = try #require(model.history.first)
    model.openHistory(summary)
    await model.retryProcessing()
    await model.waitForFinalProcessingForTesting()

    #expect(model.state == .failed)
    #expect(model.bestAvailableText.contains("texto vivo durable"))
    #expect(model.hasCopyableTranscript)
    #expect(try Data(contentsOf: fixture.audio) == originalAudio)
    #expect(try String(contentsOf: fixture.folder.appendingPathComponent("live-transcript.txt"), encoding: .utf8)
        .contains("texto vivo durable"))
}

@MainActor
@Test
func diarizationFailurePreservesFullTranscript() async throws {
    let fixture = try makeRecoverableProcessingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalAudio = try Data(contentsOf: fixture.audio)
    let model = ClassScribeModel(
        store: fixture.store,
        finalProcessor: StubFinalProcessor(.diarizationFailure),
    )
    try model.openHistory(#require(model.history.first))
    await model.retryProcessing()
    await model.waitForFinalProcessingForTesting()

    #expect(model.state == .failed)
    #expect(model.finalReplacedLive)
    #expect(model.allSegments.map(\.text) == ["transcripción final persistida"])
    #expect(model.bestAvailableText.contains("transcripción final persistida"))
    #expect(try String(contentsOf: fixture.folder.appendingPathComponent("all-speakers.txt"), encoding: .utf8)
        .contains("transcripción final persistida"))
    #expect(try String(contentsOf: fixture.folder.appendingPathComponent("all-speakers.md"), encoding: .utf8)
        .contains("transcripción final persistida"))
    #expect(try Data(contentsOf: fixture.audio) == originalAudio)
}

@MainActor
@Test
func successfulFinalRetryCompletesSession() async throws {
    let fixture = try makeRecoverableProcessingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = ClassScribeModel(store: fixture.store, finalProcessor: StubFinalProcessor(.success))
    try model.openHistory(#require(model.history.first))
    await model.retryProcessing()
    await model.waitForFinalProcessingForTesting()

    #expect(model.state == .complete)
    #expect(model.speakers.map(\.id) == ["Persona 1"])
    #expect(model.professorSpeakerID == "Persona 1")
    #expect(!model.professorSegments.isEmpty)
    #expect(model.history.first?.isRecoverable == false)
    #expect(try String(contentsOf: fixture.folder.appendingPathComponent("professor.txt"), encoding: .utf8)
        .contains("transcripción final persistida"))
}

@MainActor
@Test
func rawOnlyFinalRetryCompletesSession() async throws {
    let fixture = try makeRecoverableProcessingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.removeItem(at: fixture.audio)
    let rawURL = fixture.folder.appendingPathComponent("source.raw")
    let samples = Array(repeating: Float(0.05), count: 16000)
    let rawData = samples.withUnsafeBytes { Data($0) }
    try rawData.write(to: rawURL)
    let model = ClassScribeModel(store: fixture.store, finalProcessor: StubFinalProcessor(.success))
    let summary = try #require(model.history.first)
    #expect(summary.hasRecoverableRawAudio)
    model.openHistory(summary)

    await model.retryProcessing()
    await model.waitForFinalProcessingForTesting()

    #expect(model.state == .complete)
    #expect(try abs(WavFile.validate(fixture.audio) - 1) < 0.02)
    #expect(try Data(contentsOf: rawURL) == rawData)
    #expect(model.history.first?.isRecoverable == false)
}

@MainActor
@Test
func retryIsSingleFlightAndSessionBound() async throws {
    let fixture = try makeRecoverableProcessingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let otherFolder = try makeCompletedHistorySession(store: fixture.store)
    let processor = SlowCountingFinalProcessor()
    let model = ClassScribeModel(store: fixture.store, finalProcessor: processor)
    let target = try #require(model.history.first { $0.folder == fixture.folder })
    let other = try #require(model.history.first { $0.folder == otherFolder })
    model.openHistory(target)

    let first = Task { @MainActor in await model.retryProcessing() }
    for _ in 0 ..< 100 where !model.isSessionBusy {
        await Task.yield()
    }
    #expect(model.isSessionBusy)
    model.openHistory(other)
    #expect(model.currentFolder == fixture.folder)
    let duplicate = Task { @MainActor in await model.retryProcessing() }
    await first.value
    await duplicate.value
    await model.waitForFinalProcessingForTesting()

    let counts = await processor.counts()
    #expect(counts.transcription == 1)
    #expect(counts.diarization == 1)
    #expect(model.state == .complete)
    #expect(model.currentFolder == fixture.folder)
}

@MainActor
@Test
func cancellingFinalProcessingKeepsAudioAndLiveText() async throws {
    let fixture = try makeRecoverableProcessingFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalAudio = try Data(contentsOf: fixture.audio)
    let model = ClassScribeModel(store: fixture.store, finalProcessor: CancellableFinalProcessor())
    model.openHistory(try #require(model.history.first))

    await model.retryProcessing()
    #expect(model.state == .finalTranscription)
    model.cancelFinalProcessing()
    await model.waitForFinalProcessingForTesting()

    #expect(model.state == .cancelled)
    #expect(model.bestAvailableText.contains("texto vivo durable"))
    #expect(model.hasCopyableTranscript)
    #expect(try Data(contentsOf: fixture.audio) == originalAudio)
    #expect(model.history.first?.isRecoverable == true)
}

private struct RecoverableProcessingFixture {
    var root: URL
    var folder: URL
    var audio: URL
    var store: SessionStore
}

private func makeRecoverableProcessingFixture() throws -> RecoverableProcessingFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-final-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let store = SessionStore(root: root)
    let started = Date(timeIntervalSince1970: 1_750_000_000)
    let folder = try store.createFolder(subject: "Prueba resiliente", date: started)
    let audio = folder.appendingPathComponent("source.wav")
    try WavFile.writeFloat32(Array(repeating: 0.05, count: 16000), to: audio)
    var accumulator = LiveTranscriptAccumulator()
    accumulator.accept("texto vivo durable", start: 0, end: 1, confirmedByPause: false)
    accumulator.confirmProvisional()
    let context = LiveTranscriptContext(
        subject: "Prueba resiliente",
        startedAt: started,
        mode: .inPerson,
        source: "Micrófono de prueba",
        duration: 1,
    )
    try store.saveLive(accumulator: accumulator, context: context, folder: folder, checkpoint: "fixture")
    try store.saveMetadata(
        ClassMetadata(
            id: UUID(), subject: context.subject, startedAt: started, duration: 1,
            mode: context.mode, source: context.source, professorSpeakerID: nil,
            professorSelectionIsAutomatic: true, speakerCount: 0, state: .failed,
            folderPath: folder.path, technicalVocabulary: "",
        ),
        folder: folder,
    )
    return RecoverableProcessingFixture(root: root, folder: folder, audio: audio, store: store)
}

private func makeCompletedHistorySession(store: SessionStore) throws -> URL {
    let started = Date(timeIntervalSince1970: 1_750_000_100)
    let folder = try store.createFolder(subject: "Otra sesión", date: started)
    try WavFile.writeFloat32(Array(repeating: 0.02, count: 8000), to: folder.appendingPathComponent("source.wav"))
    let segment = TranscriptSegment(
        start: 0,
        end: 0.5,
        text: "otra sesión completa",
        speakerID: "Persona 1",
        confidence: 0.9,
    )
    let metadata = ClassMetadata(
        id: UUID(), subject: "Otra sesión", startedAt: started, duration: 0.5,
        mode: .inPerson, source: "Micrófono", professorSpeakerID: "Persona 1",
        professorSelectionIsAutomatic: false, speakerCount: 1, state: .complete,
        folderPath: folder.path, technicalVocabulary: "",
    )
    try store.saveFinal(
        metadata: metadata,
        all: [segment],
        professor: [segment],
        review: [],
        speakers: [],
        folder: folder,
    )
    return folder
}
