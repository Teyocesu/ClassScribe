import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AudioCaptureSession")

/// Orchestrates app audio capture + optional mic recording.
/// Replaces the CLI entry point — call `start()` and `stop()` directly from the host app.
@available(macOS 14.2, *)
public class AudioCaptureSession {
    private var pids: [pid_t]
    private var source: AppAudioCaptureSource
    private let sampleRate: Int
    private let channels: Int
    private let appOutputURL: URL
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
    private var micCapture: MicCaptureHandler?
    private var appFileHandle: FileHandle?
    private let appTimelineAnchor = TimelineAnchor(rate: Int(speechSampleRate))
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
        // Create app output file and get its file descriptor
        // Restrict permissions to owner-only (0600) — audio may contain sensitive meeting content
        FileManager.default.createFile(
            atPath: appOutputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600],
        )
        let handle = try FileHandle(forWritingTo: appOutputURL)
        appFileHandle = handle
        do {
            try startApplicationCapture(
                source: source,
                liveSink: appLiveSink,
                callbackGate: appCallbackGate,
            )
        } catch {
            try? handle.close()
            appFileHandle = nil
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
        guard let capture = appCapture else { return }
        capture.stop()
        rememberApplicationReadings(capture)
        appCapture = nil
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
            timelineAnchor: appTimelineAnchor,
            sourceCallbackGate: callbackGate,
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

    /// Terminal output-device restart failure owned by the current native
    /// source. The session keeps the stopped AppAudioCapture object attached
    /// until the control plane observes this value and performs normal
    /// recoverable finalization, so durable audio is never discarded.
    public var appTerminalErrorMessage: String? {
        appCapture?.terminalErrorMessage
    }

    /// Instantaneous mic level in dBFS, decayed to -120 when no buffer has arrived
    /// in the last 0.5 s. Drives the menu-bar asymmetric-silence indicator.
    public var micLevelDBFS: Double {
        micCapture?.currentLevelDBFS ?? -120
    }

    /// Stop all capture and return the result.
    public func stop() -> AudioCaptureResult {
        stopApplicationCapture()
        micCapture?.stop()

        // Gather the raw per-track readings and hand the delay/rate/channel
        // arithmetic to a pure, unit-tested builder. The app file is what
        // `AppAudioCapture` actually WROTE — 16 kHz mono after the in-IOProc
        // resample, not the device's raw capture format.
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

        try? appFileHandle?.close()
        appFileHandle = nil
        micCapture = nil

        logger.info("Capture session stopped (rate: \(result.actualSampleRate), channels: \(result.actualChannels), micDelay: \(result.micDelay))")
        return result
    }
}
