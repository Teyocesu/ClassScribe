import ClassScribeProcessingIPC
import Foundation
import Testing

@Test("Un monólogo corto no se prueba y uno largo no inventa speakers")
func singleSpeakerProbeDoesNotInventSpeakers() {
    let shortMonologue = [span(0, 20, "S1")]
    let longMonologue = [
        span(0, 40, "S1"),
        span(42, 82, "S1"),
    ]
    let singleSpeakerProbe = [
        span(0, 38, "S1"),
        span(42, 80, "S1"),
    ]

    #expect(!DiarizationRecoveryPolicy.needsRecovery(shortMonologue))
    #expect(DiarizationRecoveryPolicy.needsRecovery(longMonologue))
    #expect(DiarizationRecoveryPolicy.inferredSpeakerCount(
        baseline: longMonologue,
        probe: singleSpeakerProbe,
    ) == nil)
}

@Test("Un baseline único acepta evidencia multihablante fuerte y distribuida")
func singleSpeakerCollapseAcceptsStrongProbe() throws {
    let baseline = [span(0, 100, "S1")]
    let probe = [
        span(0, 20, "S1"), span(20, 40, "S2"),
        span(40, 60, "S3"), span(60, 80, "S1"),
        span(80, 100, "S4"),
    ]

    let inferred = DiarizationRecoveryPolicy.inferredSpeakerCount(
        baseline: baseline,
        probe: probe,
    )
    #expect(inferred == 4)
    #expect(DiarizationRecoveryPolicy.shouldUseRecovery(
        baseline: baseline,
        candidate: probe,
        inferredSpeakerCount: try #require(inferred),
    ))
}

@Test("Fragmentación débil y tardía no recupera un baseline único")
func singleSpeakerCollapseRejectsWeakProbe() {
    let baseline = [span(0, 100, "S1")]
    let weakProbe = [
        span(0, 90, "S1"), span(90, 92, "S2"),
        span(92, 94, "S3"), span(94, 96, "S2"),
        span(96, 100, "S1"),
    ]

    #expect(DiarizationRecoveryPolicy.inferredSpeakerCount(
        baseline: baseline,
        probe: weakProbe,
    ) == nil)
}

@Test("Una partición multihablante colapsada activa la recuperación")
func dominantMultiSpeakerPartitionTriggersRecovery() {
    let spans = [
        span(0, 90, "S1"),
        span(95, 100, "S2"),
    ]

    let metrics = DiarizationRecoveryPolicy.metrics(for: spans)
    #expect(metrics.speakerCount == 2)
    #expect(abs(metrics.dominantShare - 90.0 / 95.0) < 0.000_001)
    #expect(DiarizationRecoveryPolicy.needsRecovery(spans))
}

@Test("El conteo inferido es dinámico y exige más estructura")
func probeCountStaysDynamicAndMustRevealMoreStructure() {
    let baseline = [span(0, 90, "S1"), span(95, 100, "S2")]
    let richerProbe = [
        span(0, 20, "S1"), span(21, 40, "S2"),
        span(41, 60, "S3"), span(61, 80, "S4"),
    ]
    let unchangedProbe = [span(0, 40, "S1"), span(41, 80, "S2")]

    #expect(DiarizationRecoveryPolicy.inferredSpeakerCount(
        baseline: baseline,
        probe: richerProbe,
    ) == 4)
    #expect(DiarizationRecoveryPolicy.inferredSpeakerCount(
        baseline: baseline,
        probe: unchangedProbe,
    ) == nil)
}

@Test("La recuperación exige cambios distribuidos y separación temprana")
func recoveryRequiresDistributedChangesAndFirstMinuteSeparation() {
    let baseline = [span(0, 90, "S1"), span(95, 100, "S2")]
    let recovered = [
        span(0, 20, "S1"), span(20, 40, "S2"),
        span(40, 60, "S1"), span(60, 80, "S3"),
        span(80, 100, "S4"),
    ]
    let stillCollapsedEarly = [
        span(0, 60, "S1"), span(60, 75, "S2"),
        span(75, 90, "S3"), span(90, 100, "S4"),
    ]

    #expect(DiarizationRecoveryPolicy.shouldUseRecovery(
        baseline: baseline,
        candidate: recovered,
        inferredSpeakerCount: 4,
    ))
    #expect(!DiarizationRecoveryPolicy.shouldUseRecovery(
        baseline: baseline,
        candidate: stillCollapsedEarly,
        inferredSpeakerCount: 4,
    ))
}

private func span(
    _ start: TimeInterval,
    _ end: TimeInterval,
    _ speaker: String,
) -> DiarizationWorkerSpan {
    DiarizationWorkerSpan(start: start, end: end, speakerID: speaker, quality: 1)
}
