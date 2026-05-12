import Foundation

/// High-level events emitted by ``ChatEngine`` during a send operation.
/// Bridges ``AgentEvent`` (from OakAgent) to app-level concerns like ``ChatTurn``.
public enum StreamEvent: Sendable {
    case delta(String)
    case toolUseStarted(ToolUseRecord)
    case toolUsePending(ToolUseRecord)
    case toolUseCompleted(ToolUseRecord)
    case finished(ChatTurn)
    case error(Error)
}
