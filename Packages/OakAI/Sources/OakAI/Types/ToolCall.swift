import Foundation

/// An LLM's invocation of a tool.
public struct ToolCall: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let input: ToolInput

    public init(id: String, name: String, input: ToolInput) {
        self.id = id
        self.name = name
        self.input = input
    }
}
