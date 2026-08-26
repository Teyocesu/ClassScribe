import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AudioCaptureSession")

/// Orchestrates app audio capture + optional mic recording.
/// Replaces the CLI entry point — call `start()` and `stop()` directly from the host app.
@available(macOS 14.2, *)
public class AudioCaptureSession: @unchecked Sendable {
    private var pids: [pid_t]
    private var source: AppAudioCaptureSource
    private let sampleRate: Int
    private let channels: Int
    private let appOutputURL: URL
    private let appManifestURL: URL?
    private let micOutputURL: URL?
    private let micDeviceUID: String?
    private let debugLogging: Bool
    private let appLiveSink: LiveAudioSink?
    private let appCallbackGate: (@Sendable () -> Bool)?
    private let micLiveSink: LiveAudioSink?
    // Inert in production (nil); an e2e build injects one to verify the mic
    // installTap NSException recovery (issue #379). Forwarded to MicCaptureHandler.
    private let micDebugFault: DebugTapFault?

    private var appCapture: AppAudioCapture?
    private var masterWriter: MasterAudioWriter?
    private var stoppedAppTerminalErrorMessage: String?
    private var micCapture: MicCaptureHandler?
    private var appFileHandle: FileHandle?
    private var applicationSourceGeneration: UInt64 = 1
    private var appFirstFrameTicks: UInt64 = 0
    private var appOutputSampleRate = 0
    private var appOutputChannels = 0

    /// - Parameter pids: PIDs to capture audio from. For Electron/WebView2
    ///   apps (Teams 2.x, Slack, Discord) this should include the root PID
    ///   plus helper/renderer children; for native Cocoa apps a
    ///   single-element array is fine.
    /// - Parameter appLiveSink: Optional real-time buffer callback for the app
    ///   audio track (CATap output, interleaved Float32 at the tap's native
    ///   rate, typically 48 kHz). Called from the IOProc thread — non-blocking.
    /// - Parameter micLiveSink: Optional real-time buffer callback for the mic
    ///   track (mono Float32 at file rate, typically 16 kHz post-resample).
    ///   Called from the AVAudioEngine tap thread — non-blocking.
    public convenience init(
        pids: [pid_t],
        appOutputURL: URL,
        appManifestURL: URL? = nil,
        sampleRate: Int = 48000,
        channels: Int = 2,
        micOutputURL: URL? = nil,
        micDeviceUID: String? = nil,
        debugLogging: Bool = false,
        appLiveSink: LiveAudioSink? = nil,
        appCallbackGate: (@Sendable () -> Bool)? = nil,
        micLiveSink: LiveAudioSink? = nil,
        micDebugFault: DebugTapFault? = nil,
    ) {
        self.init(
            source: .application(processes: pids),
            appOutputURL: appOutputURL,
            appManifestURL: appManifestURL,
            sampleRate: sampleRate,
            channels: channels,
            micOutputURL: micOutputURL,
            micDeviceUID: micDeviceUID,
            debugLogging: debugLogging,
            appLiveSink: appLiveSink,
            appCallbackGate: appCallbackGate,
            micLiveSink: micLiveSink,
            micDebugFault: micDebugFault,
        )
    }

    public init(
        source: AppAudioCaptureSource,
        appOutputURL: URL,
        appManifestURL: URL? = nil,
        sampleRate: Int = 48000,
        channels: Int = 2,
        micOutputURL: URL? = nil,
        micDeviceUID: String? = nil,
        debugLogging: Bool = false,
        appLiveSink: LiveAudioSink? = nil,
        appCallbackGate: (@Sendable () -> Bool)? = nil,
        micLiveSink: LiveAudioSink? = nil,
        micDebugFault: DebugTapFault? = nil,
    ) {
        self.source = source
        if case let .application(processes) = source {
            self.pids = processes
        } else {
            self.pids = []
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.appOutputURL = appOutputURL
        self.appManifestURL = appManifestURL
        self.micOutputURL = micOutputURL
        self.micDeviceUID = micDeviceUID
        self.debugLogging = debugLogging
        self.appLiveSink = appLiveSink
        self.appCallbackGate = appCallbackGate
        self.micLiveSink = micLiveSink
        self.micDebugFault = micDebugFault
    }

    /// Start capturing app audio (and optionally mic audio).
    public func start() throws {
        applicationSourceGeneration = 1
        stoppedAppTerminalErrorMessage = nil
        // Create app output file and get its file descriptor
        // Restrict permissions to owner-only (0600) — audio may contain sensitive meeting content
        FileManager.default.createFile(
            atPath: appOutputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600],
        )
        let handle = try FileHandle(forWritingTo: appOutputURL)
        appFileHandle = handle
        if let appManifestURL {
            masterWriter = MasterAudioWriter(
                outputFileDescriptor: handle.fileDescriptor,
                masterURL: appOutputURL,
                manifestURL: appManifestURL,
                timelineAnchor: TimelineAnchor(),
            )
        } else {
            masterWriter = nil
        }
        do {
            try startApplicationCapture(
                source: source,
                liveSink: appLiveSink,
                callbackGate: appCallbackGate,
            )
        } catch {
            try? handle.close()
            appFileHandle = nil
            masterWriter = nil
            throw error
        }

        // Start mic capture if requested
        if let micURL = micOutputURL {
            let mic = MicCaptureHandler(
                outputURL: micURL,
                debugLogging: debugLogging,
                liveSink: micLiveSink,
                debugFault: micDebugFault,
            )
            do {
                try mic.start(deviceUID: micDeviceUID)
                micCapture = mic
            } catch {
                logger.error("Failed to start mic capture: \(error.localizedDescription, privacy: .public). Continuing with app audio only.")
            }
        }

        logger.info("Capture session started (PIDs \(self.pids), rate: \(self.sampleRate), channels: \(self.channels))")
    }

    /// Replaces only the native application source. The session-owned file
    /// descriptor, timeline anchor, and live store remain untouched. The old
    /// CATap is synchronously stopped and its IOProc queue drained by
    /// `AppAudioCapture.stop()` before the new tap is started.
    public func replaceApplicationCapture(
        pids: [pid_t],
        liveSink: LiveAudioSink?,
        callbackGate: (@Sendable () -> Bool)?,
    ) throws {
        try replaceApplicationCapture(
            source: .application(processes: pids),
            liveSink: liveSink,
            callbackGate: callbackGate,
        )
    }

    public func replaceApplicationCapture(
        source: AppAudioCaptureSource,
        liveSink: LiveAudioSink?,
        callbackGate: (@Sendable () -> Bool)?,
    ) throws {
        guard let handle = appFileHandle else {
            throw NSError(
                domain: "audiotap", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Capture session has no durable app output"],
            )
        }
        stopApplicationCapture()
        if let failureMessage = masterWriter?.failureMessage {
            throw NSError(
                domain: "audiotap.master",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: failureMessage],
            )
        }
        applicationSourceGeneration &+= 1
        self.source = source
        if case let .application(processes) = source {
            self.pids = processes
        } else {
            self.pids = []
        }
        do {
            try startApplicationCapture(
                source: source,
                liveSink: liveSink,
                callbackGate: callbackGate,
            )
        } catch {
            // The existing raw file and its current length are deliberately
            // left intact so the caller can preserve a recoverable session.
            _ = handle
            throw error
        }
    }

    /// Stops the current native app source but leaves the session file open so
    /// a subsequent source generation can append at the same offset.
    public func stopApplicationCapture() {
        if let capture = appCapture {
            capture.stop()
            rememberApplicationReadings(capture)
            appCapture = nil
        }
        finishMasterWriter()
    }

    private func startApplicationCapture(
        source: AppAudioCaptureSource,
        liveSink: LiveAudioSink?,
        callbackGate: (@Sendable () -> Bool)?,
    ) throws {
        guard let handle = appFileHandle else {
            throw NSError(
                domain: "audiotap", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Capture session output is not open"],
            )
        }
        let capture = AppAudioCapture(
            source: source,
            outputFileDescriptor: handle.fileDescriptor,
            sampleRate: sampleRate,
            channels: channels,
            debugLogging: debugLogging,
            liveSink: liveSink,
            timelineAnchor: masterWriter?.timelineAnchor,
            sourceCallbackGate: callbackGate,
            masterWriter: masterWriter,
            sourceGeneration: applicationSourceGeneration,
        )
        try capture.start()
        appCapture = capture
        rememberApplicationReadings(capture)
    }

    private func rememberApplicationReadings(_ capture: AppAudioCapture) {
        if capture.appFirstFrameTime > 0 {
            if appFirstFrameTicks == 0 {
                appFirstFrameTicks = capture.appFirstFrameTime
            } else {
                appFirstFrameTicks = min(appFirstFrameTicks, capture.appFirstFrameTime)
            }
        }
        if capture.outputSampleRate > 0 {
            appOutputSampleRate = capture.outputSampleRate
        }
        if capture.outputChannels > 0 {
            appOutputChannels = capture.outputChannels
        }
    }

    /// Instantaneous app-audio level in dBFS, decayed to -120 when no buffer has
    /// arrived in the last 0.5 s. Drives the menu-bar asymmetric-silence indicator.
    public var appLevelDBFS: Double {
        appCapture?.currentLevelDBFS ?? -120
    }

    /// Terminal failure owned by the current native source or durable master.
    /// The session retains the first failure after source teardown so the
    /// control plane can perform recoverable finalization without discarding
    /// durable evidence.
    public var appTerminalErrorMessage: String? {
        masterWriter?.failureMessage
            ?? appCapture?.terminalErrorMessage
            ?? stoppedAppTerminalErrorMessage
    }

    /// Instantaneous mic level in dBFS, decayed to -120 when no buffer has arrived
    /// in the last 0.5 s. Drives the menu-bar asymmetric-silence indicator.
    public var micLevelDBFS: Double {
        micCapture?.currentLevelDBFS ?? -120
    }

    /// Stop all capture and return the result.
    public func stop() -> AudioCaptureResult {
        stopApplicationCapture()
        finishMasterWriter()
        micCapture?.stop()

        // Gather the raw per-track readings and hand the delay/rate/channel
        // arithmetic to a pure, unit-tested builder. New online sessions have
        // a source-rate master; legacy direct callers without a manifest keep
        // the historical fixed-rate output path.
        let result = AudioCaptureResult.make(
            appOutputURL: appOutputURL,
            micOutputURL: micOutputURL,
            configured: (sampleRate: sampleRate, channels: channels),
            app: .init(
                firstFrameTicks: appFirstFrameTicks,
                sampleRate: appOutputSampleRate,
                channels: appOutputChannels,
            ),
            mic: .init(
                recorded: micCapture != nil,
                firstFrameTicks: micCapture?.firstFrameTime ?? 0,
            ),
        )

        stoppedAppTerminalErrorMessage = masterWriter?.failureMessage
        try? appFileHandle?.close()
        appFileHandle = nil
        masterWriter = nil
        micCapture = nil

        logger.info("Capture session stopped (rate: \(result.actualSampleRate), channels: \(result.actualChannels), micDelay: \(result.micDelay))")
        return result
    }

    /// Test-only product seam: attaches a real session-owned master writer to
    /// this session without constructing a CoreAudio source. The native
    /// executor can then exercise the same level/stop ownership path with a
    /// deterministic injected durable failure.
    @_spi(ClassScribeTests)
    public func installMasterWriterForTesting(
        _ writer: MasterAudioWriter,
        fileHandle: FileHandle,
    ) {
        masterWriter = writer
        appFileHandle = fileHandle
        stoppedAppTerminalErrorMessage = nil
    }

    private func finishMasterWriter() {
        guard let writer = masterWriter else { return }
        do {
            try writer.finish()
        } catch {
            writer.recordFailure(error)
            logger.error(
                "Master audio finalization failed: \(error.localizedDescription, privacy: .public)",
            )
        }
        stoppedAppTerminalErrorMessage = writer.failureMessage
    }
}
