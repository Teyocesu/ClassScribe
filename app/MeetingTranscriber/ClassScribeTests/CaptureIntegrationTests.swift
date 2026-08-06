@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import ClassScribe

@MainActor
@Test(
    "CATap captura únicamente el proceso reproductor y produce WAV audible",
    .enabled(if: ProcessInfo.processInfo.environment["CLASSSCRIBE_RUN_APP_CAPTURE_TEST"] == "1")
)
func applicationCaptureFixture() async throws {
    guard let fixture = ProcessInfo.processInfo.environment["CLASSSCRIBE_TEST_AUDIO"] else {
        Issue.record("Falta CLASSSCRIBE_TEST_AUDIO")
        return
    }
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClassScribe-AppCapture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let player = Process()
    player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    player.arguments = [fixture]
    try player.run()
    defer { if player.isRunning { player.terminate() } }

    let controller = CaptureController()
    let source = RunningApplication(
        id: player.processIdentifier,
        name: "ClassScribe fixture player",
        bundleIdentifier: "",
        bundleURL: nil
    )
    _ = try await controller.start(mode: .online, application: source, microphone: nil, folder: folder)
    try await Task.sleep(for: .seconds(6))
    let result = try await controller.stop()
    #expect(result.duration > 4)
    #expect(try rms(of: result.url) > 0.002)
    #expect(player.processIdentifier != ProcessInfo.processInfo.processIdentifier)
}

@MainActor
@Test(
    "Micrófono autorizado mantiene captura y produce WAV",
    .enabled(if: ProcessInfo.processInfo.environment["CLASSSCRIBE_RUN_MIC_CAPTURE_TEST"] == "1")
)
func microphoneCaptureFixture() async throws {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        Issue.record("El host de pruebas no tiene permiso de micrófono; concédelo a ClassScribe desde la app")
        return
    }
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
    )
    guard let microphone = discovery.devices.first else {
        Issue.record("No hay micrófono disponible")
        return
    }
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClassScribe-MicCapture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let controller = CaptureController()
    _ = try await controller.start(
        mode: .inPerson,
        application: nil,
        microphone: MicrophoneOption(id: microphone.uniqueID, name: microphone.localizedName),
        folder: folder
    )
    try await Task.sleep(for: .seconds(60))
    let level = controller.levelDBFS
    let result = try await controller.stop()
    #expect(result.duration >= 55)
    #expect(level > -120)
    #expect(try rms(of: result.url) > 0.0001)
}

private func rms(of url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)
    ) else { return 0 }
    try file.read(into: buffer)
    guard let channels = buffer.floatChannelData else { return 0 }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return 0 }
    let sum = (0 ..< count).reduce(0.0) { partial, index in
        let value = Double(channels[0][index])
        return partial + value * value
    }
    return sqrt(sum / Double(count))
}
