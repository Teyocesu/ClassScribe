import CoreAudio

/// Native CATap source kinds. The system-output variant is deliberately
/// represented by the validated process-object IDs to exclude, not by an
/// application PID list. This keeps the global tap boundary explicit.
public enum AppAudioCaptureSource: Equatable, Sendable {
    case application(processes: [pid_t])
    case systemOutput(excludingProcessObjectIDs: [AudioObjectID])
}

/// Already validated object IDs handed to the SDK construction boundary.
/// Application PIDs remain in `AppAudioCaptureSource` so they can be
/// retranslated on a device restart; this type prevents that distinction from
/// being lost at the final CATap call.
public enum CATapDescriptionSource: Equatable, Sendable {
    case application(processObjectIDs: [AudioObjectID])
    case systemOutput(excludingProcessObjectIDs: [AudioObjectID])
}

/// Single construction boundary for the two CATap policies used by the
/// product. Keeping the SDK initializers here makes it hard for a future
/// system-output caller to accidentally enumerate every process instead.
@available(macOS 14.2, *)
public enum CATapDescriptionFactory {
    public static func make(for source: CATapDescriptionSource) -> CATapDescription {
        switch source {
        case let .application(processObjectIDs):
            return CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        case let .systemOutput(excludingProcessObjectIDs):
            return CATapDescription(
                stereoGlobalTapButExcludeProcesses: excludingProcessObjectIDs,
            )
        }
    }
}
