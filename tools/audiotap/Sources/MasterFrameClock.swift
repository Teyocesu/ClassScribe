import Foundation

/// Session-owned duration budget for the durable master.
///
/// A converter is allowed to reset its interpolation state when a capture
/// generation or input format changes. This clock deliberately does not reset
/// with it: it accumulates source duration in master-frame units and rounds
/// only the cumulative value. The returned segment budget is therefore the
/// number of master frames assigned to this source segment, including the
/// fractional remainder left by all preceding segments.
@available(macOS 14.2, *)
public final class MasterFrameClock: @unchecked Sendable {
    public let masterRate: Int

    public private(set) var totalInputFrames: Int64 = 0
    public private(set) var exactMasterFrames: Double = 0
    public private(set) var targetSourceFrames: Int64 = 0
    public private(set) var fractionalRemainder: Double = 0

    public init?(masterRate: Int) {
        guard masterRate > 0 else { return nil }
        self.masterRate = masterRate
    }

    /// Reserves the cumulative master-frame budget for one source segment.
    /// The clock is audio-duration state only; explicit handoff silence is
    /// owned by the timeline anchor and is not folded into this source budget.
    @discardableResult
    public func reserveSourceFrames(
        inputFrameCount: Int,
        inputRate: Int,
    ) -> MasterFrameBudget {
        precondition(inputFrameCount >= 0)
        precondition(inputRate > 0)

        let start = targetSourceFrames
        totalInputFrames += Int64(inputFrameCount)
        exactMasterFrames +=
            Double(inputFrameCount) * Double(masterRate) / Double(inputRate)

        // A capture attempt is bounded well below Double's loss of integer
        // precision. Keep the guard explicit so a future long-session change
        // cannot silently wrap the durable frame count.
        precondition(exactMasterFrames < Double(Int64.max))
        let rounded = Int64(exactMasterFrames.rounded(.toNearestOrAwayFromZero))
        targetSourceFrames = max(start, rounded)
        fractionalRemainder = exactMasterFrames - exactMasterFrames.rounded(.down)

        return MasterFrameBudget(
            startFrame: start,
            endFrame: targetSourceFrames,
        )
    }
}

public struct MasterFrameBudget: Sendable, Equatable {
    public let startFrame: Int64
    public let endFrame: Int64

    public var frameCount: Int64 { endFrame - startFrame }
}
