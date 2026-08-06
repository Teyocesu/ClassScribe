import AudioTapLib
@testable import ClassScribe
import Foundation
import Testing

@Test
func invalidWAVFixturesArePreserved() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let empty = folder.appendingPathComponent("empty.wav")
    try Data().write(to: empty)
    let headerOnly = folder.appendingPathComponent("header-only.wav")
    try pcm16WAVHeader(dataBytes: 0).write(to: headerOnly)
    let truncated = folder.appendingPathComponent("truncated.wav")
    try Data("RIFF\0\0\0\0WAVE".utf8).write(to: truncated)

    for url in [empty, headerOnly, truncated] {
        do {
            _ = try WavFile.validate(url)
            Issue.record("Se esperaba rechazo de \(url.lastPathComponent)")
        } catch {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}

@Test
func silentAndContinuousWAVFixtures() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let silence = folder.appendingPathComponent("silence.wav")
    try WavFile.writeFloat32(Array(repeating: 0, count: 16000), to: silence)
    #expect(try abs(WavFile.validate(silence) - 1) < 0.02)

    let continuous = folder.appendingPathComponent("continuous.wav")
    let samples = (0 ..< 32000).map { index in
        Float(sin(2 * .pi * 220 * Double(index) / 16000) * 0.2)
    }
    try WavFile.writeFloat32(samples, to: continuous)
    #expect(try abs(WavFile.validate(continuous) - 2) < 0.02)
}

@Test
func streamingRawWrapPreservesInput() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let raw = folder.appendingPathComponent("source.raw")
    let samples = Array(repeating: Float(0.1), count: 16000)
    let rawData = samples.withUnsafeBytes { Data($0) }
    try rawData.write(to: raw)
    let destination = folder.appendingPathComponent("source.wav")
    try Data("contenido anterior".utf8).write(to: destination)

    try WavFile.wrapFloat32Raw(raw, destination: destination)
    #expect(try abs(WavFile.validate(destination) - 1) < 0.02)
    #expect(try Data(contentsOf: raw) == rawData)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .allSatisfy { !$0.hasSuffix(".tmp") })
}

@Test
func rawRecoveryPreservesEvidence() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let raw = folder.appendingPathComponent("source.raw")
    let samples = Array(repeating: Float(0.08), count: 16000)
    let rawData = samples.withUnsafeBytes { Data($0) }
    try rawData.write(to: raw)
    let destination = folder.appendingPathComponent("source.wav")
    let invalidWAV = Data("WAV incompleto que debe conservarse".utf8)
    try invalidWAV.write(to: destination)

    #expect(try abs(WavFile.recoverFloat32Raw(raw, destination: destination) - 1) < 0.02)
    #expect(try Data(contentsOf: raw) == rawData)
    #expect(try abs(WavFile.validate(destination) - 1) < 0.02)
    let preserved = try FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: nil,
    ).filter { $0.lastPathComponent.hasPrefix("source-invalid-preserved-") }
    #expect(preserved.count == 1)
    let preservedURL = try #require(preserved.first)
    #expect(try Data(contentsOf: preservedURL) == invalidWAV)
    let permissions = try #require(
        FileManager.default.attributesOfItem(atPath: preservedURL.path)[.posixPermissions] as? NSNumber,
    ).intValue & 0o777
    #expect(permissions == 0o600)
}

@Test
func truncatedRawDoesNotReplaceDestination() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let raw = folder.appendingPathComponent("source.raw")
    try Data([0, 1, 2]).write(to: raw)
    let destination = folder.appendingPathComponent("source.wav")
    let original = Data("evidencia WAV".utf8)
    try original.write(to: destination)

    #expect(throws: CaptureError.self) {
        _ = try WavFile.recoverFloat32Raw(raw, destination: destination)
    }
    #expect(try Data(contentsOf: destination) == original)
}

@Test
func symbolicAudioIsRejectedWithoutTouchingItsTarget() throws {
    let folder = try makeAudioValidationFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("outside.wav")
    try WavFile.writeFloat32(Array(repeating: Float(0.1), count: 16000), to: target)
    let original = try Data(contentsOf: target)
    let link = folder.appendingPathComponent("source.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(throws: CaptureError.self) {
        _ = try WavFile.validate(link)
    }

    let raw = folder.appendingPathComponent("source.raw")
    let samples = Array(repeating: Float(0.2), count: 16000)
    try samples.withUnsafeBytes { Data($0) }.write(to: raw)
    #expect(throws: CaptureError.self) {
        _ = try WavFile.recoverFloat32Raw(raw, destination: link)
    }
    #expect(try Data(contentsOf: target) == original)
    #expect((try link.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
}

@Test
func liveAudioGenerationRejectsQueuedBuffersFromPreviousSession() async {
    let store = LiveAudioBufferStore()
    let oldGeneration = await store.reset()
    let newGeneration = await store.reset()
    let buffer = LiveAudioBuffer(
        samples: Array(repeating: Float(0.25), count: 1600),
        channelCount: 1,
        sampleRate: 16000,
        hostTime: 0,
    )

    await store.append(buffer, generation: oldGeneration)
    #expect(await store.totalSamples() == 0)
    await store.append(buffer, generation: newGeneration)
    #expect(await store.totalSamples() == 1600)
}

private func makeAudioValidationFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-audio-validation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

private func pcm16WAVHeader(dataBytes: UInt32) -> Data {
    var bytes: [UInt8] = [
        0x52, 0x49, 0x46, 0x46,
        0, 0, 0, 0,
        0x57, 0x41, 0x56, 0x45,
        0x66, 0x6D, 0x74, 0x20,
        16, 0, 0, 0,
        1, 0,
        1, 0,
        0x80, 0x3E, 0, 0,
        0, 0x7D, 0, 0,
        2, 0,
        16, 0,
        0x64, 0x61, 0x74, 0x61,
        0, 0, 0, 0,
    ]
    let riffSize = UInt32(36) + dataBytes
    withUnsafeBytes(of: riffSize.littleEndian) { bytes.replaceSubrange(4 ..< 8, with: $0) }
    withUnsafeBytes(of: dataBytes.littleEndian) { bytes.replaceSubrange(40 ..< 44, with: $0) }
    return Data(bytes)
}
