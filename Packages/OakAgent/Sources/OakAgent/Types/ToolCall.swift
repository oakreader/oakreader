import Foundation

/// An LLM's invocation of a tool.
public struct ToolCall: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let input: [String: String]

    public init(id: String, name: String, input: [String: String]) {
        self.id = id
        self.name = name
        self.input = input
    }
}
