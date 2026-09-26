import Foundation

/// High-level events emitted during a send operation, bridging the backend's
/// protocol events to app-level concerns like ``Turn``. Produced by the app's
/// `BackendChatEngine`, which replaced this package's in-process agent loop.
public enum SessionEvent: Sendable {
    case delta(String)
    case thinkingDelta(String)
    /// Accumulated raw JSON of an in-progress tool call's input (streaming).
    case toolInputDelta(id: String, name: String, partialJSON: String)
    case toolUseStarted(ToolUseRecord)
    case toolUsePending(ToolUseRecord)
    case toolUseCompleted(ToolUseRecord)
    case finished(Turn)
    case error(Error)
}
