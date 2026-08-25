@testable import ClassScribe
import Foundation
import Testing

@Test("Una generación anterior no pasa el gate de ownership")
func staleSessionAttemptIsRejected() {
    var gate = SessionGenerationGate()
    let first = gate.begin(sessionID: UUID())
    let second = gate.begin(sessionID: first.sessionID)

    #expect(!gate.accepts(first))
    #expect(gate.accepts(second))
    #expect(first.sessionID == second.sessionID)
    #expect(first.generation < second.generation)
    #expect(first.nonce != second.nonce)
}

@Test("Schema v2 persiste tokens estables y ejes concurrentes")
func schemaV2UsesStableTokens() throws {
    let attempt = SessionAttemptID(sessionID: UUID(), generation: 4)
    let metadata = ClassMetadata(
        id: attempt.sessionID,
        subject: "Física",
        startedAt: Date(timeIntervalSince1970: 1_750_000_000),
        duration: 4,
        mode: .online,
        source: "Chrome",
        professorSpeakerID: nil,
        professorSelectionIsAutomatic: true,
        speakerCount: 0,
        state: .complete,
        folderPath: "/tmp/classscribe",
        technicalVocabulary: "vector",
        language: .french,
        sessionPhase: .complete,
        capturePhase: .idle,
        asrPhase: .idle,
        captureScope: .application,
        audioFormat: "float32_16000_mono",
        attemptID: attempt,
    )

    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any]
    #expect(object?["schemaVersion"] as? Int == 2)
    #expect(object?["captureScope"] as? String == "application")
    #expect(object?["sessionPhase"] as? String == "complete")
    #expect(object?["capturePhase"] as? String == "idle")
    #expect(object?["asrPhase"] as? String == "idle")
    #expect(object?["transcriptionLanguage"] as? String == "fr")
    #expect(object?["sessionAttemptID"] is [String: Any])
    #expect(!String(data: try JSONEncoder().encode(metadata), encoding: .utf8)!.contains("Transcripción final lista"))
}

@Test("Un token explícito desconocido no se convierte en un default legacy")
func explicitUnknownMetadataTokensFail() throws {
    func assertUnknown(field: String, value: String, removeCaptureScope: Bool = false) throws {
        let attempt = SessionAttemptID(sessionID: UUID(), generation: 1)
        let metadata = ClassMetadata(
            id: attempt.sessionID,
            subject: "Prueba",
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            duration: 1,
            mode: .inPerson,
            source: "Micrófono",
            professorSpeakerID: nil,
            professorSelectionIsAutomatic: true,
            speakerCount: 0,
            state: .complete,
            folderPath: "/tmp/classscribe",
            technicalVocabulary: "",
            sessionPhase: .complete,
            capturePhase: .idle,
            asrPhase: .idle,
            captureScope: .microphone,
            attemptID: attempt,
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any],
        )
        if removeCaptureScope {
            object.removeValue(forKey: "captureScope")
        }
        object[field] = value
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try JSONDecoder().decode(ClassMetadata.self, from: data)
            #expect(Bool(false), "El token desconocido no debe reinterpretarse")
        } catch let error as SessionMetadataDecodeError {
            #expect(error == .unknownToken(field: field, value: value))
        }
    }

    try assertUnknown(field: "state", value: "future-state")
    try assertUnknown(field: "sessionPhase", value: "future-session-phase")
    try assertUnknown(field: "capturePhase", value: "future-capture-phase")
    try assertUnknown(field: "asrPhase", value: "future-asr-phase")
    try assertUnknown(field: "captureScope", value: "future-scope")
    try assertUnknown(field: "mode", value: "future-mode", removeCaptureScope: true)
}

@Test("Una metadata futura se rechaza sin downgrade")
func futureMetadataIsUnsupportedWithoutRewrite() throws {
    let attempt = SessionAttemptID(sessionID: UUID(), generation: 1)
    let metadata = ClassMetadata(
        id: attempt.sessionID,
        subject: "Futuro",
        startedAt: Date(),
        duration: 0,
        mode: .inPerson,
        source: "Micrófono",
        professorSpeakerID: nil,
        professorSelectionIsAutomatic: true,
        speakerCount: 0,
        state: .complete,
        folderPath: "/tmp/futuro",
        technicalVocabulary: "",
        attemptID: attempt,
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any],
    )
    object["schemaVersion"] = 3
    let data = try JSONSerialization.data(withJSONObject: object)
    do {
        _ = try JSONDecoder().decode(ClassMetadata.self, from: data)
        #expect(Bool(false), "Una metadata futura no debe abrirse como v2")
    } catch let error as SessionMetadataDecodeError {
        #expect(error == .unsupportedSchemaVersion(3))
    }

    let root = try makeSessionStateTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("future", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let metadataURL = folder.appendingPathComponent("metadata.json")
    try data.write(to: metadataURL)
    try Data("texto conservado".utf8).write(to: folder.appendingPathComponent("live-transcript.txt"))
    let before = try Data(contentsOf: metadataURL)
    #expect(SessionStore(root: root).scanSessions().isEmpty)
    #expect(try Data(contentsOf: metadataURL) == before)
}

@Test("Metadata legacy truncada sigue siendo recuperable y de solo lectura")
func truncatedLegacyMetadataRemainsRecoverable() throws {
    let root = try makeSessionStateTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("truncated", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let metadataURL = folder.appendingPathComponent("metadata.json")
    let corruptMetadata = Data("{\"schemaVersion\":1,\"state\":\"recording\"".utf8)
    try corruptMetadata.write(to: metadataURL)
    try WavFile.writeFloat32(
        Array(repeating: Float(0.05), count: 16_000),
        to: folder.appendingPathComponent("source.wav"),
    )
    try Data("texto parcial conservado".utf8).write(to: folder.appendingPathComponent("live-transcript.txt"))

    let summary = try #require(SessionStore(root: root).scanSessions().first)

    #expect(summary.isRecoverable)
    #expect(summary.recoveryReason?.contains("truncada") == true)
    #expect(try Data(contentsOf: metadataURL) == corruptMetadata)
    #expect(summary.preferredTextURL?.lastPathComponent == "live-transcript.txt")
}

@Test("Un token desconocido no se interpreta como metadata legacy")
func unknownMetadataTokenIsUnsupportedWithoutRewrite() throws {
    let root = try makeSessionStateTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("unknown-token", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let metadata = ClassMetadata(
        id: UUID(),
        subject: "Token",
        startedAt: Date(),
        duration: 0,
        mode: .inPerson,
        source: "Micrófono",
        professorSpeakerID: nil,
        professorSelectionIsAutomatic: true,
        speakerCount: 0,
        state: .complete,
        folderPath: folder.path,
        technicalVocabulary: "",
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any],
    )
    object["state"] = "future-state"
    let data = try JSONSerialization.data(withJSONObject: object)
    let metadataURL = folder.appendingPathComponent("metadata.json")
    try data.write(to: metadataURL)
    try Data("texto conservado".utf8).write(to: folder.appendingPathComponent("live-transcript.txt"))

    #expect(SessionStore(root: root).scanSessions().isEmpty)
    #expect(try Data(contentsOf: metadataURL) == data)
}

@Test("Fixture macOS v0.7 abre sin reescribir y aplica defaults legacy")
func macOSLegacyFixtureOpensWithoutRewrite() throws {
    let root = try makeSessionStateTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = legacyFixture("macos-v0.7-online-incomplete")
    let folder = root.appendingPathComponent("macos-v0.7-online-incomplete", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["metadata.json", "all-speakers.json"] {
        try FileManager.default.copyItem(at: fixture.appendingPathComponent(name), to: folder.appendingPathComponent(name))
    }
    let originalMetadata = try Data(contentsOf: folder.appendingPathComponent("metadata.json"))

    let store = SessionStore(root: root)
    let summary = try #require(store.scanSessions().first)
    #expect(summary.metadata.schemaVersion == 1)
    #expect(summary.metadata.language == nil)
    #expect(summary.metadata.effectiveTranscriptionLanguage == .spanish)
    #expect(summary.metadata.mode == .online)
    #expect(summary.metadata.captureScope == .application)
    #expect(summary.metadata.sessionPhase == .recording)
    #expect(summary.metadata.professorSpeakerID == "Persona 0")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("live-transcript.txt").path))
    #expect(try Data(contentsOf: folder.appendingPathComponent("metadata.json")) == originalMetadata)

    let restored = store.restore(summary)
    #expect(restored.allSegments.first?.speakerID == "Persona 0")
    #expect(try Data(contentsOf: folder.appendingPathComponent("metadata.json")) == originalMetadata)
}

@Test("ASR original, propuesta y overlay sobreviven a la proyección diarizada")
func transcriptSourcesRemainSeparated() throws {
    let root = try makeSessionStateTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(root: root)
    let folder = try store.createFolder(subject: "Fuentes", date: Date())
    let sourceURL = folder.appendingPathComponent("source.wav")
    try WavFile.writeFloat32(Array(repeating: 0.1, count: 16_000), to: sourceURL)
    let sourceBefore = try Data(contentsOf: sourceURL)
    let originalSegment = TranscriptSegment(
        start: 0,
        end: 1,
        text: "texto ASR original",
        speakerID: "Persona desconocida",
        confidence: 0,
    )
    let attempt = SessionAttemptID(sessionID: UUID(), generation: 1)
    var metadata = ClassMetadata(
        id: attempt.sessionID,
        subject: "Fuentes",
        startedAt: Date(),
        duration: 1,
        mode: .inPerson,
        source: "Micrófono",
        professorSpeakerID: nil,
        professorSelectionIsAutomatic: true,
        speakerCount: 0,
        state: .diarizing,
        folderPath: folder.path,
        technicalVocabulary: "",
        language: .spanish,
        attemptID: attempt,
    )
    let reference = try store.saveFullTranscript(metadata: metadata, segments: [originalSegment], folder: folder)
    metadata.asrOriginalReference = reference
    let assigned = originalSegment.with(speakerID: "Persona 1", confidence: 0.9)
    let proposal = DiarizationProposal(
        proposalID: UUID(),
        createdAt: Date(),
        engineVersion: "test",
        asrRunID: reference.runID,
        spans: [DiarizationSpan(start: 0, end: 1, speakerID: "Persona 1", quality: 0.9)],
    )
    metadata.state = .complete
    metadata.sessionPhase = .complete
    try store.saveFinal(
        metadata: metadata,
        all: [assigned],
        professor: [assigned],
        review: [],
        speakers: [],
        folder: folder,
        humanCorrection: HumanCorrectionUpdate(
            allText: "corrección humana",
            professorText: "corrección profesor",
        ),
        diarizationProposal: proposal,
    )

    let overlayBefore = try Data(contentsOf: folder.appendingPathComponent("human-correction-overlay.json"))
    let newerAutomatic = assigned.with(speakerID: "Persona 2", confidence: 0.8)
    try store.saveAutomaticProjection(
        metadata: metadata,
        all: [newerAutomatic],
        professor: [newerAutomatic],
        review: [],
        speakers: [],
        folder: folder,
        automaticAllText: "resultado automático nuevo",
        automaticProfessorText: "profesor automático nuevo",
    )
    #expect(try Data(contentsOf: folder.appendingPathComponent("human-correction-overlay.json")) == overlayBefore)
    #expect(try String(contentsOf: folder.appendingPathComponent("all-speakers.txt"), encoding: .utf8) == "corrección humana")
    let projected: [TranscriptSegment] = try JSONDecoder.iso8601.decode(
        [TranscriptSegment].self,
        from: Data(contentsOf: folder.appendingPathComponent("all-speakers.json")),
    )
    #expect(projected.first?.speakerID == "Persona 2")

    let artifact = try JSONDecoder.iso8601.decode(
        ASRTranscriptArtifact.self,
        from: Data(contentsOf: folder.appendingPathComponent(reference.relativePath)),
    )
    #expect(artifact.segments == [originalSegment])
    #expect(try Data(contentsOf: sourceURL) == sourceBefore)
    let overlay = try JSONDecoder.iso8601.decode(
        HumanCorrectionOverlay.self,
        from: Data(contentsOf: folder.appendingPathComponent("human-correction-overlay.json")),
    )
    #expect(overlay.editedAllText == "corrección humana")
    let proposals = try JSONDecoder.iso8601.decode(
        DiarizationProposalDocument.self,
        from: Data(contentsOf: folder.appendingPathComponent("diarization-proposals.json")),
    )
    #expect(proposals.proposals.contains(where: { $0.proposalID == proposal.proposalID }))
    let persistedMetadata = try JSONDecoder.iso8601.decode(
        ClassMetadata.self,
        from: Data(contentsOf: folder.appendingPathComponent("metadata.json")),
    )
    #expect(persistedMetadata.asrOriginalReference == reference)
    #expect(persistedMetadata.diarizationProposalReferences.contains { $0.proposalID == proposal.proposalID })
    #expect(persistedMetadata.humanCorrectionOverlayReference?.relativePath == "human-correction-overlay.json")
}

private func legacyFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/LegacySessions/\(name)", isDirectory: true)
}

private func makeSessionStateTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-state-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private extension TranscriptSegment {
    func with(speakerID: String, confidence: Double) -> TranscriptSegment {
        var copy = self
        copy.speakerID = speakerID
        copy.confidence = confidence
        return copy
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
