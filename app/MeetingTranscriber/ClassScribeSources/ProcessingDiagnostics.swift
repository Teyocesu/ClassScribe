import AudioTapLib
import Foundation

/// Opt-in, local-only timing marks for startup and finalization investigations.
/// The normal application path does not emit entries. No transcript, audio, or
/// file path is included in the log.
enum ProcessingDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["CLASSSCRIBE_PERF_DIAGNOSTICS"] == "1"

    @discardableResult
    static func mark(
        _ event: String,
        attempt: SessionAttemptID? = nil,
        since: TimeInterval? = nil,
        detail: String? = nil,
    ) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        guard enabled else { return now }

        var fields = [
            "processing",
            "event=\(event)",
            "mono_ms=\(Int(now * 1_000))",
            "attempt=\(attempt?.token ?? "none")",
        ]
        if let since {
            fields.append("elapsed_ms=\(Int(max(0, now - since) * 1_000))")
        }
        if let detail {
            fields.append("detail=\(detail)")
        }
        MicCaptureDiagnostics.record(fields.joined(separator: " "))
        return now
    }
}
