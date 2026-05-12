import Foundation

/// Typed lifecycle events emitted by the ``Agent`` during a run.
public enum AgentEvent: Sendable {
    /// A text delta from the LLM response.
    case delta(String)
    /// A tool execution has started.
    case toolUseStarted(ToolUseRecord)
    /// A tool is awaiting user confirmation.
    case toolUsePending(ToolUseRecord)
    /// A tool execution has completed (with result).
    case toolUseCompleted(ToolUseRecord)
    /// The LLM finished a response. Contains the full text and any tool records for this iteration.
    case iterationCompleted(text: String, toolUses: [ToolUseRecord])
    /// An error occurred.
    case error(Error)
}
