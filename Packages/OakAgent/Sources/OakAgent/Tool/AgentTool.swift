import Foundation

/// Protocol for tools that can be executed by the ``Agent``.
public protocol AgentTool: Sendable {
    /// Unique tool name (e.g. "read", "bash").
    var name: String { get }

    /// Human-readable description shown to the LLM.
    var description: String { get }

    /// JSON Schema describing the tool's input parameters.
    var inputSchema: [String: Any] { get }

    /// Execute the tool with the given context and return a result.
    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput
}

extension AgentTool {
    /// Convert this tool to a ``ToolDefinition`` for sending to an LLM.
    public var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, inputSchema: inputSchema)
    }
}
