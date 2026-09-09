import Foundation
import Testing
@testable import ClassScribe

private let correctionSpeakerA = "Persona 1"
private let correctionSpeakerB = "Persona 2"

private func correctionSpeaker(_ id: String, name: String? = nil, embedding: [Float]? = nil) -> SpeakerRecord {
    SpeakerRecord(
        id: id,
        displayName: name ?? id,
        totalSpeakingTime: 0,
        recentFragments: [],
        confidence: 0.9,
        embedding: embedding,
    )
}

private func correctionSegment(
    _ text: String,
    speakerID: String,
    start: TimeInterval,
    end: TimeInterval,
    id: UUID = UUID(),
    wordTimings: [TranscriptWordTiming]? = nil,
) -> TranscriptSegment {
    TranscriptSegment(
        id: id,
        start: start,
        end: end,
        text: text,
        speakerID: speakerID,
        confidence: 0.9,
        wordTimings: wordTimings,
    )
}

private func correctionOperation(
    kind: SpeakerCorrectionKind,
    speakerID: String? = nil,
    targetSpeakerID: String? = nil,
    segmentIDs: [UUID] = [],
    anchorStart: TimeInterval? = nil,
    anchorEnd: TimeInterval? = nil,
    anchorText: String? = nil,
    splitAfterWordIndex: Int? = nil,
) -> SpeakerCorrectionOperation {
    SpeakerCorrectionOperation(
        id: UUID(),
        kind: kind,
        speakerID: speakerID,
        targetSpeakerID: targetSpeakerID,
        displayName: nil,
        segmentIDs: segmentIDs,
        createdAt: Date(),
        anchorStart: anchorStart,
        anchorEnd: anchorEnd,
        anchorText: anchorText,
        splitAfterWordIndex: splitAfterWordIndex,
    )
}

@Test("Rename and merge preserve identity, text, timing, and embeddings")
func renameAndMergePreserveRawSegmentData() {
    let first = correctionSegment("Hola", speakerID: correctionSpeakerA, start: 0, end: 2)
    let second = correctionSegment("mundo", speakerID: correctionSpeakerB, start: 2, end: 4)
    let overlay = HumanCorrectionOverlay(operations: [
        SpeakerCorrectionOperation(
            id: UUID(),
            kind: .rename,
            speakerID: correctionSpeakerA,
            targetSpeakerID: nil,
            displayName: "Juan",
            segmentIDs: [],
            createdAt: Date(),
        ),
        correctionOperation(
            kind: .merge,
            speakerID: correctionSpeakerB,
            targetSpeakerID: correctionSpeakerA,
        ),
    ])
    let result = SpeakerCorrectionProjection.apply(
        segments: [first, second],
        speakers: [
            correctionSpeaker(correctionSpeakerA, embedding: [1, 0]),
            correctionSpeaker(correctionSpeakerB, embedding: [0, 1]),
        ],
        review: [],
        professorSpeakerID: nil,
        professorSelectionIsAutomatic: true,
        overlay: overlay,
    )

    #expect(result.unresolvedOperationIDs.isEmpty)
    #expect(result.segments.map(\.id) == [first.id, second.id])
    #expect(result.segments.map(\.text) == [first.text, second.text])
    #expect(result.segments.map(\.speakerID) == [correctionSpeakerA, correctionSpeakerA])
    #expect(result.speakers.count == 1)
    #expect(result.speakers[0].displayName == "Juan")
    #expect(result.speakers[0].embedding == [1, 0])
    #expect(result.speakers[0].totalSpeakingTime == 4)
}

@Test("Merge rejects cycles and reassignment changes only one segment")
func mergeCyclesAndSingleSegmentReassignment() {
    let first = correctionSegment("uno", speakerID: correctionSpeakerA, start: 0, end: 1)
    let second = correctionSegment("dos", speakerID: correctionSpeakerB, start: 1, end: 2)
    let merge = correctionOperation(
        kind: .merge,
        speakerID: correctionSpeakerB,
        targetSpeakerID: correctionSpeakerA,
    )
    #expect(!SpeakerCorrectionProjection.canMerge(
        sourceID: correctionSpeakerA,
        targetID: correctionSpeakerB,
        existingOperations: [merge],
        knownSpeakerIDs: [correctionSpeakerA, correctionSpeakerB],
    ))

    let reassignment = correctionOperation(
        kind: .reassign,
        speakerID: correctionSpeakerB,
        targetSpeakerID: correctionSpeakerA,
        segmentIDs: [second.id],
        anchorStart: second.start,
        anchorEnd: second.end,
        anchorText: second.text,
    )
    let result = SpeakerCorrectionProjection.apply(
        segments: [first, second],
        speakers: [
            correctionSpeaker(correctionSpeakerA),
            correctionSpeaker(correctionSpeakerB),
        ],
        review: [],
        professorSpeakerID: nil,
        professorSelectionIsAutomatic: true,
        overlay: HumanCorrectionOverlay(operations: [reassignment]),
    )
    #expect(result.segments.map(\.speakerID) == [correctionSpeakerA, correctionSpeakerA])
    #expect(result.segments[0].id == first.id)
    #expect(result.segments[1].id == second.id)
}

@Test("Merge chains remain idempotent after the intermediate speaker disappears")
func mergeChainsRemainIdempotent() {
    let first = correctionSegment("uno", speakerID: correctionSpeakerA, start: 0, end: 1)
    let second = correctionSegment("dos", speakerID: correctionSpeakerB, start: 1, end: 2)
    let third = correctionSegment("tres", speakerID: "Persona 3", start: 2, end: 3)
    let firstMerge = correctionOperation(
        kind: .merge,
        speakerID: correctionSpeakerA,
        targetSpeakerID: correctionSpeakerB,
    )
    let secondMerge = correctionOperation(
        kind: .merge,
        speakerID: correctionSpeakerB,
        targetSpeakerID: "Persona 3",
    )
    let overlay = HumanCorrectionOverlay(operations: [firstMerge, secondMerge])
    let initial = SpeakerCorrectionProjection.apply(
        segments: [first, second, third],
        speakers: [
            correctionSpeaker(correctionSpeakerA),
            correctionSpeaker(correctionSpeakerB),
            correctionSpeaker("Persona 3"),
        ],
        review: [],
        professorSpeakerID: nil,
        professorSelectionIsAutomatic: true,
        overlay: overlay,
    )
    let reopened = SpeakerCorrectionProjection.apply(
        segments: initial.segments,
        speakers: initial.speakers,
        review: initial.review,
        professorSpeakerID: initial.professorSpeakerID,
        professorSelectionIsAutomatic: initial.professorSelectionIsAutomatic,
        overlay: overlay,
    )
    #expect(initial.unresolvedOperationIDs.isEmpty)
    #expect(reopened.unresolvedOperationIDs.isEmpty)
    #expect(reopened.segments.map(\.speakerID) == ["Persona 3", "Persona 3", "Persona 3"])
}

@Test("Manual professor survives rename and merge")
func manualProfessorSurvivesSpeakerCorrections() {
    let segment = correctionSegment("explicación", speakerID: correctionSpeakerB, start: 0, end: 1)
    let professor = correctionOperation(
        kind: .professorConfirmation,
        speakerID: correctionSpeakerB,
    )
    let merge = correctionOperation(
        kind: .merge,
        speakerID: correctionSpeakerB,
        targetSpeakerID: correctionSpeakerA,
    )
    let rename = SpeakerCorrectionOperation(
        id: UUID(),
        kind: .rename,
        speakerID: correctionSpeakerA,
        targetSpeakerID: nil,
        displayName: "Profesora García",
        segmentIDs: [],
        createdAt: Date(),
    )
    let result = SpeakerCorrectionProjection.apply(
        segments: [segment],
        speakers: [correctionSpeaker(correctionSpeakerA), correctionSpeaker(correctionSpeakerB)],
        review: [],
        professorSpeakerID: correctionSpeakerB,
        professorSelectionIsAutomatic: false,
        overlay: HumanCorrectionOverlay(operations: [professor, merge, rename]),
    )

    #expect(result.professorSpeakerID == correctionSpeakerA)
    #expect(!result.professorSelectionIsAutomatic)
    #expect(result.speakers.first?.displayName == "Profesora García")
}

@Test("Manual split uses real word timings and preserves every word")
func manualSplitPreservesWordTimings() {
    let timings = [
        TranscriptWordTiming(text: "Hola", start: 10, end: 10.5),
        TranscriptWordTiming(text: "cómo", start: 10.6, end: 11),
        TranscriptWordTiming(text: "estás", start: 11.1, end: 11.7),
        TranscriptWordTiming(text: "bien", start: 12, end: 12.4),
        TranscriptWordTiming(text: "gracias", start: 12.5, end: 13),
    ]
    let source = correctionSegment(
        "Hola cómo estás bien gracias",
        speakerID: correctionSpeakerA,
        start: 10,
        end: 13,
        wordTimings: timings,
    )
    let operation = correctionOperation(
        kind: .split,
        speakerID: correctionSpeakerA,
        segmentIDs: [source.id],
        anchorStart: source.start,
        anchorEnd: source.end,
        anchorText: source.text,
        splitAfterWordIndex: 3,
    )
    let result = SpeakerCorrectionProjection.apply(
        segments: [source],
        speakers: [correctionSpeaker(correctionSpeakerA)],
        review: [],
        professorSpeakerID: nil,
        professorSelectionIsAutomatic: true,
        overlay: HumanCorrectionOverlay(operations: [operation]),
    )

    #expect(result.unresolvedOperationIDs.isEmpty)
    #expect(result.segments.count == 2)
    #expect(result.segments.map(\.text).joined(separator: " ") == source.text)
    #expect(result.segments[0].start == 10)
    #expect(result.segments[0].end == 11.7)
    #expect(result.segments[1].start == 12)
    #expect(result.segments[1].end == 13)
    #expect(result.segments.flatMap { $0.wordTimings ?? [] }.map(\.text) == timings.map(\.text))
}

@Test("Reprocessing uses conservative anchors and rejects ambiguity")
func reprocessingUsesConservativeAnchors() {
    let oldID = UUID()
    let newID = UUID()
    let operation = correctionOperation(
        kind: .reassign,
        speakerID: correctionSpeakerA,
        targetSpeakerID: correctionSpeakerB,
        segmentIDs: [oldID],
        anchorStart: 2,
        anchorEnd: 3,
        anchorText: "repetido",
    )
    let reconciled = SpeakerCorrectionProjection.apply(
        segments: [correctionSegment("repetido", speakerID: correctionSpeakerA, start: 2, end: 3, id: newID)],
        speakers: [correctionSpeaker(correctionSpeakerA), correctionSpeaker(correctionSpeakerB)],
        review: [],
        professorSpeakerID: nil,
        professorSelectionIsAutomatic: true,
        overlay: HumanCorrectionOverlay(operations: [operation]),
    )
    #expect(reconciled.unresolvedOperationIDs.isEmpty)
    #expect(reconciled.segments[0].speakerID == correctionSpeakerB)

    var ambiguousOperation = operation
    ambiguousOperation.id = UUID()
    ambiguousOperation.anchorStart = nil
    ambiguousOperation.anchorEnd = nil
    let ambiguous = SpeakerCorrectionProjection.apply(
        segments: [
            correctionSegment("repetido", speakerID: correctionSpeakerA, start: 2, end: 3),
            correctionSegment("repetido", speakerID: correctionSpeakerA, start: 5, end: 6),
        ],
        speakers: [correctionSpeaker(correctionSpeakerA), correctionSpeaker(correctionSpeakerB)],
        review: [],
        professorSpeakerID: nil,
        professorSelectionIsAutomatic: true,
        overlay: HumanCorrectionOverlay(operations: [ambiguousOperation]),
    )
    #expect(ambiguous.unresolvedOperationIDs == [ambiguousOperation.id])
    #expect(ambiguous.segments.allSatisfy { $0.speakerID == correctionSpeakerA })
}

@Test("Legacy overlay decoding and named exports remain compatible")
func legacyOverlayAndNamedExportCompatibility() throws {
    let legacyOverlay = try JSONDecoder().decode(
        HumanCorrectionOverlay.self,
        from: Data(#"{"operations":[]}"#.utf8),
    )
    #expect(legacyOverlay.operations.isEmpty)
    #expect(legacyOverlay.editedAllText == nil)

    let segment = correctionSegment("Texto completo", speakerID: correctionSpeakerA, start: 0, end: 1)
    let exported = TranscriptExporter.plainText([segment], speakerNames: [correctionSpeakerA: "Juan"])
    #expect(exported.contains("Juan"))
    #expect(exported.contains("Texto completo"))
    #expect(SpeakerPresentation.localizedName(
        id: correctionSpeakerA,
        storedDisplayName: "Juan",
        language: .french,
    ) == "Juan")
}

@Test("Human correction overlay is durable across store restore")
func humanCorrectionOverlayRoundTripsThroughSessionStore() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClassScribe.SpeakerCorrections.\(UUID().uuidString)")
    let store = SessionStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = try store.createFolder("Correcciones")
    let segment = correctionSegment("Texto", speakerID: correctionSpeakerA, start: 0, end: 1)
    let speaker = correctionSpeaker(correctionSpeakerA)
    let metadata = ClassMetadata(
        id: UUID(),
        subject: "Correcciones",
        startedAt: Date(),
        duration: 1,
        mode: .inPerson,
        source: "Micrófono",
        professorSpeakerID: correctionSpeakerA,
        professorSelectionIsAutomatic: false,
        speakerCount: 1,
        state: .complete,
        folderPath: folder.path,
        technicalVocabulary: "",
    )
    let operation = SpeakerCorrectionOperation(
        id: UUID(),
        kind: .rename,
        speakerID: correctionSpeakerA,
        targetSpeakerID: nil,
        displayName: "Juan",
        segmentIDs: [],
        createdAt: Date(),
    )
    try store.saveFinal(
        metadata: metadata,
        all: [segment],
        professor: [segment],
        review: [],
        speakers: [speaker],
        folder: folder,
        humanCorrection: HumanCorrectionUpdate(operations: [operation]),
    )

    let summary = try #require(store.scanSessions().first)
    let restored = store.restore(summary)
    #expect(restored.humanCorrectionOverlay?.operations.map(\.id) == [operation.id])
    #expect(restored.allSegments.first?.text == segment.text)
}
