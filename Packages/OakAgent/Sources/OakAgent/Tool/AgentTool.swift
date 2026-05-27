import Foundation
@_exported import OakAI

// MARK: - Tool Category

/// Safety classification used by the permission system to decide whether a
/// tool invocation requires user confirmation.
public enum ToolCategory: String, Codable, Sendable {
    /// Read-only operations (read_document, search, etc.) — safe.
    case readOnly
    /// Write operations (write_file, edit_file).
    case write
    /// Dangerous / destructive operations (bash, shell commands).
    case dangerous
}

/// Protocol for tools that can be executed by the ``Agent``.
public protocol AgentTool: Sendable {
    /// Unique tool name (e.g. "read", "bash").
    var name: String { get }

    /// Human-readable description shown to the LLM.
    var description: String { get }

    /// JSON Schema describing the tool's input parameters.
    var inputSchema: [String: Any] { get }

    /// Safety category for the permission system. Defaults to `.readOnly`.
    var category: ToolCategory { get }

    /// Execute the tool with the given context and return a result.
    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput
}

extension AgentTool {
    /// Convert this tool to a ``ToolDefinition`` for sending to an LLM.
    public var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, inputSchema: inputSchema)
    }

    /// Default category — most tools are read-only.
    public var category: ToolCategory { .readOnly }
}
