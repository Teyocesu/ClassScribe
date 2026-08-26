import Foundation

/// A terminal condition that the native capture owner must preserve until the
/// control plane has stopped and validated the current attempt.
///
/// The category is deliberately small: source loss may offer the user the
/// explicitly selectable system-output source, while a durable-master failure
/// must never be presented as a source-recovery opportunity.
public enum CaptureNativeTerminalFailureCategory: String, Equatable, Sendable {
    case source
    case durableMaster
}

public struct CaptureNativeTerminalFailure: Equatable, Sendable {
    public let message: String
    public let category: CaptureNativeTerminalFailureCategory

    public init(
        message: String,
        category: CaptureNativeTerminalFailureCategory,
    ) {
        self.message = message
        self.category = category
    }
}
