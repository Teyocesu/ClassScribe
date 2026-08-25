import CoreAudio

/// Native CATap source policies. System-output capture stores only the policy
/// to exclude ClassScribe itself; the AudioObjectIDs are ephemeral CoreAudio
/// evidence and are revalidated at every CATap construction.
public enum AppAudioCaptureSource: Equatable, Sendable {
    case application(processes: [pid_t])
    case systemOutput
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
