import Foundation

/// Pure policy used by the isolated macOS worker to recognize FluidAudio
/// partitions that have collapsed into one dominant cluster.  Keeping the
/// decision independent of Core ML makes the safety gates deterministic.
public enum DiarizationRecoveryPolicy {
    public static let dominantShareThreshold = 0.85
    public static let probeClusteringThreshold = 0.7

    public struct Metrics: Equatable, Sendable {
        public var speakerCount: Int
        public var dominantShare: Double
        public var speakerChanges: Int
        public var firstMinuteSpeakerCount: Int

        public init(
            speakerCount: Int,
            dominantShare: Double,
            speakerChanges: Int,
            firstMinuteSpeakerCount: Int,
        ) {
            self.speakerCount = speakerCount
            self.dominantShare = dominantShare
            self.speakerChanges = speakerChanges
            self.firstMinuteSpeakerCount = firstMinuteSpeakerCount
        }
    }

    public static func metrics(for spans: [DiarizationWorkerSpan]) -> Metrics {
        let ordered = spans.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
        var durations: [String: TimeInterval] = [:]
        var changes = 0
        var previousSpeaker: String?
        var firstMinuteSpeakers = Set<String>()

        for span in ordered {
            let duration = max(0, span.end - span.start)
            durations[span.speakerID, default: 0] += duration
            if let previousSpeaker, previousSpeaker != span.speakerID {
                changes += 1
            }
            previousSpeaker = span.speakerID
            if span.start < 60, span.end > 0 {
                firstMinuteSpeakers.insert(span.speakerID)
            }
        }

        let total = durations.values.reduce(0, +)
        let dominant = durations.values.max() ?? 0
        return Metrics(
            speakerCount: durations.count,
            dominantShare: total > 0 ? dominant / total : 0,
            speakerChanges: changes,
            firstMinuteSpeakerCount: firstMinuteSpeakers.count,
        )
    }

    /// A single-speaker result is deliberately excluded: there is no engine
    /// evidence for another voice, so recovery must not invent one.
    public static func needsRecovery(_ spans: [DiarizationWorkerSpan]) -> Bool {
        let value = metrics(for: spans)
        return value.speakerCount >= 2 && value.dominantShare > dominantShareThreshold
    }

    /// The probe remains auto-counted.  Its count may be used as an exact
    /// re-clustering target only when it reveals more structure than the
    /// collapsed baseline; no fixed speaker count enters the policy.
    public static func inferredSpeakerCount(
        baseline: [DiarizationWorkerSpan],
        probe: [DiarizationWorkerSpan],
    ) -> Int? {
        let baselineCount = metrics(for: baseline).speakerCount
        let probeCount = metrics(for: probe).speakerCount
        return probeCount > baselineCount ? probeCount : nil
    }

    /// Accept a recovery only when it materially reduces dominance and adds
    /// real temporal alternation.  Prefer first-minute separation when the
    /// baseline missed it, but never accept a candidate with more speakers
    /// than the auto-counted probe.
    public static func shouldUseRecovery(
        baseline: [DiarizationWorkerSpan],
        candidate: [DiarizationWorkerSpan],
        inferredSpeakerCount: Int,
    ) -> Bool {
        let before = metrics(for: baseline)
        let after = metrics(for: candidate)
        guard after.speakerCount >= 2,
              after.speakerCount <= inferredSpeakerCount,
              after.dominantShare < before.dominantShare,
              after.speakerChanges > before.speakerChanges
        else { return false }

        if before.firstMinuteSpeakerCount < 2 {
            return after.firstMinuteSpeakerCount >= 2
        }
        return true
    }
}
