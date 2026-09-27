import Foundation

/// Schema sent to an LLM describing a callable tool.
struct ToolDefinition: @unchecked Sendable {
    let name: String
    let description: String
    /// JSON Schema describing the tool's input parameters.
    /// Must be JSON-serializable (composed of String, Int, Bool, Array, Dictionary).
    let inputSchema: [String: Any]

    init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
