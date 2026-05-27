import Foundation

/// Raw chunks produced by an ``LLMProviderService`` during streaming.
public enum StreamChunk: Sendable {
    case delta(String)
    case thinking(String)
    case toolUse(ToolCall)
    /// Accumulated raw JSON of an in-progress tool call's input, emitted on each
    /// streaming delta so the UI can render tool input as it's generated.
    case toolInputDelta(id: String, name: String, partialJSON: String)
    case finished(stopReason: String?)
    case error(String)
}
