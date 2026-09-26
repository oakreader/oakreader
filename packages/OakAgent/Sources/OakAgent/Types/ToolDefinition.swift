import Foundation

/// Schema sent to an LLM describing a callable tool.
public struct ToolDefinition: @unchecked Sendable {
    public let name: String
    public let description: String
    /// JSON Schema describing the tool's input parameters.
    /// Must be JSON-serializable (composed of String, Int, Bool, Array, Dictionary).
    public let inputSchema: [String: Any]

    public init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
