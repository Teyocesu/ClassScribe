@testable import AudioTapLib
import XCTest

@available(macOS 14.2, *)
final class StreamingMasterResamplerTests: XCTestCase {
    func test44100To48000TracksRationalCountAcrossTenThousandCallbacks() throws {
        let converter = try XCTUnwrap(
            StreamingMasterResampler(
                inputRate: 44_100,
                inputChannels: 1,
                outputRate: 48_000,
                outputChannels: 1,
            ),
        )
        var outputFrames: Int64 = 0
        var firstPhase: Double?
        var secondPhase: Double?

        for callback in 0 ..< 10_000 {
            outputFrames += Int64(
                converter.process([Float](repeating: 0.25, count: 256)).count,
            )
            if callback == 0 {
                firstPhase = converter.fractionalPhase
            } else if callback == 1 {
                secondPhase = converter.fractionalPhase
            }
        }
        outputFrames += Int64(converter.finish().count)

        let expected = roundedRatio(
            inputFrames: 10_000 * 256,
            inputRate: 44_100,
            outputRate: 48_000,
        )
        let firstPhase = try XCTUnwrap(firstPhase)
        let secondPhase = try XCTUnwrap(secondPhase)
        XCTAssertEqual(outputFrames, converter.totalOutputFrames)
        XCTAssertLessThanOrEqual(abs(outputFrames - expected), 1)
        XCTAssertNotEqual(firstPhase, 0, accuracy: 0.000000000001)
        XCTAssertNotEqual(firstPhase, secondPhase, accuracy: 0.000000000001)
    }

    func test48000To44100TracksRationalCountAcrossTenThousandCallbacks() throws {
        let converter = try XCTUnwrap(
            StreamingMasterResampler(
                inputRate: 48_000,
                inputChannels: 1,
                outputRate: 44_100,
                outputChannels: 1,
            ),
        )
        var outputFrames: Int64 = 0

        for _ in 0 ..< 10_000 {
            outputFrames += Int64(
                converter.process([Float](repeating: -0.25, count: 127)).count,
            )
        }
        outputFrames += Int64(converter.finish().count)

        let expected = roundedRatio(
            inputFrames: 10_000 * 127,
            inputRate: 48_000,
            outputRate: 44_100,
        )
        XCTAssertEqual(outputFrames, converter.totalOutputFrames)
        XCTAssertLessThanOrEqual(abs(outputFrames - expected), 1)
    }

    func testAlternatingCallbackSizesKeepsCumulativeCount() throws {
        let converter = try XCTUnwrap(
            StreamingMasterResampler(
                inputRate: 44_100,
                inputChannels: 1,
                outputRate: 48_000,
                outputChannels: 1,
            ),
        )
        let callbackSizes = [127, 256, 511]
        var inputFrames: Int64 = 0
        var outputFrames: Int64 = 0

        for callback in 0 ..< 3_000 {
            let size = callbackSizes[callback % callbackSizes.count]
            inputFrames += Int64(size)
            outputFrames += Int64(
                converter.process([Float](repeating: 0.1, count: size)).count,
            )
        }
        outputFrames += Int64(converter.finish().count)

        let expected = roundedRatio(
            inputFrames: inputFrames,
            inputRate: 44_100,
            outputRate: 48_000,
        )
        XCTAssertEqual(converter.totalInputFrames, inputFrames)
        XCTAssertEqual(outputFrames, converter.totalOutputFrames)
        XCTAssertLessThanOrEqual(abs(outputFrames - expected), 1)
    }

    func testRampSplitAcrossCallbacksMatchesOneBlockAndStaysContinuous() throws {
        let inputRate = 44_100
        let outputRate = 48_000
        let ramp = (0 ..< 4_096).map { Float($0) / 4_096 }
        let oneBlock = try output(
            ramp,
            inputRate: inputRate,
            outputRate: outputRate,
            callbackSizes: [ramp.count],
        )
        let split = try output(
            ramp,
            inputRate: inputRate,
            outputRate: outputRate,
            callbackSizes: [127, 256, 511, 89],
        )

        XCTAssertEqual(split.count, oneBlock.count)
        let maximumSplitError = zip(split, oneBlock)
            .map { abs($0 - $1) }
            .max() ?? 0
        XCTAssertLessThan(maximumSplitError, 0.00002)

        let maximumBoundaryDelta = zip(split.dropFirst(), split)
            .map { abs($0 - $1) }
            .max() ?? 0
        XCTAssertLessThan(maximumBoundaryDelta, 0.002)
    }

    private func output(
        _ samples: [Float],
        inputRate: Int,
        outputRate: Int,
        callbackSizes: [Int],
    ) throws -> [Float] {
        let converter = try XCTUnwrap(
            StreamingMasterResampler(
                inputRate: inputRate,
                inputChannels: 1,
                outputRate: outputRate,
                outputChannels: 1,
            ),
        )
        var result: [Float] = []
        var offset = 0
        var callback = 0
        while offset < samples.count {
            let requested = callbackSizes[callback % callbackSizes.count]
            let count = min(requested, samples.count - offset)
            result += converter.process(Array(samples[offset ..< (offset + count)]))
            offset += count
            callback += 1
        }
        result += converter.finish()
        XCTAssertEqual(Int64(result.count), converter.totalOutputFrames)
        return result
    }

    private func roundedRatio(
        inputFrames: Int64,
        inputRate: Int,
        outputRate: Int,
    ) -> Int64 {
        let numerator = inputFrames * Int64(outputRate)
        let denominator = Int64(inputRate)
        return numerator / denominator
            + ((numerator % denominator) * 2 >= denominator ? 1 : 0)
    }
}
