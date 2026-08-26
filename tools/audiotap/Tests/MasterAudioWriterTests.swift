@testable import AudioTapLib
import Darwin
import Foundation
import XCTest

@available(macOS 14.2, *)
final class MasterAudioWriterTests: XCTestCase {
    func testFirstNonEmptyPcmChoosesMasterFormat() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let writer = fixture.writer

        XCTAssertFalse(try writer.append([], inputRate: 48_000, inputChannels: 2, hostTicks: 0, sourceGeneration: 1))
        XCTAssertNil(writer.format)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifestURL.path))

        XCTAssertTrue(try writer.append(
            [0.25, -0.25],
            inputRate: 44_100,
            inputChannels: 1,
            hostTicks: 0,
            sourceGeneration: 1,
        ))
        XCTAssertEqual(writer.format?.sampleRate, 44_100)
        XCTAssertEqual(writer.format?.channels, 1)
        XCTAssertEqual(writer.framesWritten, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
    }

    func testEmptyCallbackDoesNotChooseMasterFormat() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        XCTAssertFalse(try fixture.writer.append(
            [],
            inputRate: 44_100,
            inputChannels: 2,
            hostTicks: 0,
            sourceGeneration: 1,
        ))
        XCTAssertNil(fixture.writer.format)
        XCTAssertNil(fixture.writer.manifest)
        XCTAssertEqual(fixture.writer.framesWritten, 0)
    }

    func testStaleCallbackCannotChooseMasterFormat() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let gate = CaptureLifecycleGate()
        let generation = try XCTUnwrap(gate.begin())
        gate.cancel()

        if gate.isActive(generation) {
            _ = try fixture.writer.append(
                [0.1, -0.1],
                inputRate: 48_000,
                inputChannels: 2,
                hostTicks: 0,
                sourceGeneration: generation,
            )
        }

        XCTAssertNil(fixture.writer.format)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifestURL.path))
    }

    func testMasterFormatIsImmutableWithinAttempt() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let writer = fixture.writer

        _ = try writer.append(
            [0.1, -0.1, 0.2, -0.2],
            inputRate: 48_000,
            inputChannels: 2,
            hostTicks: 0,
            sourceGeneration: 1,
        )
        _ = try writer.append(
            [0.3, -0.3],
            inputRate: 44_100,
            inputChannels: 1,
            hostTicks: 0,
            sourceGeneration: 2,
        )

        XCTAssertEqual(writer.format?.sampleRate, 48_000)
        XCTAssertEqual(writer.format?.channels, 2)
        XCTAssertEqual(writer.manifest?.conversions.count, 1)
        XCTAssertEqual(writer.manifest?.conversions.first?.outputSampleRate, 48_000)
        XCTAssertEqual(writer.manifest?.conversions.first?.outputChannels, 2)
    }

    func testInputFormatChangeIsConvertedNotConcatenated() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let writer = fixture.writer

        XCTAssertTrue(try writer.append(
            [0.1, -0.1, 0.2, -0.2],
            inputRate: 48_000,
            inputChannels: 2,
            hostTicks: 0,
            sourceGeneration: 1,
        ))
        _ = try writer.append(
            [0.3, -0.3],
            inputRate: 44_100,
            inputChannels: 1,
            hostTicks: 0,
            sourceGeneration: 2,
        )

        try fixture.close()
        let raw = try Data(contentsOf: fixture.masterURL)
        XCTAssertEqual(raw.count, Int(writer.framesWritten) * 2 * MemoryLayout<Float>.size)
        XCTAssertEqual(writer.format?.encoding, "float32LE")
        XCTAssertEqual(writer.manifest?.conversions.count, 1)
    }

    func testMasterDurationDoesNotDependOnAsrDerivativeBytes() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let writer = fixture.writer

        _ = try writer.append(
            [Float](repeating: 0.1, count: 48_000 * 2),
            inputRate: 48_000,
            inputChannels: 2,
            hostTicks: 0,
            sourceGeneration: 1,
        )

        XCTAssertEqual(writer.duration, 1, accuracy: 0.000001)
    }

    func testSourceWavDerivativeIsFixed16kMonoRaw() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let samples = (0 ..< 480).flatMap { _ in [Float(0.1), Float(-0.1)] }
        _ = try fixture.writer.append(
            samples,
            inputRate: 48_000,
            inputChannels: 2,
            hostTicks: 0,
            sourceGeneration: 1,
        )
        XCTAssertEqual(fixture.writer.format?.sampleRate, 48_000)
        XCTAssertEqual(fixture.writer.format?.channels, 2)
        XCTAssertEqual(fixture.writer.format?.encoding, "float32LE")
        try fixture.close()

        let derivativeURL = fixture.folderURL.appendingPathComponent("source.wav")
        let duration = try MasterAudioDerivative.writeFloat32Raw(
            masterURL: fixture.masterURL,
            manifestURL: fixture.manifestURL,
            destinationURL: derivativeURL,
        )

        XCTAssertEqual(duration, 0.01, accuracy: 0.0001)
        XCTAssertEqual(try Data(contentsOf: derivativeURL).count, 160 * MemoryLayout<Float>.size)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.masterURL.path))
    }

    func test44k1MonoInputKeepsItsSourceRate() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try fixture.writer.append(
            [Float](repeating: 0.2, count: 441),
            inputRate: 44_100,
            inputChannels: 1,
            hostTicks: 0,
            sourceGeneration: 1,
        )

        XCTAssertEqual(fixture.writer.format?.sampleRate, 44_100)
        XCTAssertEqual(fixture.writer.format?.channels, 1)
    }

    func testMoreThanTwoChannelsDownmixesToStereoAndRecordsConversion() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try fixture.writer.append(
            [0.1, 0.2, 0.3, 0.4],
            inputRate: 48_000,
            inputChannels: 4,
            hostTicks: 0,
            sourceGeneration: 1,
        )

        XCTAssertEqual(fixture.writer.format?.channels, 2)
        XCTAssertEqual(fixture.writer.manifest?.conversions.first?.inputChannels, 4)
        XCTAssertEqual(fixture.writer.framesWritten, 1)
    }

    private struct Fixture {
        let folderURL: URL
        let masterURL: URL
        let manifestURL: URL
        let handle: FileHandle
        let writer: MasterAudioWriter

        func close() throws {
            try handle.synchronize()
            try handle.close()
        }

        func cleanup() {
            try? handle.close()
            try? FileManager.default.removeItem(at: folderURL)
        }
    }

    private func makeFixture() throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("classscribe-master-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let master = folder.appendingPathComponent("master.raw")
        let manifest = folder.appendingPathComponent("audio-manifest.json")
        guard FileManager.default.createFile(
            atPath: master.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600],
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: master)
        return Fixture(
            folderURL: folder,
            masterURL: master,
            manifestURL: manifest,
            handle: handle,
            writer: MasterAudioWriter(
                outputFileDescriptor: handle.fileDescriptor,
                masterURL: master,
                manifestURL: manifest,
            ),
        )
    }
}
