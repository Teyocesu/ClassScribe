import CoreAudio
import Foundation

public struct ValidatedAudioTarget: Equatable, Sendable {
    public let pid: pid_t
    public let audioObjectID: AudioObjectID

    public init(pid: pid_t, audioObjectID: AudioObjectID) {
        self.pid = pid
        self.audioObjectID = audioObjectID
    }
}

/// Pure handoff seam used by both startup reconciliation and the final tap
/// construction. The real implementation supplies CoreAudio translation plus
/// a PID round-trip check; tests can inject deterministic SDK-shaped results.
public enum AudioTargetValidation {
    public static func translateAndValidate(
        _ pids: [pid_t],
        translate: (pid_t) -> AudioObjectID?,
        roundTrip: (pid_t, AudioObjectID) -> Bool,
    ) -> [ValidatedAudioTarget] {
        pids.compactMap { pid in
            guard pid > 0,
                  let objectID = translate(pid),
                  objectID != AudioObjectID(kAudioObjectUnknown),
                  roundTrip(pid, objectID) else { return nil }
            return ValidatedAudioTarget(pid: pid, audioObjectID: objectID)
        }
    }
}

/// Translates PIDs to CoreAudio process `AudioObjectID`s for `CATapDescription`.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// Whether CoreAudio has published an audio-process object for at least one
    /// candidate PID. A freshly launched player can be alive for a short window
    /// before this becomes true; hosts use this probe to await registration
    /// asynchronously instead of blocking the main actor or failing the first
    /// capture attempt.
    public static func hasRegisteredAudioProcess(in pids: [pid_t]) -> Bool {
        !validatedAudioTargets(in: pids).isEmpty
    }

    /// Returns only PIDs whose CoreAudio process object can be translated and
    /// whose `kAudioProcessPropertyPID` round-trip still names that PID.
    /// This is a startup diagnostic snapshot; callers must re-run it immediately
    /// before constructing a CATapDescription.
    public static func validatedAudioProcessPIDs(in pids: [pid_t]) -> [pid_t] {
        validatedAudioTargets(in: pids).map(\.pid)
    }

    public static func validatedAudioTargets(in pids: [pid_t]) -> [ValidatedAudioTarget] {
        AudioTargetValidation.translateAndValidate(
            pids,
            translate: rawTranslatePID,
            roundTrip: audioObjectMatchesPID,
        )
    }

    /// Translate every stored PID and return (pid, audioObjectID) pairs.
    /// PIDs that fail translation (helper has no audio-object entry, process
    /// exited between enumeration and tap creation) are dropped — that's
    /// expected for Electron helper trees where only the audio-emitting
    /// renderer owns an audio object. Throws when no PID at all could be
    /// translated, since the resulting tap would have nothing to listen to.
    ///
    /// Returns pairs (not parallel arrays) so callers can log per-PID
    /// without re-zipping against `pids` — `compactMap` would otherwise
    /// silently mis-align the two sequences.
    func translatePIDs() throws -> [(pid: pid_t, audioObjectID: AudioObjectID)] {
        let translated = Self.validatedAudioTargets(in: pids).map {
            (pid: $0.pid, audioObjectID: $0.audioObjectID)
        }
        guard !translated.isEmpty else {
            throw NSError(
                domain: "audiotap", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to translate any of \(pids.count) PIDs to audio objects",
                ],
            )
        }
        return translated
    }

    static func translatePID(_ pid: pid_t) -> AudioObjectID? {
        guard let objectID = rawTranslatePID(pid), audioObjectMatchesPID(pid, objectID) else {
            return nil
        }
        return objectID
    }

    private static func rawTranslatePID(_ pid: pid_t) -> AudioObjectID? {
        guard pid > 0 else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var mutablePid = pid
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &mutablePid, &size, &objectID,
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private static func audioObjectMatchesPID(_ pid: pid_t, _ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var translatedPID: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(
            objectID, &address,
            0, nil, &size, &translatedPID,
        )
        return status == noErr && translatedPID == pid
    }
}
