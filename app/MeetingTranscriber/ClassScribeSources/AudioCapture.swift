@preconcurrency import AVFoundation
import AppKit
import AudioTapLib
import Darwin
import Foundation
import Observation

actor LiveAudioBufferStore {
    private let sampleRate = 16_000
    private let retainedSeconds = 45
    private var samples: [Float] = []
    private var baseSampleIndex: Int64 = 0
    private var totalSampleCount: Int64 = 0
    private(set) var latestLevelDBFS = -120.0

    func append(_ buffer: LiveAudioBuffer) {
        let mono = Self.mono16k(buffer)
        guard !mono.isEmpty else { return }
        samples.append(contentsOf: mono)
        totalSampleCount += Int64(mono.count)
        let meanSquare = mono.reduce(0.0) { $0 + Double($1 * $1) } / Double(mono.count)
        latestLevelDBFS = meanSquare > 0 ? 10 * log10(meanSquare) : -120

        let maximum = sampleRate * retainedSeconds
        if samples.count > maximum {
            let removed = samples.count - maximum
            samples.removeFirst(removed)
            baseSampleIndex += Int64(removed)
        }
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
        baseSampleIndex = 0
        totalSampleCount = 0
        latestLevelDBFS = -120
    }

    func totalSamples() -> Int64 { totalSampleCount }

    func window(seconds: Double, endingAt endIndex: Int64? = nil) -> (samples: [Float], start: TimeInterval)? {
        let end = min(endIndex ?? totalSampleCount, totalSampleCount)
        let wanted = Int64(seconds * Double(sampleRate))
        let start = max(baseSampleIndex, end - wanted)
        guard end > start else { return nil }
        let lower = Int(start - baseSampleIndex)
        let upper = Int(end - baseSampleIndex)
        guard lower >= 0, upper <= samples.count else { return nil }
        return (Array(samples[lower ..< upper]), Double(start) / Double(sampleRate))
    }

    func hasRecentPause(milliseconds: Int = 550) -> Bool {
        let count = min(samples.count, sampleRate * milliseconds / 1_000)
        guard count > 0 else { return true }
        let tail = samples.suffix(count)
        let meanSquare = tail.reduce(0.0) { $0 + Double($1 * $1) } / Double(count)
        let db = meanSquare > 0 ? 10 * log10(meanSquare) : -120
        return db < -43
    }

    private static func mono16k(_ buffer: LiveAudioBuffer) -> [Float] {
        guard buffer.channelCount > 0, buffer.sampleRate > 0 else { return [] }
        let frames = buffer.samples.count / buffer.channelCount
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0 ..< frames {
            var sum: Float = 0
            for channel in 0 ..< buffer.channelCount {
                sum += buffer.samples[frame * buffer.channelCount + channel]
            }
            mono[frame] = sum / Float(buffer.channelCount)
        }
        guard buffer.sampleRate != 16_000 else { return mono }
        let outputCount = max(1, Int(Double(mono.count) * 16_000 / Double(buffer.sampleRate)))
        return (0 ..< outputCount).map { index in
            let source = min(mono.count - 1, Int(Double(index) * Double(buffer.sampleRate) / 16_000))
            return mono[source]
        }
    }
}

enum WavFile {
    static func wrapFloat32Raw(_ rawURL: URL, destination: URL, sampleRate: Int = 16_000) throws {
        let data = try Data(contentsOf: rawURL)
        var header = Data()
        header.appendASCII("RIFF")
        header.appendUInt32LE(UInt32(36 + data.count))
        header.appendASCII("WAVEfmt ")
        header.appendUInt32LE(16)
        header.appendUInt16LE(3) // IEEE float
        header.appendUInt16LE(1)
        header.appendUInt32LE(UInt32(sampleRate))
        header.appendUInt32LE(UInt32(sampleRate * 4))
        header.appendUInt16LE(4)
        header.appendUInt16LE(32)
        header.appendASCII("data")
        header.appendUInt32LE(UInt32(data.count))
        header.append(data)
        try header.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func writeFloat32(_ samples: [Float], to destination: URL, sampleRate: Int = 16_000) throws {
        let temporary = destination.deletingPathExtension().appendingPathExtension("raw")
        let data = samples.withUnsafeBytes { Data($0) }
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try wrapFloat32Raw(temporary, destination: destination, sampleRate: sampleRate)
    }

    static func validate(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.sampleRate > 0, file.length > 0 else {
            throw CaptureError.emptyAudio
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) { append(value.data(using: .ascii)!) }
    mutating func appendUInt16LE(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt16>.size))
    }
    mutating func appendUInt32LE(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt32>.size))
    }
}

enum CaptureError: LocalizedError {
    case sourceMissing
    case permissionDenied
    case noProcesses
    case emptyAudio
    case notRecording

    var errorDescription: String? {
        switch self {
        case .sourceMissing: "Selecciona una fuente de audio."
        case .permissionDenied: "El permiso de micrófono fue denegado. Actívalo en Privacidad y seguridad."
        case .noProcesses: "La aplicación elegida ya no está en ejecución."
        case .emptyAudio: "El archivo de audio está vacío. El original se conservó para diagnóstico."
        case .notRecording: "No hay una clase en grabación."
        }
    }
}

@MainActor
@Observable
final class CaptureController {
    private(set) var applications: [RunningApplication] = []
    private(set) var microphones: [MicrophoneOption] = []
    private(set) var levelDBFS = -120.0
    private(set) var isCapturing = false

    let liveStore = LiveAudioBufferStore()
    private var onlineSession: AudioCaptureSession?
    private var microphoneCapture: MicCaptureHandler?
    private var levelTimer: Timer?
    private var rawOnlineURL: URL?
    private var sourceWAVURL: URL?

    func refreshSources() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        applications = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  let name = app.localizedName,
                  !name.isEmpty else { return nil }
            return RunningApplication(
                id: app.processIdentifier,
                name: name,
                bundleIdentifier: app.bundleIdentifier ?? "",
                bundleURL: app.bundleURL
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        microphones = discovery.devices.map {
            MicrophoneOption(id: $0.uniqueID, name: $0.localizedName)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start(
        mode: CaptureMode,
        application: RunningApplication?,
        microphone: MicrophoneOption?,
        folder: URL
    ) async throws -> URL {
        guard !isCapturing else { throw CaptureError.notRecording }
        await liveStore.reset()
        let sourceURL = folder.appendingPathComponent("source.wav")
        let sink: LiveAudioSink = { [liveStore] buffer in
            Task { await liveStore.append(buffer) }
        }

        switch mode {
        case .online:
            guard let application else { throw CaptureError.sourceMissing }
            var pids: [pid_t] = [application.id]
            if let bundleURL = application.bundleURL {
                pids.append(contentsOf: ProcessTreeEnumerator.pidsRooted(in: bundleURL))
            }
            pids = Array(Set(pids)).filter { $0 > 0 && $0 != getpid() }
            guard !pids.isEmpty else { throw CaptureError.noProcesses }
            let rawURL = folder.appendingPathComponent("source.raw")
            let session = AudioCaptureSession(
                pids: pids,
                appOutputURL: rawURL,
                micOutputURL: nil,
                appLiveSink: sink
            )
            try session.start()
            rawOnlineURL = rawURL
            onlineSession = session

        case .inPerson:
            guard await requestMicrophonePermission() else { throw CaptureError.permissionDenied }
            guard let microphone else { throw CaptureError.sourceMissing }
            let capture = MicCaptureHandler(outputURL: sourceURL, liveSink: sink)
            try capture.start(deviceUID: microphone.id)
            microphoneCapture = capture
        }

        sourceWAVURL = sourceURL
        isCapturing = true
        startLevelTimer()
        return sourceURL
    }

    func stop() throws -> (url: URL, duration: TimeInterval) {
        guard isCapturing, let sourceWAVURL else { throw CaptureError.notRecording }
        isCapturing = false
        levelTimer?.invalidate()
        levelTimer = nil
        if let onlineSession {
            _ = onlineSession.stop()
            self.onlineSession = nil
            if let rawOnlineURL {
                try WavFile.wrapFloat32Raw(rawOnlineURL, destination: sourceWAVURL)
                try? FileManager.default.removeItem(at: rawOnlineURL)
            }
        }
        microphoneCapture?.stop()
        microphoneCapture = nil
        levelDBFS = -120
        return (sourceWAVURL, try WavFile.validate(sourceWAVURL))
    }

    func abortPreservingAudio() {
        guard isCapturing else { return }
        _ = try? stop()
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let onlineSession = self.onlineSession {
                    self.levelDBFS = onlineSession.appLevelDBFS
                } else if let microphoneCapture = self.microphoneCapture {
                    self.levelDBFS = microphoneCapture.currentLevelDBFS
                }
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
