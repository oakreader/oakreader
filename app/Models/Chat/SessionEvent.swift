import Foundation

/// High-level events emitted during a send operation, bridging the backend's
/// protocol events to app-level concerns like ``Turn``. Produced by the app's
/// `BackendChatEngine`, which replaced this package's in-process agent loop.
enum SessionEvent: Sendable {
    case delta(String)
    case thinkingDelta(String)
    /// A tool call the model is still writing: its arguments parsed so far.
    case toolInputDelta(id: String, name: String, input: ToolInput)
    /// The model stopped thinking: its first text or tool call arrived.
    case thinkingFinished(seconds: Double)
    case toolUseStarted(ToolUseRecord)
    case toolUsePending(ToolUseRecord)
    case toolUseCompleted(ToolUseRecord)
    case finished(Turn)
    case error(Error)
}
