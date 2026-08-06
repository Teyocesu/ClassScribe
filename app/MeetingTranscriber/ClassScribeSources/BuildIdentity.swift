import AudioTapLib
import Foundation

/// Build provenance injected into the local development app bundle by
/// `scripts/run_app.sh`. Keeping it in the bundle makes a physical test
/// auditable even when LaunchServices would otherwise reactivate an old PID.
enum BuildIdentity {
    private static let commitKey = "ClassScribeBuildCommit"
    private static let timestampKey = "ClassScribeBuildTimestamp"

    static let commit: String = Bundle.main.object(forInfoDictionaryKey: commitKey) as? String ?? "unknown"
    static let timestamp: String = Bundle.main.object(forInfoDictionaryKey: timestampKey) as? String ?? "unknown"
    static let executablePath = (Bundle.main.executableURL
        ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.path
    static let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path

    static var displayLabel: String {
        "Build \(commit) · \(timestamp)"
    }

    static var provenanceLabel: String {
        "\(displayLabel) · \(bundlePath)"
    }

    static func recordLaunch() {
        MicCaptureDiagnostics.record(
            "app launch commit=\(commit) builtAt=\(timestamp) executable=\(executablePath) bundle=\(bundlePath) bundleID=\(Bundle.main.bundleIdentifier ?? "unknown")"
        )
    }
}
