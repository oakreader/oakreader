import Foundation

/// Raw chunks produced by an ``LLMProviderService`` during streaming.
public enum StreamChunk: Sendable {
    case delta(String)
    case toolUse(ToolCall)
    case finished(stopReason: String?)
    case error(String)
}
