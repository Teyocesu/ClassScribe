import Foundation

/// Small, local-only lifecycle log for physical microphone diagnostics.
/// It records device and engine metadata, never samples or transcript text.
public enum MicCaptureDiagnostics {
    private static let queue = DispatchQueue(label: "app.classscribe.mic-diagnostics")
    private static let maximumLogBytes = 256 * 1024

    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClassScribe", isDirectory: true)
            .appendingPathComponent("mic-capture.log")
    }

    public static func record(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let url = logURL
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attributes[.size] as? NSNumber,
                   size.intValue > maximumLogBytes {
                    try? FileManager.default.removeItem(at: url)
                }
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } catch {
                // Diagnostics must never interfere with real-time capture.
            }
        }
    }
}
