import Foundation

/// Result of a tool execution.
public struct ToolOutput: Sendable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    /// Convenience for a successful text result.
    public static func success(_ text: String) -> ToolOutput {
        ToolOutput(content: text)
    }

    /// Convenience for an error result.
    public static func error(_ message: String) -> ToolOutput {
        ToolOutput(content: message, isError: true)
    }
}
