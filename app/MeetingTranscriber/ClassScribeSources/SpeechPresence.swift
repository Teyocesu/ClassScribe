import FluidAudio
import Foundation

/// A time range where Silero found speech. Ranges remain on the ASR timeline;
/// the audio passed to Parakeet is never trimmed to these ranges.
struct SpeechPresenceRegion: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
}

/// Evidence returned by the speech-presence gate before an ASR hypothesis can
/// be published. It deliberately contains no transcript text.
struct SpeechPresenceEvidence: Equatable, Sendable {
    let regions: [SpeechPresenceRegion]

    var hasVoice: Bool {
        regions.contains { region in
            region.start.isFinite && region.end.isFinite && region.end > region.start
        }
    }

    static let none = SpeechPresenceEvidence(regions: [])
}

/// Applies the conservative acceptance policy after ASR has produced its
/// original segments. A nil evidence value means VAD failed and therefore
/// deliberately preserves every ASR segment (fail-open).
enum SpeechPresenceAcceptancePolicy {
    static let acceptancePadding: TimeInterval = 0.30

    static func intersects(
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval,
        regions: [SpeechPresenceRegion],
        padding: TimeInterval = acceptancePadding,
    ) -> Bool {
        guard segmentStart.isFinite,
              segmentEnd.isFinite,
              segmentEnd >= segmentStart,
              padding.isFinite,
              padding >= 0 else { return false }

        return regions.contains { region in
            guard region.start.isFinite,
                  region.end.isFinite,
                  region.end > region.start else { return false }
            let paddedStart = max(0, region.start - padding)
            let paddedEnd = region.end + padding
            // Inclusive endpoints intentionally keep a hypothesis that lands
            // exactly on a speech/padding boundary.
            return segmentStart <= paddedEnd && segmentEnd >= paddedStart
        }
    }

    static func filterSegments(
        _ segments: [TranscriptSegment],
        evidence: SpeechPresenceEvidence?,
    ) -> [TranscriptSegment] {
        guard let evidence else { return segments }
        guard evidence.hasVoice else { return [] }
        return segments.filter { segment in
            intersects(
                segmentStart: segment.start,
                segmentEnd: segment.end,
                regions: evidence.regions,
            )
        }
    }
}

/// Shared, lazy Silero VAD used by both live windows and final-file ASR.
/// Loading is single-flight. Callers decide whether an error should fail-open;
/// a VAD outage must never prevent the existing ASR path from running.
actor FluidAudioSpeechPresenceDetector {
    private static let vadConfig = VadConfig(defaultThreshold: 0.40)
    private static let segmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0.15,
        minSilenceDuration: 0.30,
        maxSpeechDuration: .infinity,
        speechPadding: 0,
    )

    private let modelLoad = AsyncSingleFlight<VadManager>()

    func prewarm() async throws {
        _ = try await loadedManager()
    }

    func analyze(samples: [Float]) async throws -> SpeechPresenceEvidence {
        guard !samples.isEmpty else { return .none }
        let manager = try await loadedManager()
        let segments = try await manager.segmentSpeech(samples, config: Self.segmentationConfig)
        try Task.checkCancellation()
        return Self.evidence(from: segments)
    }

    func analyze(file: URL) async throws -> SpeechPresenceEvidence {
        let samples = try AudioConverter().resampleAudioFile(file)
        return try await analyze(samples: samples)
    }

    private func loadedManager() async throws -> VadManager {
        try await modelLoad.value {
            try await VadManager(config: Self.vadConfig)
        }
    }

    private static func evidence(from segments: [VadSegment]) -> SpeechPresenceEvidence {
        SpeechPresenceEvidence(
            regions: segments.map { segment in
                SpeechPresenceRegion(
                    start: max(0, segment.startTime),
                    end: max(0, segment.endTime),
                )
            },
        )
    }
}
