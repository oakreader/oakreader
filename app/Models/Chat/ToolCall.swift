import Foundation

/// An LLM's invocation of a tool.
struct ToolCall: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let input: ToolInput

    init(id: String, name: String, input: ToolInput) {
        self.id = id
        self.name = name
        self.input = input
    }
}
