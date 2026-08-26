@testable import AudioTapLib
import Foundation
import Testing

@available(macOS 14.2, *)
@Test
func continuousSameRateCallbacksPreserveExactMasterSamples() throws {
    let fixture = try MasterAudioTestFixture()
    defer { fixture.close() }

    let first = (0 ..< 256).map { Float($0 + 1) / 1_000 }
    let second = (0 ..< 256).map { Float($0 + 257) / 1_000 }
    let start = secondsToMachTicks(1)
    let callbackStep = secondsToMachTicks(Double(256) / 48_000)

    try fixture.writer.append(
        first,
        inputRate: 48_000,
        inputChannels: 1,
        hostTicks: start,
        sourceGeneration: 1,
    )
    try fixture.writer.append(
        second,
        inputRate: 48_000,
        inputChannels: 1,
        hostTicks: start + callbackStep,
        sourceGeneration: 1,
    )
    try fixture.writer.finish()

    #expect(try fixture.readSamples() == first + second)
    #expect(fixture.writer.framesWritten == 512)
    #expect(fixture.writer.frameClock?.targetSourceFrames == 512)
}

@available(macOS 14.2, *)
@Test
func streamingLookaheadIsNotTreatedAsTimelineGap() throws {
    let fixture = try MasterAudioTestFixture()
    defer { fixture.close() }

    let first = [Float](repeating: 0.25, count: 256)
    let second = [Float](repeating: 0.5, count: 256)
    let start = secondsToMachTicks(2)
    let callbackStep = secondsToMachTicks(Double(256) / 48_000)

    try fixture.writer.append(
        first,
        inputRate: 48_000,
        inputChannels: 1,
        hostTicks: start,
        sourceGeneration: 1,
    )
    try fixture.writer.append(
        second,
        inputRate: 48_000,
        inputChannels: 1,
        hostTicks: start + callbackStep,
        sourceGeneration: 1,
    )
    try fixture.writer.finish()

    let samples = try fixture.readSamples()
    #expect(samples.count == 512)
    #expect(samples.allSatisfy { $0 == 0.25 || $0 == 0.5 })
    #expect(!samples.contains(0))
}

@available(macOS 14.2, *)
@Test
func realHandoffGapStillInsertsExpectedSilence() throws {
    let fixture = try MasterAudioTestFixture()
    defer { fixture.close() }

    let first = [Float](repeating: 0.2, count: 256)
    let second = [Float](repeating: 0.4, count: 256)
    let firstTicks = secondsToMachTicks(3)
    let secondTicks = firstTicks + secondsToMachTicks(
        Double(256) / 48_000 + 0.05,
    )

    try fixture.writer.append(
        first,
        inputRate: 48_000,
        inputChannels: 1,
        hostTicks: firstTicks,
        sourceGeneration: 1,
    )
    try fixture.writer.append(
        second,
        inputRate: 48_000,
        inputChannels: 1,
        hostTicks: secondTicks,
        sourceGeneration: 2,
    )
    try fixture.writer.finish()

    let gapFrames = max(
        0,
        Int((machTicksToSeconds(secondTicks - firstTicks) * 48_000).rounded()) - 256,
    )
    let samples = try fixture.readSamples()
    #expect(gapFrames > 0)
    #expect(samples.count == 512 + gapFrames)
    #expect(Array(samples[256 ..< (256 + gapFrames)]) == [Float](repeating: 0, count: gapFrames))
    #expect(Array(samples[(256 + gapFrames) ..< samples.count]) == second)
}

@available(macOS 14.2, *)
@Test
func tenZeroGapGenerationsKeepGlobalDurationWithinOneMasterFrame() throws {
    let fixture = try MasterAudioTestFixture()
    defer { fixture.close() }

    try fixture.writer.append(
        [0.1],
        inputRate: 48_000,
        inputChannels: 1,
        hostTicks: 0,
        sourceGeneration: 1,
    )
    for generation in 0 ..< 10 {
        try fixture.writer.append(
            [Float](repeating: Float(generation + 1) / 20, count: 256),
            inputRate: 44_100,
            inputChannels: 1,
            hostTicks: 0,
            sourceGeneration: UInt64(generation + 2),
        )
        try fixture.writer.finish()
    }

    let ideal = 1 + (2_560.0 * 48_000 / 44_100)
    let target = fixture.writer.frameClock?.targetSourceFrames ?? 0
    #expect(abs(Double(fixture.writer.framesWritten) - ideal) <= 1)
    #expect(fixture.writer.framesWritten == target)
    #expect(fixture.writer.framesWritten != 1 + (279 * 10))
}

@available(macOS 14.2, *)
@Test
func formatChangesKeepGlobalRoundingRemainder() throws {
    let fixture = try MasterAudioTestFixture()
    defer { fixture.close() }

    try fixture.writer.append(
        [0.1],
        inputRate: 48_000,
        inputChannels: 1,
        hostTicks: 0,
        sourceGeneration: 1,
    )
    for generation in 0 ..< 10 {
        let inputRate = generation.isMultiple(of: 2) ? 44_100 : 48_000
        try fixture.writer.append(
            [Float](repeating: 0.1, count: 256),
            inputRate: inputRate,
            inputChannels: 1,
            hostTicks: 0,
            sourceGeneration: UInt64(generation + 2),
        )
        try fixture.writer.finish()
    }

    let ideal = 1 + (5 * 256.0 * 48_000 / 44_100) + (5 * 256.0)
    #expect(abs(Double(fixture.writer.framesWritten) - ideal) <= 1)
    #expect(fixture.writer.framesWritten == fixture.writer.frameClock?.targetSourceFrames)
}

@available(macOS 14.2, *)
@Test
func flushTailIsAccountedExactlyOnce() throws {
    let fixture = try MasterAudioTestFixture()
    defer { fixture.close() }

    try fixture.writer.append(
        [0.1],
        inputRate: 48_000,
        inputChannels: 1,
        hostTicks: 0,
        sourceGeneration: 1,
    )
    try fixture.writer.append(
        [Float](repeating: 0.3, count: 256),
        inputRate: 44_100,
        inputChannels: 1,
        hostTicks: 0,
        sourceGeneration: 2,
    )
    try fixture.writer.finish()
    let framesAfterFirstFinish = fixture.writer.framesWritten
    let bytesAfterFirstFinish = try fixture.masterURL.resourceValues(forKeys: [.fileSizeKey]).fileSize

    try fixture.writer.finish()

    #expect(fixture.writer.framesWritten == framesAfterFirstFinish)
    #expect(try fixture.masterURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == bytesAfterFirstFinish)
    #expect(fixture.writer.framesWritten == fixture.writer.frameClock?.targetSourceFrames)
}

@available(macOS 14.2, *)
@Test
func multipleDeviceRestartsDoNotAccumulateOneFramePerRestart() throws {
    let fixture = try MasterAudioTestFixture()
    defer { fixture.close() }

    for generation in 0 ..< 10 {
        try fixture.writer.append(
            [Float](repeating: 0.2, count: 256),
            inputRate: 48_000,
            inputChannels: 1,
            hostTicks: secondsToMachTicks(Double(generation * 256) / 48_000),
            sourceGeneration: UInt64(generation + 1),
        )
        try fixture.writer.finish()
    }

    let samples = try fixture.readSamples()
    #expect(samples.count == 2_560)
    #expect(samples.allSatisfy { $0 == 0.2 })
    #expect(fixture.writer.framesWritten == 2_560)
}

@available(macOS 14.2, *)
private final class MasterAudioTestFixture {
    let folder: URL
    let masterURL: URL
    let manifestURL: URL
    let handle: FileHandle
    let writer: MasterAudioWriter

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("classscribe-master-composition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: false,
        )
        masterURL = folder.appendingPathComponent("master.raw")
        manifestURL = folder.appendingPathComponent("audio-manifest.json")
        guard FileManager.default.createFile(
            atPath: masterURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600],
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: masterURL)
        writer = MasterAudioWriter(
            outputFileDescriptor: handle.fileDescriptor,
            masterURL: masterURL,
            manifestURL: manifestURL,
        )
    }

    func readSamples() throws -> [Float] {
        try handle.synchronize()
        let data = try Data(contentsOf: masterURL)
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data.withUnsafeBytes { rawBuffer in
            rawBuffer.bindMemory(to: UInt32.self).map {
                Float(bitPattern: UInt32(littleEndian: $0))
            }
        }
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
        try? FileManager.default.removeItem(at: folder)
    }
}
