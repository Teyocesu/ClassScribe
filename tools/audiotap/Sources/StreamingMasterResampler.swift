/// Stateful linear converter for the durable source-rate master.
///
/// The converter keeps one source stream's phase and frame counters across
/// callbacks. It waits for one source frame of look-ahead before interpolating
/// and emits the final held frame from `finish()`. That makes a ramp split into
/// callbacks produce the same samples as one block while still preserving the
/// cumulative rational frame count. A new instance is required for a new input
/// format or source generation; its state must never cross a handoff gap.
@available(macOS 14.2, *)
public final class StreamingMasterResampler: @unchecked Sendable {
    public let inputRate: Int
    public let inputChannels: Int
    public let outputRate: Int
    public let outputChannels: Int

    public private(set) var totalInputFrames: Int64 = 0
    public private(set) var totalOutputFrames: Int64 = 0
    /// Fractional source-frame position of the next output frame.
    public private(set) var fractionalPhase: Double = 0

    private var buffer: [Float] = []
    private var bufferStartFrame: Int64 = 0
    private var previousFrame: [Float]
    private var lastInputFrame: [Float]
    private var hasInput = false
    private var finished = false

    public init?(
        inputRate: Int,
        inputChannels: Int,
        outputRate: Int,
        outputChannels: Int,
    ) {
        guard inputRate > 0, inputChannels > 0,
              outputRate > 0, (1 ... 2).contains(outputChannels)
        else { return nil }
        self.inputRate = inputRate
        self.inputChannels = inputChannels
        self.outputRate = outputRate
        self.outputChannels = outputChannels
        previousFrame = [Float](repeating: 0, count: outputChannels)
        lastInputFrame = [Float](repeating: 0, count: outputChannels)
        buffer.reserveCapacity(outputChannels * 512)
    }

    /// Appends one interleaved callback. An incomplete trailing frame is
    /// ignored, matching the existing PCM callback boundary behavior.
    ///
    /// `targetOutputFrames` is the cumulative budget assigned by the
    /// session-owned `MasterFrameClock`. Leaving it nil retains the
    /// converter-local rational budget for callers that use this primitive in
    /// isolation.
    public func process(
        _ samples: [Float],
        targetOutputFrames: Int64? = nil,
    ) -> [Float] {
        guard !finished, !samples.isEmpty else { return [] }
        let inputFrameCount = samples.count / inputChannels
        guard inputFrameCount > 0 else { return [] }

        for frame in 0 ..< inputFrameCount {
            appendNormalizedFrame(samples, frame: frame)
        }
        totalInputFrames += Int64(inputFrameCount)

        // Equal-rate input needs no temporal lookahead. Returning every
        // normalized frame here keeps converter latency separate from the
        // hardware timeline and makes continuous callbacks byte-exact.
        if inputRate == outputRate {
            let output = buffer
            buffer.removeAll(keepingCapacity: true)
            bufferStartFrame = totalInputFrames
            previousFrame = lastInputFrame
            totalOutputFrames += Int64(inputFrameCount)
            fractionalPhase = 0
            return output
        }

        return emitAvailable(
            final: false,
            targetFrames: targetOutputFrames,
        )
    }

    /// Drains the deterministic tail for this source stream. The final input
    /// frame is held only for output positions that cannot have a look-ahead
    /// frame; no state is retained after this call.
    public func finish(targetOutputFrames: Int64? = nil) -> [Float] {
        guard !finished else { return [] }
        finished = true
        if inputRate == outputRate {
            return []
        }
        return emitAvailable(
            final: true,
            targetFrames: targetOutputFrames,
        )
    }

    private func appendNormalizedFrame(_ samples: [Float], frame: Int) {
        let source = frame * inputChannels
        if outputChannels == 1 {
            var sum: Float = 0
            for channel in 0 ..< inputChannels {
                sum += Self.sanitize(samples[source + channel])
            }
            let value = sum / Float(inputChannels)
            buffer.append(value)
            lastInputFrame[0] = value
        } else if inputChannels == 1 {
            let value = Self.sanitize(samples[source])
            buffer.append(value)
            buffer.append(value)
            lastInputFrame[0] = value
            lastInputFrame[1] = value
        } else if inputChannels == 2 {
            let left = Self.sanitize(samples[source])
            let right = Self.sanitize(samples[source + 1])
            buffer.append(left)
            buffer.append(right)
            lastInputFrame[0] = left
            lastInputFrame[1] = right
        } else {
            var left: Float = 0
            var right: Float = 0
            var leftCount = 0
            var rightCount = 0
            for channel in 0 ..< inputChannels {
                let value = Self.sanitize(samples[source + channel])
                if channel.isMultiple(of: 2) {
                    left += value
                    leftCount += 1
                } else {
                    right += value
                    rightCount += 1
                }
            }
            let normalizedLeft = left / Float(max(leftCount, 1))
            let normalizedRight = right / Float(max(rightCount, 1))
            buffer.append(normalizedLeft)
            buffer.append(normalizedRight)
            lastInputFrame[0] = normalizedLeft
            lastInputFrame[1] = normalizedRight
        }
        hasInput = true
    }

    private func emitAvailable(final: Bool, targetFrames: Int64?) -> [Float] {
        guard hasInput else { return [] }
        let target = targetFrames ?? roundedRatio(totalInputFrames)
        guard target >= totalOutputFrames else {
            updatePhase()
            compactBuffer()
            return []
        }
        guard totalOutputFrames < target else {
            updatePhase()
            compactBuffer()
            return []
        }

        let remainingFrames = target - totalOutputFrames
        var output = [Float]()
        output.reserveCapacity(Int(remainingFrames) * outputChannels)

        while totalOutputFrames < target {
            let positionNumerator = totalOutputFrames * Int64(inputRate)
            let lower = positionNumerator / Int64(outputRate)
            guard lower < totalInputFrames else { break }
            let upper = lower + 1
            if !final, upper >= totalInputFrames {
                break
            }

            let remainder = positionNumerator % Int64(outputRate)
            let fraction = Float(remainder) / Float(outputRate)
            for channel in 0 ..< outputChannels {
                let first = sample(frame: lower, channel: channel)
                let second = upper < totalInputFrames
                    ? sample(frame: upper, channel: channel)
                    : lastInputFrame[channel]
                output.append(Self.sanitize(first + ((second - first) * fraction)))
            }
            totalOutputFrames += 1
        }

        updatePhase()
        compactBuffer()
        return output
    }

    private func sample(frame: Int64, channel: Int) -> Float {
        if frame < bufferStartFrame {
            return previousFrame[channel]
        }
        let offset = Int(frame - bufferStartFrame) * outputChannels + channel
        guard offset >= 0, offset < buffer.count else {
            return lastInputFrame[channel]
        }
        return buffer[offset]
    }

    private func compactBuffer() {
        guard hasInput, !buffer.isEmpty else { return }
        let nextPositionNumerator = totalOutputFrames * Int64(inputRate)
        let nextLower = nextPositionNumerator / Int64(outputRate)
        let lastFrame = max(0, totalInputFrames - 1)
        let keepFrom = min(max(0, nextLower), lastFrame)
        let framesToDrop = keepFrom - bufferStartFrame
        guard framesToDrop > 0 else { return }

        let samplesToDrop = Int(framesToDrop) * outputChannels
        previousFrame = Array(buffer[(samplesToDrop - outputChannels) ..< samplesToDrop])
        buffer.removeFirst(samplesToDrop)
        bufferStartFrame = keepFrom
    }

    private func updatePhase() {
        let remainder = (totalOutputFrames * Int64(inputRate)) % Int64(outputRate)
        fractionalPhase = Double(remainder) / Double(outputRate)
    }

    private func roundedRatio(_ inputFrames: Int64) -> Int64 {
        let numerator = inputFrames * Int64(outputRate)
        let denominator = Int64(inputRate)
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        return quotient + (remainder * 2 >= denominator ? 1 : 0)
    }

    private static func sanitize(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }
}
