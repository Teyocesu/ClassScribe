@testable import ClassScribe
import Foundation
import Testing

@Test
func sessionsCreatedInTheSameSecondUseUniqueFolders() throws {
    let root = try makeSessionTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root)
    let started = Date(timeIntervalSince1970: 1_750_000_000)

    let first = try store.createFolder(subject: "Álgebra", date: started)
    let second = try store.createFolder(subject: "Álgebra", date: started)

    #expect(first != second)
    #expect(second.lastPathComponent.hasSuffix("-2"))
}

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["CLASSSCRIBE_RUN_PRIVATE_RECOVERY_AUDIT"] == "1"),
)
func privateSessionRecoveryAudit() throws {
    guard let rootPath = ProcessInfo.processInfo.environment["CLASSSCRIBE_RECOVERY_ROOT"],
          let sessionName = ProcessInfo.processInfo.environment["CLASSSCRIBE_RECOVERY_SESSION"]
    else {
        Issue.record("Faltan CLASSSCRIBE_RECOVERY_ROOT y CLASSSCRIBE_RECOVERY_SESSION")
        return
    }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let folder = root.appendingPathComponent(sessionName, isDirectory: true)
    let legacyURL = folder.appendingPathComponent("live-transcript.json")
    let originalLegacy = try Data(contentsOf: legacyURL)
    let store = SessionStore(root: root)
    let summary = try #require(store.scanSessions().first { $0.folder.lastPathComponent == sessionName })
    #expect(summary.isRecoverable)
    #expect(summary.canRetryProcessing)
    #expect(summary.preferredTextURL?.lastPathComponent == "recovered-transcript.txt")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("live-transcript.txt").path))
    #expect(!store.restore(summary).preferredText.isEmpty)
    #expect(try Data(contentsOf: legacyURL) == originalLegacy)
}

@Test
func legacySessionRecovery() throws {
    let root = try makeSessionTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("2026-07-01_090000_sesion-legacy", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try WavFile.writeFloat32(Array(repeating: 0.05, count: 16000), to: folder.appendingPathComponent("source.wav"))
    let legacy = Data("""
    {"provisional":"fragmento provisional conservado","stable":"texto estable","updatedAt":"2026-08-06T14:37:58Z"}
    """.utf8)
    let legacyURL = folder.appendingPathComponent("live-transcript.json")
    try legacy.write(to: legacyURL)
    try "transcripción completa recuperada".write(
        to: folder.appendingPathComponent("recovered-transcript.txt"),
        atomically: true,
        encoding: .utf8,
    )

    let store = SessionStore(root: root)
    let first = try #require(store.scanSessions().first)
    #expect(first.isRecoverable)
    #expect(first.canRetryProcessing)
    #expect(first.textSource == .recovered)
    #expect(first.preferredTextURL?.lastPathComponent == "recovered-transcript.txt")
    #expect(try Data(contentsOf: legacyURL) == legacy)

    let liveTXT = folder.appendingPathComponent("live-transcript.txt")
    let readable = try String(contentsOf: liveTXT, encoding: .utf8)
    #expect(readable.contains("texto estable"))
    #expect(readable.contains("fragmento provisional conservado"))
    let permissions = try #require(
        FileManager.default.attributesOfItem(atPath: liveTXT.path)[.posixPermissions] as? NSNumber,
    ).intValue & 0o777
    #expect(permissions == 0o600)

    let restored = store.restore(first)
    #expect(restored.preferredText == "transcripción completa recuperada")
    #expect(restored.preferredTextSource == .recovered)
    #expect(restored.liveAccumulator.visibleText.contains("texto estable"))
    #expect(store.scanSessions().first?.id == first.id)
    #expect(try Data(contentsOf: legacyURL) == legacy)
}

@Test
func invalidAudioRecovery() throws {
    let root = try makeSessionTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("2026-08-05_090000_clase-incompleta", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try Data([0, 1, 2]).write(to: folder.appendingPathComponent("source.wav"))
    try "Materia: Prueba\n\nTranscripción:\n\ntexto que no debe perderse\n".write(
        to: folder.appendingPathComponent("live-transcript.txt"),
        atomically: true,
        encoding: .utf8,
    )

    let store = SessionStore(root: root)
    let summary = try #require(store.scanSessions().first)
    #expect(summary.isRecoverable)
    #expect(summary.hasAudio)
    #expect(!summary.audioIsValid)
    #expect(!summary.canRetryProcessing)
    #expect(store.restore(summary).preferredText == "texto que no debe perderse")
}

@Test
func rawOnlySessionRecovery() throws {
    let root = try makeSessionTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("2026-08-05_100000-audio-crudo", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let rawURL = folder.appendingPathComponent("source.raw")
    let samples = Array(repeating: Float(0.04), count: 16000)
    let rawData = samples.withUnsafeBytes { Data($0) }
    try rawData.write(to: rawURL)
    try "Materia: Recuperación\n\nTranscripción:\n\ntexto conservado\n".write(
        to: folder.appendingPathComponent("live-transcript.txt"),
        atomically: true,
        encoding: .utf8,
    )

    let store = SessionStore(root: root)
    let summary = try #require(store.scanSessions().first)
    #expect(summary.isRecoverable)
    #expect(!summary.hasAudio)
    #expect(!summary.audioIsValid)
    #expect(summary.hasRecoverableRawAudio)
    #expect(summary.canRetryProcessing)
    #expect(summary.recoveryReason?.contains("audio crudo") == true)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("source.wav").path))
    #expect(try Data(contentsOf: rawURL) == rawData)
}

@Test
func restoredFinalEdits() throws {
    let root = try makeSessionTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root)
    let started = Date(timeIntervalSince1970: 1_750_000_000)
    let folder = try store.createFolder(subject: "Álgebra 中文", date: started)
    try WavFile.writeFloat32(Array(repeating: 0.02, count: 16000), to: folder.appendingPathComponent("source.wav"))
    let segment = TranscriptSegment(
        start: 0,
        end: 1,
        text: "texto segmentado original",
        speakerID: "Persona 1",
        confidence: 0.9,
    )
    let metadata = ClassMetadata(
        id: UUID(),
        subject: "Álgebra 中文",
        startedAt: started,
        duration: 1,
        mode: .inPerson,
        source: "Micrófono",
        professorSpeakerID: "Persona 1",
        professorSelectionIsAutomatic: false,
        speakerCount: 1,
        state: .complete,
        folderPath: folder.path,
        technicalVocabulary: "",
    )
    try store.saveFinal(
        metadata: metadata,
        all: [segment],
        professor: [segment],
        review: [],
        speakers: [],
        folder: folder,
        editedAllText: "texto completo corregido",
        editedProfessorText: "texto del profesor corregido",
    )

    let summary = try #require(store.scanSessions().first)
    #expect(!summary.isRecoverable)
    let restored = store.restore(summary)
    #expect(restored.editedAllText == "texto completo corregido")
    #expect(restored.editedProfessorText == "texto del profesor corregido")
    #expect(try String(contentsOf: folder.appendingPathComponent("all-speakers.md"), encoding: .utf8)
        .contains("texto completo corregido"))
    let persisted: [TranscriptSegment] = try JSONDecoder().decode(
        [TranscriptSegment].self,
        from: Data(contentsOf: folder.appendingPathComponent("all-speakers.json")),
    )
    #expect(persisted.map(\.text) == ["texto segmentado original"])
}

@Test
func failedDiarizationRemainsRetryable() throws {
    let root = try makeSessionTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root)
    let folder = try store.createFolder(subject: "Sistemas", date: Date())
    try WavFile.writeFloat32(Array(repeating: 0.03, count: 8000), to: folder.appendingPathComponent("source.wav"))
    let segment = TranscriptSegment(start: 0, end: 0.5, text: "ASR completo", speakerID: "Persona desconocida", confidence: 0.8)
    let metadata = ClassMetadata(
        id: UUID(), subject: "Sistemas", startedAt: Date(), duration: 0.5,
        mode: .inPerson, source: "Micrófono", professorSpeakerID: nil,
        professorSelectionIsAutomatic: true, speakerCount: 0, state: .failed,
        folderPath: folder.path, technicalVocabulary: "",
    )
    try store.saveFullTranscript(metadata: metadata, segments: [segment], folder: folder)
    let summary = try #require(store.scanSessions().first)
    #expect(summary.isRecoverable)
    #expect(summary.canRetryProcessing)
    #expect(store.restore(summary).allSegments.count == 1)
}

@Test
func sessionDirectoriesArePrivateAndSymlinkFoldersAreIgnored() throws {
    let root = try makeSessionTestRoot()
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-session-outside-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let store = SessionStore(root: root)
    let folder = try store.createFolder(subject: "Privacidad", date: Date())
    for url in [root, folder] {
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber,
        ).intValue & 0o777
        #expect(permissions == 0o700)
    }

    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data("evidencia externa".utf8).write(to: outside.appendingPathComponent("metadata.json"))
    let link = root.appendingPathComponent("sesion-enlace", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    #expect(store.scanSessions().allSatisfy { $0.folder.lastPathComponent != link.lastPathComponent })
    #expect(try Data(contentsOf: outside.appendingPathComponent("metadata.json")) == Data("evidencia externa".utf8))
}

@Test
func completeMetadataIsCommittedOnlyAfterFinalOutputs() throws {
    let root = try makeSessionTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root)
    let folder = try store.createFolder(subject: "Commit final", date: Date())
    let sessionID = UUID()
    let interrupted = ClassMetadata(
        id: sessionID, subject: "Commit final", startedAt: Date(), duration: 1,
        mode: .inPerson, source: "Micrófono", professorSpeakerID: nil,
        professorSelectionIsAutomatic: true, speakerCount: 0, state: .diarizing,
        folderPath: folder.path, technicalVocabulary: "",
    )
    try store.saveMetadata(interrupted, folder: folder)
    try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("professor.srt", isDirectory: true),
        withIntermediateDirectories: false,
    )
    var complete = interrupted
    complete.state = .complete
    let segment = TranscriptSegment(
        start: 0, end: 1, text: "texto durable", speakerID: "Persona 1", confidence: 0.9,
    )

    #expect(throws: (any Error).self) {
        try store.saveFinal(
            metadata: complete,
            all: [segment],
            professor: [segment],
            review: [],
            speakers: [],
            folder: folder,
        )
    }
    let persisted = try JSONDecoder.withISO8601.decode(
        ClassMetadata.self,
        from: Data(contentsOf: folder.appendingPathComponent("metadata.json")),
    )
    #expect(persisted.id == sessionID)
    #expect(persisted.state == .diarizing)
}

private func makeSessionTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-session-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private extension JSONDecoder {
    static var withISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
