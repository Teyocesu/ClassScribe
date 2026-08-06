/// Action to take when a mic device change is detected.
public enum MicRestartAction: Equatable {
    /// Restart the engine with the given device UID (nil = system default).
    case restart(deviceUID: String?)
    /// Skip the restart (not recording, or already restarting).
    case skip
}

public enum MicRestartTrigger: Equatable {
    case defaultInputChanged
    case engineConfigurationChanged
}

/// Pure decision logic for mic engine restarts.
/// Separated from MicCaptureHandler to enable unit testing without hardware.
public enum MicRestartPolicy {
    /// Decide whether and how to restart the mic engine after a device change.
    ///
    /// - Parameters:
    ///   - isRecording: Whether the handler is currently recording.
    ///   - isRestarting: Whether a restart is already in progress.
    ///   - selectedDeviceUID: The device UID the user explicitly selected (nil = system default).
    ///   - isSelectedDeviceAvailable: Whether the selected device is still connected.
    /// - Returns: The action to take.
    public static func decideRestart(
        isRecording: Bool,
        isRestarting: Bool,
        selectedDeviceUID: String?,
        isSelectedDeviceAvailable: Bool,
        trigger: MicRestartTrigger = .engineConfigurationChanged,
    ) -> MicRestartAction {
        guard isRecording else { return .skip }
        guard !isRestarting else { return .skip }

        if let uid = selectedDeviceUID, isSelectedDeviceAvailable {
            // A user-selected device is independent from macOS's *default*
            // input. Restarting it when some unrelated app changes the default
            // causes an AVAudioEngine configuration loop on built-in mics.
            if trigger == .defaultInputChanged { return .skip }
            return .restart(deviceUID: uid)
        }
        // No selected device, or selected device gone → use system default
        return .restart(deviceUID: nil)
    }
}
