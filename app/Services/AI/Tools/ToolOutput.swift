import Foundation

/// Result of a tool execution.
struct ToolOutput: Sendable {
    let content: String
    let isError: Bool

    init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    /// Convenience for a successful text result.
    static func success(_ text: String) -> ToolOutput {
        ToolOutput(content: text)
    }

    /// Convenience for an error result.
    static func error(_ message: String) -> ToolOutput {
        ToolOutput(content: message, isError: true)
    }
}
