import Foundation

/// Result of a tool execution, sent back to the LLM.
public struct ToolResult: Codable, Sendable {
    public let toolCallId: String
    public let toolName: String
    public let content: String
    public let isError: Bool

    public init(toolCallId: String, toolName: String, content: String, isError: Bool = false) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.isError = isError
    }
}
