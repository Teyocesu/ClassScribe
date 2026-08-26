import Foundation

/// Tracks an audio track's position on a wall-clock timeline anchored to its
/// first captured buffer, so a device-change restart gap becomes silence and the
/// track stays aligned to real time (issue #379 follow-up).
///
/// The capture handler feeds each buffer's *hardware* host-time (jitter-free
/// presentation time, e.g. `AVAudioTime.hostTime` or `AudioTimeStamp.mHostTime`,
/// converted to seconds) and its frame count; the anchor returns how many silent
/// frames to write before that buffer. Using the hardware timestamp — not the
/// callback wall-clock — means continuous capture inserts nothing (the timestamp
/// advances exactly with the audio), while a restart gap, where the timestamp
/// jumps forward, is filled precisely.
///
/// Survives restarts: it is anchored once on the first buffer and never reset, so
/// the gap between the last pre-restart buffer and the first post-restart buffer
/// is bridged automatically. The session owns one instance across source
/// incarnations; each AppAudioCapture generation receives the same reference.
public final class TimelineAnchor: @unchecked Sendable {
    private(set) var rate: Int?
    private var anchorHostSeconds: Double?
    /// Logical durable coverage, not bytes currently emitted by a converter.
    /// A streaming converter may hold look-ahead frames, so physical output
    /// must never be used to infer a wall-clock gap.
    private var logicalFramesWritten = 0

    /// Gaps beyond this are treated as a corrupt timestamp, not a real device
    /// outage: no silence is inserted (the write would be gigabytes of zeros on
    /// the audio thread, and `AVAudioFrameCount` traps past UInt32.max). The
    /// anchor is absolute, so a one-off glitched buffer self-heals on the next
    /// sane timestamp.
    static let maxGapSeconds: Double = 600

    init(rate: Int? = nil) {
        self.rate = rate
    }

    /// Sets the durable frame rate only before the first anchored buffer.
    /// Rebinds must keep using the original master rate.
    func setRateIfUnanchored(_ rate: Int) {
        guard rate > 0, anchorHostSeconds == nil else { return }
        self.rate = rate
    }

    /// Silent frames to insert before a logical source segment that presents
    /// at `hostSeconds`. The segment count is supplied by the session clock,
    /// not by the converter's physically emitted sample count. The first call
    /// sets the anchor and inserts nothing. Never negative — an early/jittered
    /// timestamp just appends.
    func silenceFramesBefore(hostSeconds: Double, logicalFrameCount: Int) -> Int {
        guard let rate, rate > 0 else { return 0 }
        guard let anchor = anchorHostSeconds else {
            anchorHostSeconds = hostSeconds
            logicalFramesWritten += logicalFrameCount
            return 0
        }
        let expected = Int(((hostSeconds - anchor) * Double(rate)).rounded())
        let silence = max(0, expected - logicalFramesWritten)
        guard silence <= Int(Self.maxGapSeconds * Double(rate)) else {
            logicalFramesWritten += logicalFrameCount
            return 0
        }
        logicalFramesWritten += silence + logicalFrameCount
        return silence
    }

    /// Compatibility label for legacy fixed-rate callers. New durable master
    /// callers should use `logicalFrameCount` explicitly.
    func silenceFramesBefore(hostSeconds: Double, frameCount: Int) -> Int {
        silenceFramesBefore(
            hostSeconds: hostSeconds,
            logicalFrameCount: frameCount,
        )
    }

    /// Legacy compatibility hook for callers that account physical frames
    /// directly. The session-owned master path must not call this for a
    /// converter tail: that tail is already included in the logical budget
    /// committed by `silenceFramesBefore(hostSeconds:logicalFrameCount:)`.
    func advance(frames: Int) {
        guard frames > 0 else { return }
        logicalFramesWritten += frames
    }
}
