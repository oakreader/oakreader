import Foundation

/// High-level events emitted by ``AgentSession`` during a send operation.
/// Bridges ``AgentEvent`` (from OakAgent) to app-level concerns like ``Turn``.
public enum SessionEvent: Sendable {
    case delta(String)
    case thinkingDelta(String)
    case toolUseStarted(ToolUseRecord)
    case toolUsePending(ToolUseRecord)
    case toolUseCompleted(ToolUseRecord)
    case finished(Turn)
    case error(Error)
}
