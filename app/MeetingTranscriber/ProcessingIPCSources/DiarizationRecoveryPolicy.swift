import Foundation

/// Pure policy used by the isolated macOS worker to recognize FluidAudio
/// partitions that have collapsed into one dominant cluster.  Keeping the
/// decision independent of Core ML makes the safety gates deterministic.
public enum DiarizationRecoveryPolicy {
    public static let dominantShareThreshold = 0.85
    public static let probeClusteringThreshold = 0.7
    public static let minimumSingleSpeakerSpeechDuration: TimeInterval = 30
    public static let maximumProbeSpeakerCount = 8
    public static let maximumProbeDominantShare = 0.80
    public static let minimumProbeSpeakerChanges = 3
    public static let minimumProbeChangeCoverage = 0.35

    public struct Metrics: Equatable, Sendable {
        public var speakerCount: Int
        public var dominantShare: Double
        public var speakerChanges: Int
        public var firstMinuteSpeakerCount: Int
        public var totalSpeechDuration: TimeInterval
        public var changeCoverage: Double

        public init(
            speakerCount: Int,
            dominantShare: Double,
            speakerChanges: Int,
            firstMinuteSpeakerCount: Int,
            totalSpeechDuration: TimeInterval,
            changeCoverage: Double,
        ) {
            self.speakerCount = speakerCount
            self.dominantShare = dominantShare
            self.speakerChanges = speakerChanges
            self.firstMinuteSpeakerCount = firstMinuteSpeakerCount
            self.totalSpeechDuration = totalSpeechDuration
            self.changeCoverage = changeCoverage
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
        var changeTimes: [TimeInterval] = []

        for span in ordered {
            let duration = max(0, span.end - span.start)
            durations[span.speakerID, default: 0] += duration
            if let previousSpeaker, previousSpeaker != span.speakerID {
                changes += 1
                changeTimes.append(span.start)
            }
            previousSpeaker = span.speakerID
            if span.start < 60, span.end > 0 {
                firstMinuteSpeakers.insert(span.speakerID)
            }
        }

        let total = durations.values.reduce(0, +)
        let dominant = durations.values.max() ?? 0
        let timelineDuration = max(0, (ordered.last?.end ?? 0) - (ordered.first?.start ?? 0))
        let changeCoverage: Double
        if let firstChange = changeTimes.first,
           let lastChange = changeTimes.last,
           timelineDuration > 0 {
            changeCoverage = max(0, lastChange - firstChange) / timelineDuration
        } else {
            changeCoverage = 0
        }
        return Metrics(
            speakerCount: durations.count,
            dominantShare: total > 0 ? dominant / total : 0,
            speakerChanges: changes,
            firstMinuteSpeakerCount: firstMinuteSpeakers.count,
            totalSpeechDuration: total,
            changeCoverage: changeCoverage,
        )
    }

    /// A long single-speaker result may now run the auto-counted probe, but it
    /// cannot select a recovery until that independent probe supplies strong,
    /// distributed multi-speaker evidence. Short monologues avoid the extra
    /// model passes altogether.
    public static func needsRecovery(_ spans: [DiarizationWorkerSpan]) -> Bool {
        let value = metrics(for: spans)
        if value.speakerCount == 1 {
            return value.totalSpeechDuration >= minimumSingleSpeakerSpeechDuration
        }
        return value.speakerCount >= 2 && value.dominantShare > dominantShareThreshold
    }

    /// The probe remains auto-counted.  Its count may be used as an exact
    /// re-clustering target only when it reveals more structure than the
    /// collapsed baseline; no fixed speaker count enters the policy.
    public static func inferredSpeakerCount(
        baseline: [DiarizationWorkerSpan],
        probe: [DiarizationWorkerSpan],
    ) -> Int? {
        let before = metrics(for: baseline)
        let after = metrics(for: probe)
        guard after.speakerCount > before.speakerCount else { return nil }
        if before.speakerCount == 1 {
            guard before.totalSpeechDuration >= minimumSingleSpeakerSpeechDuration,
                  (2 ... maximumProbeSpeakerCount).contains(after.speakerCount),
                  after.dominantShare <= maximumProbeDominantShare,
                  after.speakerChanges >= max(minimumProbeSpeakerChanges, after.speakerCount - 1),
                  after.changeCoverage >= minimumProbeChangeCoverage
            else { return nil }
        }
        return after.speakerCount
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

        if before.speakerCount == 1 {
            guard after.dominantShare <= maximumProbeDominantShare,
                  after.speakerChanges >= minimumProbeSpeakerChanges,
                  after.changeCoverage >= minimumProbeChangeCoverage
            else { return false }
        }

        if before.firstMinuteSpeakerCount < 2 {
            return after.firstMinuteSpeakerCount >= 2
        }
        return true
    }
}
