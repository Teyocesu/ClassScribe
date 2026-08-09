@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// Records microphone audio to a WAV file via AVAudioEngine.
/// Monitors for device changes via CoreAudio property listener (default input device)
/// and AVAudioEngine configuration change notification (format/route changes).
/// Automatically restarts the engine on device switch, preserving the selected device
/// when still available or falling back to system default with a warning.
///
/// Public API (`start`/`stop`/`currentLevelDBFS`) is called from the main actor.
/// The render-thread callback acquires an `InFlightCallbackGate` lease before
/// reading the converter or writing `outputFile`. Stop/restart closes that gate
/// and drains existing leases before mutating those resources. Public lifecycle
/// calls remain main-actor-owned; `@unchecked Sendable` reflects that this
/// callback discipline is not expressible to the compiler.
public class MicCaptureHandler: @unchecked Sendable {
    private var engine = AVAudioEngine()
    /// `internal` (not `private`) so the cross-file `+Timeline` extension can
    /// write gap-fill silence to it.
    var outputFile: AVAudioFile?
    private let outputURL: URL
    private let debugLogging: Bool
    private let liveSink: LiveAudioSink?
    // Debug fault injection (issue #379 repro): nil in production. An e2e
    // build's composition root injects one (DualSourceRecorder, gated by
    // #if E2E_FAULT_INJECTION) to verify the installTap NSException recovery.
    private let debugFault: DebugTapFault?
    /// Removes the engine's input tap in `stop()`. Injectable so a test can
    /// assert the teardown is skipped when no tap was installed (reading
    /// `AVAudioEngine.inputNode` throws an uncatchable NSException on an input-less host).
    private let removeInputTap: (AVAudioEngine) -> Void
    /// True once a tap is attached to the current engine's inputNode; gates the `inputNode` teardown in `stop()`.
    private var tapInstalled = false
    private var isRecording = false
    private var isRestarting = false
    private var automaticRestartCount = 0
    private static let maximumAutomaticRestarts = 3
    private var ignoreConfigurationChangesUntil = Date.distantPast
    // Bounded retry for transient restart failures (issue #379): a device
    // change can briefly expose an invalid format; retry with exponential
    // backoff (MicRestartRetryPolicy) rather than dropping the recording.
    // Reset to 0 on a successful (re)start.
    private var restartRetryCount = 0
    // True while a retry is pending in the backoff window. `isRestarting` is
    // cleared synchronously when executeRestart returns, so without this a
    // device change arriving during the 0.3 s backoff would start a second,
    // parallel restart chain racing the pending one on `engine`.
    private var retryScheduled = false
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var configChangeObserver: NSObjectProtocol?
    private var selectedDeviceUID: String?
    private var fileSampleRate: Double = 0
    private var converter: AVAudioConverter?
    private let callbackGate = InFlightCallbackGate()
    private var hasStopped = false
    /// Pre-computed resampling ratio (fileSampleRate / tapSampleRate), avoids division in audio callback.
    private var resampleRatio: Double = 1.0
    /// Wall-clock anchoring so a device-restart gap becomes silence in the WAV
    /// instead of an under-run (issue #379 follow-up — see `+Timeline`).
    /// `internal` for that cross-file extension; survives restarts (never reset).
    var timelineAnchor = TimelineAnchor(rate: Int(speechSampleRate))
    public private(set) var firstFrameTime: UInt64 = 0
    public private(set) var terminalError: MicCaptureError?
    private let firstBufferGate = MicFirstBufferGate()

    // State for an injected DebugTapFault (above). Always compiled but inert
    // unless a fault was injected — see resolveTapInstallFormat /
    // armDebugFaultIfNeeded.
    private var debugFaultArmed = false
    private var injectBadTapFormatOnce = false

    private var debugRMS = DebugRMSReporter()
    private let levelPublisher = LevelPublisher()

    /// Returns the instantaneous mic level in dBFS, decayed to -120 if no buffer
    /// arrived in the last 0.5 seconds (e.g. device muted or unplugged) — without
    /// that, a stale reading would look like live audio.
    public var currentLevelDBFS: Double {
        levelPublisher.currentLevelDBFS
    }

    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )

    public init(
        outputURL: URL,
        debugLogging: Bool = false,
        liveSink: LiveAudioSink? = nil,
        debugFault: DebugTapFault? = nil,
        removeInputTap: @escaping (AVAudioEngine) -> Void = { $0.inputNode.removeTap(onBus: 0) },
    ) {
        self.outputURL = outputURL
        self.debugLogging = debugLogging
        self.liveSink = liveSink
        self.debugFault = debugFault
        self.removeInputTap = removeInputTap
    }

    deinit {
        stop()
    }

    private static func deviceIDForUID(_ uid: String) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID: Unmanaged<CFString>? = Unmanaged.passUnretained(uid as CFString)
        let qualifierSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, qualifierSize, &cfUID,
            &size, &deviceID,
        )
        return deviceID
    }

    public func start(deviceUID: String? = nil) throws {
        hasStopped = false
        selectedDeviceUID = deviceUID
        firstFrameTime = 0
        terminalError = nil
        automaticRestartCount = 0
        firstBufferGate.reset()
        MicCaptureDiagnostics.record(
            "start begin handler=\(ObjectIdentifier(self)) requestedUID=\(deviceUID ?? "default") output=\(outputURL.path)",
        )
        do {
            try startEngine(deviceUID: deviceUID)
        } catch {
            // `startEngine` can fail after creating the WAV or attaching the
            // input tap (for example if AVAudioEngine.start throws). Tear down
            // deterministically instead of waiting for ARC/deinit timing.
            stop()
            throw error
        }
        installDeviceChangeListener()
        installConfigChangeObserver()
    }

    /// Wait for audio that has actually reached the WAV writer. Callers must
    /// not present a recording as active before this succeeds.
    @MainActor
    public func waitForFirstBuffer(timeout: TimeInterval = 2.5) async throws {
        try Task.checkCancellation()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if firstBufferGate.hasWrittenFrames {
                try Task.checkCancellation()
                return
            }
            // A restart can reach its terminal limit before the startup wait
            // expires. Surface that precise failure immediately instead of
            // overwriting it with a generic first-buffer timeout.
            if let terminalError {
                throw terminalError
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        if let terminalError {
            throw terminalError
        }
        let snapshot = firstBufferGate.snapshot
        let error = MicCaptureError.firstBufferTimeout(
            timeout: timeout,
            callbacks: snapshot.callbacks,
            frames: snapshot.frames,
        )
        MicCaptureDiagnostics.record("first-buffer timeout callbacks=\(snapshot.callbacks) frames=\(snapshot.frames)")
        terminalError = error
        stop()
        throw error
    }

    /// Validate the live hardware format and derive a tap format that MATCHES
    /// the node's actual channel count. Issue #379: a device change to a
    /// multi-channel input (e.g. 24 kHz/1ch → 44.1 kHz/2ch) crashed because the
    /// tap was hardcoded to 1 channel — installTapOnBus raises an NSException
    /// when the tap format's channel count differs from the freshly-negotiated
    /// node bus. Matching the node's channel count and downmixing to mono in
    /// the converter (see startEngine) avoids the mismatch at the source. The
    /// 0 Hz / 0-channel guard covers the transient where the device hasn't
    /// finished re-initialising; throwing lets executeRestart retry.
    private func validatedTapFormat(for hwFormat: AVAudioFormat) throws -> AVAudioFormat {
        guard let tapFormat = TapFormatResolver.tapFormat(forHardware: hwFormat) else {
            throw MicCaptureError.invalidHardwareFormat(
                sampleRate: hwFormat.sampleRate, channelCount: hwFormat.channelCount,
            )
        }
        return tapFormat
    }

    // swiftlint:disable:next function_body_length
    private func startEngine(deviceUID: String? = nil) throws {
        tapInstalled = false // reset per attempt; re-set once safeInstallTap attaches a tap
        // No input device available (e.g. Mac Mini server without mic hardware) —
        // accessing AVAudioEngine.inputNode would throw an uncatchable NSException.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw MicCaptureError.noInputDevice
        }

        let inputNode = engine.inputNode

        if let uid = deviceUID {
            var deviceID = Self.deviceIDForUID(uid)
            guard deviceID != kAudioObjectUnknown else {
                logger.error("Selected mic device UID '\(uid)' is unavailable")
                MicCaptureDiagnostics.record("selected device UID unavailable; start rejected")
                throw MicCaptureError.deviceUnavailable(uid: uid)
            }
            let audioUnit = inputNode.audioUnit! // swiftlint:disable:this force_unwrapping
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size),
            )
            guard status == noErr else {
                logger.error("Mic device set failed (status \(status)); start rejected")
                MicCaptureDiagnostics.record("selected device failed status=\(status); start rejected")
                throw MicCaptureError.deviceSelectionFailed(uid: uid, status: status)
            }
            logger.info("Mic device set: \(uid) (ID \(deviceID))")
            MicCaptureDiagnostics.record("selected device applied uid=\(uid) id=\(deviceID)")
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Mic hardware format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount)ch")
        MicCaptureDiagnostics.record("hardware format rate=\(hwFormat.sampleRate) channels=\(hwFormat.channelCount)")
        MicCaptureDiagnostics.record(
            "system default input name=\(getDefaultInputDeviceName() ?? "unknown") uid=\(getDefaultInputDeviceUID() ?? "unknown")",
        )

        let tapFormat = try validatedTapFormat(for: hwFormat)

        if debugLogging {
            let inUID = getDefaultInputDeviceUID() ?? "?"
            let inName = getDefaultInputDeviceName() ?? "?"
            logger.info(
                "[debug] Mic input device: name=\(inName, privacy: .public) uid=\(inUID, privacy: .public) hwRate=\(hwFormat.sampleRate, privacy: .public) hwChannels=\(hwFormat.channelCount, privacy: .public)",
            )
        }

        logger.info("Mic tap format: \(tapFormat.sampleRate) Hz, \(tapFormat.channelCount)ch")
        MicCaptureDiagnostics.record("tap install format rate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount)")

        // Always 16kHz — WhisperKit target rate
        if outputFile == nil {
            fileSampleRate = speechSampleRate
            let wavSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: fileSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            outputFile = try AVAudioFile(forWriting: outputURL, settings: wavSettings)
            // Restrict permissions to owner-only (0600) — audio may contain sensitive meeting content
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputURL.path,
            )
            // A fresh file gets a fresh wall-clock anchor — its accounting
            // belongs to this file's sample stream. Restarts keep the file
            // (and the anchor), so a restart gap is bridged with silence.
            timelineAnchor = TimelineAnchor(rate: Int(fileSampleRate))
        }

        converter = nil
        resampleRatio = fileSampleRate / tapFormat.sampleRate
        if let setup = MicConverterFactory.make(tapFormat: tapFormat, fileSampleRate: fileSampleRate) {
            converter = setup.converter
            if let channel = setup.selectedChannel {
                logger.info(
                    "Mic: layout has no usable implicit downmix — selecting channel \(channel) explicitly",
                )
            }
            logger.info(
                "Mic: converting \(Int(tapFormat.sampleRate))Hz/\(tapFormat.channelCount)ch → \(Int(self.fileSampleRate))Hz/1ch",
            )
        }

        // Normally returns tapFormat unchanged; under an injected DebugTapFault
        // it returns an invalid format once to exercise the recovery path.
        let installFormat = resolveTapInstallFormat(default: tapFormat)
        // installTapOnBus raises an ObjC NSException for an invalid/incompatible
        // format (issue #379); Swift can't catch that. Build the tap block, then
        // install it through the ObjC shim so a raise becomes a recoverable throw.
        // swiftlint:disable closure_parameter_position closure_body_length
        let tapBlock: AVAudioNodeTapBlock = {
            [weak self] buffer, when in
            // swiftlint:enable closure_parameter_position closure_body_length
            guard let self, self.callbackGate.enter() else { return }
            defer { self.callbackGate.leave() }
            if self.firstFrameTime == 0 {
                self.firstFrameTime = mach_absolute_time()
            }
            self.accumulateDebugRMS(buffer: buffer)
            self.publishCurrentLevel()
            self.maybeReportDebugRMS()
            do {
                if let converter = self.converter {
                    let outputFrames = resampleOutputCapacity(
                        inputFrames: buffer.frameLength, ratio: self.resampleRatio,
                    )
                    guard let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: converter.outputFormat,
                        frameCapacity: outputFrames,
                    ) else { return }
                    var error: NSError?
                    let feed = FeedOnce(buffer: buffer)
                    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                        feed.next(outStatus)
                    }
                    if let error {
                        logger.warning("Mic resample error: \(error.localizedDescription, privacy: .public)")
                        MicCaptureDiagnostics.record("converter error=\(error.localizedDescription)")
                    } else {
                        self.fillTimelineGap(before: when, outputFrames: Int(outputBuffer.frameLength))
                        try self.outputFile?.write(from: outputBuffer)
                        self.markWrittenBuffer(frames: Int(outputBuffer.frameLength))
                        self.forwardToLiveSink(buffer: outputBuffer)
                    }
                } else {
                    self.fillTimelineGap(before: when, outputFrames: Int(buffer.frameLength))
                    try self.outputFile?.write(from: buffer)
                    self.markWrittenBuffer(frames: Int(buffer.frameLength))
                    self.forwardToLiveSink(buffer: buffer)
                }
            } catch {
                logger.warning("Mic write error: \(error.localizedDescription, privacy: .public)")
                MicCaptureDiagnostics.record("WAV write error=\(error.localizedDescription)")
            }
        }

        do {
            try inputNode.safeInstallTap(onBus: 0, bufferSize: 4096, format: installFormat, block: tapBlock)
        } catch {
            logger.error("Mic: installTap failed (\(error.localizedDescription, privacy: .public)) — restart will retry")
            throw error
        }
        tapInstalled = true // inputNode accessed + tap attached; stop() must remove it even if start() throws

        ignoreConfigurationChangesUntil = Date().addingTimeInterval(1.0)
        MicCaptureDiagnostics.record("engine prepare")
        engine.prepare()
        callbackGate.open()
        try engine.start()
        isRecording = true
        restartRetryCount = 0
        logger.info("Mic recording started: \(self.outputURL.lastPathComponent)")
        MicCaptureDiagnostics.record("engine started; configuration events ignored for 1s")

        armDebugFaultIfNeeded()
    }

    private func installDeviceChangeListener() {
        guard deviceChangeListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultInputDeviceChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            listener,
        )
        if status == noErr {
            deviceChangeListener = listener
            logger.info("Mic: listening for default input device changes")
        } else {
            logger.warning("Failed to install device change listener (status: \(status))")
        }
    }

    /// Listen for AVAudioEngine configuration changes (format changes on current device).
    private func installConfigChangeObserver() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main,
        ) { [weak self] _ in
            self?.handleEngineConfigChange()
        }
        logger.info("Mic: listening for engine configuration changes")
    }

    private func handleEngineConfigChange() {
        guard Date() >= ignoreConfigurationChangesUntil else {
            MicCaptureDiagnostics.record("ignored configuration change caused by engine start")
            return
        }
        logger.info("Mic: engine configuration changed (format/route change)")
        handleDeviceChange(trigger: .engineConfigurationChanged)
    }

    private func handleDefaultInputDeviceChanged() {
        logger.info("Mic: default input device changed")
        handleDeviceChange(trigger: .defaultInputChanged)
    }

    private func handleDeviceChange(trigger: MicRestartTrigger) {
        MicCaptureDiagnostics.record("device event trigger=\(trigger == .defaultInputChanged ? "default-input" : "engine-configuration")")
        let isDeviceAvailable = selectedDeviceUID.map { Self.deviceIDForUID($0) != kAudioObjectUnknown } ?? false
        let action = MicRestartPolicy.decideRestart(
            isRecording: isRecording,
            // Treat a pending retry as still-restarting so a device change in
            // the backoff window doesn't spawn a competing restart chain.
            isRestarting: isRestarting || retryScheduled,
            selectedDeviceUID: selectedDeviceUID,
            isSelectedDeviceAvailable: isDeviceAvailable,
            trigger: trigger,
        )

        switch action {
        case let .restart(deviceUID):
            executeRestart(deviceUID: deviceUID)

        case .skip:
            break
        }
    }

    private func executeRestart(deviceUID: String?) {
        guard automaticRestartCount < Self.maximumAutomaticRestarts else {
            finishWithFailure(.restartLimitExceeded(maximum: Self.maximumAutomaticRestarts))
            return
        }
        automaticRestartCount += 1
        MicCaptureDiagnostics.record("restart \(automaticRestartCount)/\(Self.maximumAutomaticRestarts) device=\(deviceUID ?? "default")")
        isRestarting = true
        defer { isRestarting = false }

        if deviceUID == nil, let uid = selectedDeviceUID {
            logger.warning("Mic: selected device '\(uid)' no longer available, falling back to system default")
        }

        callbackGate.closeAndWait()
        if tapInstalled {
            removeInputTap(engine)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        // AVAudioEngine can be in a bad state after config change — must recreate.
        // Hold a strong reference to the old engine for a grace period so any
        // in-flight `AVAudioIOUnit::IOUnitPropertyListener` blocks that
        // AVFoundation queued on a libdispatch worker fire against a live
        // object. Without this hold, dropping the last reference here races
        // against those blocks and crashes with EXC_BAD_ACCESS in
        // `objc_msgSend` on the freed engine.
        let oldEngine = engine
        engine = AVAudioEngine()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = oldEngine
        }

        do {
            try startEngine(deviceUID: deviceUID)
            let hwRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
            if hwRate <= 0 {
                logger.warning("Mic: hardware format rate is \(hwRate) after restart — may produce incorrect audio")
            }
            installConfigChangeObserver()
            logger.info("Mic: engine restarted on \(deviceUID != nil ? "selected" : "default") device (\(Int(hwRate)) Hz)")
        } catch {
            callbackGate.closeAndWait()
            // A transient invalid format / installTap raise (issue #379) is
            // recoverable: the device usually settles within a few hundred ms.
            // Keep recording and retry with backoff instead of killing it.
            logger.error("Failed to restart mic after device change: \(error.localizedDescription, privacy: .public) — scheduling retry")
            scheduleRestartRetry(deviceUID: deviceUID)
        }
    }

    private func finishWithFailure(_ error: MicCaptureError) {
        guard terminalError == nil else { return }
        terminalError = error
        MicCaptureDiagnostics.record("terminal capture error=\(error.localizedDescription)")
        stop()
    }

    /// Re-attempt a failed restart after a short backoff, bounded by
    /// `maxRestartRetries`. Only retries while still recording; gives up (and
    /// stops recording) once the budget is exhausted.
    private func scheduleRestartRetry(deviceUID: String?) {
        guard isRecording else { return }
        switch MicRestartRetryPolicy.decide(attemptsSoFar: restartRetryCount) {
        case .giveUp:
            logger.error("Mic: giving up restart after \(MicRestartRetryPolicy.maxAttempts) failed attempts")
            finishWithFailure(.restartLimitExceeded(maximum: MicRestartRetryPolicy.maxAttempts))

        case let .retry(delay):
            restartRetryCount += 1
            retryScheduled = true
            let attempt = restartRetryCount
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.retryScheduled = false
                guard self.isRecording else { return }
                logger.info("Mic: restart retry \(attempt)/\(MicRestartRetryPolicy.maxAttempts)")
                self.executeRestart(deviceUID: deviceUID)
            }
        }
    }

    public func stop() {
        guard !hasStopped else {
            MicCaptureDiagnostics.record("stop duplicate ignored handler=\(ObjectIdentifier(self))")
            return
        }
        hasStopped = true
        MicCaptureDiagnostics.record("stop begin handler=\(ObjectIdentifier(self)) output=\(outputURL.path)")

        // Reject new callback work and wait for already-entered writes before
        // touching the tap, engine, converter or AVAudioFile.
        isRecording = false
        retryScheduled = false
        if let listener = deviceChangeListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                DispatchQueue.main,
                listener,
            )
            deviceChangeListener = nil
        }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        callbackGate.closeAndWait()
        // Skip the inputNode teardown when no tap was installed — the getter
        // raises an uncatchable NSException on an input-less host (deinit path).
        if tapInstalled {
            removeInputTap(engine)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
        outputFile = nil
        converter = nil
        if let handle = try? FileHandle(forWritingTo: outputURL) {
            try? handle.synchronize()
            try? handle.close()
        }
        let actualSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let metrics = firstBufferGate.snapshot
        MicCaptureDiagnostics.record(
            "stop complete handler=\(ObjectIdentifier(self)) callbacks=\(metrics.callbacks) frames=\(metrics.frames) bytes=\(metrics.frames * 2) fileSize=\(actualSize) restarts=\(automaticRestartCount) error=\(terminalError?.localizedDescription ?? "none")",
        )

        // Mirror the retain-grace from executeRestart: if the caller drops
        // MicCaptureHandler immediately after stop() returns, the engine
        // ivar's last reference would race against any in-flight
        // AVAudioIOUnit::IOUnitPropertyListener block AVFoundation queued
        // on a libdispatch worker. Holding a local ref for 500 ms lets
        // those blocks fire against a live object.
        let retainedEngine = engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = retainedEngine
        }
        logger.info("Mic recording stopped")
    }
}

// MARK: - Debug logging helpers

extension MicCaptureHandler {
    /// Publish the most recent per-buffer dBFS reading so UI consumers
    /// (menu bar level indicator) can poll it. Called from the
    /// AVAudioEngine tap callback after `accumulateDebugRMS`.
    func publishCurrentLevel() {
        levelPublisher.publish(level: debugRMS.lastLevelDBFS)
    }

    /// Sum squares across all channels of an AVAudioPCMBuffer into the shared
    /// reporter. AVAudioEngine taps deliver float buffers in practice; the int16
    /// branch is a safety net.
    func accumulateDebugRMS(buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }
        let sumSq: Double
        if let floatData = buffer.floatChannelData {
            sumSq = sumOfSquaresFloat(floatData, frames: frames, channels: channelCount)
        } else if let int16Data = buffer.int16ChannelData {
            sumSq = sumOfSquaresInt16(int16Data, frames: frames, channels: channelCount)
        } else {
            return
        }
        debugRMS.add(sumSq: sumSq, samples: frames * channelCount)
    }

    /// Drain the 5-s throttle and emit one RMS-energy log line per tick, but
    /// only when `debugLogging` is on. The drain itself runs unconditionally
    /// so the reporter's accumulators stay bounded for long sessions.
    func maybeReportDebugRMS() {
        guard let report = debugRMS.tick() else { return }
        guard debugLogging else { return }
        let dBStr = String(format: "%.1f", report.dBFS)
        logger.info(
            "[debug] Mic RMS (5s): \(dBStr, privacy: .public) dBFS, samples=\(report.samples, privacy: .public)",
        )
    }

    /// Hand the freshly-written PCM buffer (mono Float32 at file rate, typically
    /// 16 kHz post-resample) to the optional live sink. Short-circuits when no
    /// sink is installed.
    func forwardToLiveSink(buffer: AVAudioPCMBuffer) {
        guard let sink = liveSink else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.floatChannelData else { return }
        let ptr = channelData[0]
        let samples = Array(UnsafeBufferPointer(start: ptr, count: frames))
        sink(LiveAudioBuffer(
            samples: samples,
            channelCount: Int(buffer.format.channelCount),
            sampleRate: Int(buffer.format.sampleRate),
            hostTime: mach_absolute_time(),
        ))
    }

    func markWrittenBuffer(frames: Int) {
        if firstBufferGate.recordWrittenFrames(frames) {
            firstFrameTime = mach_absolute_time()
            let actualSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let fileID = outputFile.map { String(describing: ObjectIdentifier($0)) } ?? "none"
            MicCaptureDiagnostics.record(
                "first buffer written handler=\(ObjectIdentifier(self)) file=\(fileID) output=\(outputURL.path) frames=\(frames) fileSize=\(actualSize)",
            )
        }
    }

    func markTapInstalledForTesting() {
        tapInstalled = true
    }
}

private func sumOfSquaresFloat(
    _ data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int, channels: Int,
) -> Double {
    var sumSq: Double = 0
    for ch in 0 ..< channels {
        let ptr = data[ch]
        for i in 0 ..< frames {
            sumSq += Double(ptr[i]) * Double(ptr[i])
        }
    }
    return sumSq
}

private func sumOfSquaresInt16(
    _ data: UnsafePointer<UnsafeMutablePointer<Int16>>, frames: Int, channels: Int,
) -> Double {
    let scale = 1.0 / 32768.0
    var sumSq: Double = 0
    for ch in 0 ..< channels {
        let ptr = data[ch]
        for i in 0 ..< frames {
            let s = Double(ptr[i]) * scale
            sumSq += s * s
        }
    }
    return sumSq
}

public enum MicCaptureError: LocalizedError {
    case noInputDevice
    case deviceUnavailable(uid: String)
    case deviceSelectionFailed(uid: String, status: OSStatus)
    case invalidHardwareFormat(sampleRate: Double, channelCount: UInt32)
    case firstBufferTimeout(timeout: TimeInterval, callbacks: Int, frames: Int)
    case restartLimitExceeded(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone hardware available"
        case let .deviceUnavailable(uid):
            "El micrófono seleccionado ya no está disponible (\(uid)). Conéctalo de nuevo o elige otro."
        case let .deviceSelectionFailed(uid, status):
            "No se pudo activar el micrófono seleccionado (\(uid), OSStatus \(status)). Elige otro dispositivo."
        case let .invalidHardwareFormat(sampleRate, channelCount):
            "Microphone reported an invalid format (\(sampleRate) Hz, \(channelCount) ch)"
        case let .firstBufferTimeout(timeout, callbacks, frames):
            "El micrófono se inició pero no entregó audio en \(String(format: "%.1f", timeout)) s (callbacks: \(callbacks), frames: \(frames))."
        case let .restartLimitExceeded(maximum):
            "La captura de micrófono se reinició \(maximum) veces sin estabilizarse."
        }
    }
}

// MARK: - Debug fault injection (issue #379 recovery verification)

private extension MicCaptureHandler {
    /// In production (`debugFault == nil`) returns `real` unchanged. Under an
    /// injected fault it returns an invalid (0 Hz) tap format exactly once —
    /// the condition that makes installTapOnBus raise
    /// `IsFormatSampleRateAndChannelCountValid` — so the e2e can verify the
    /// NSException recovery path end-to-end.
    func resolveTapInstallFormat(default real: AVAudioFormat) -> AVAudioFormat {
        guard injectBadTapFormatOnce else { return real }
        injectBadTapFormatOnce = false
        guard let bad = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false,
        ) else { return real }
        logger.warning("[debug-fault] installing invalid (0 Hz) tap format (issue #379 repro)")
        return bad
    }

    /// No-op in production. When a `DebugTapFault` was injected: once, after the
    /// first successful start, schedule a single self-triggered device-change
    /// restart whose tap install uses the bad format. Drives the real
    /// handleDeviceChange → executeRestart → startEngine path so the
    /// reproduction exercises production code, not a shortcut.
    func armDebugFaultIfNeeded() {
        guard let debugFault, !debugFaultArmed else { return }
        debugFaultArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + debugFault.triggerRestartAfter) { [weak self] in
            guard let self, self.isRecording else { return }
            logger.warning("[debug-fault] firing simulated mic device-change mid-recording (issue #379 repro)")
            self.injectBadTapFormatOnce = true
            self.handleDeviceChange(trigger: .engineConfigurationChanged)
        }
    }
}
