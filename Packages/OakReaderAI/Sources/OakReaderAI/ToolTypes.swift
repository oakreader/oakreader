import Foundation

// MARK: - Tool Definition (sent to LLM)

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

// MARK: - Tool Call (returned by LLM)

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

// MARK: - Tool Result (sent back to LLM)

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

// MARK: - Tool Use Record (persisted in JSONL and rendered in UI)

public struct ToolUseRecord: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let input: [String: String]
    public var result: String?
    public var isError: Bool

    public init(id: String, name: String, input: [String: String], result: String? = nil, isError: Bool = false) {
        self.id = id
        self.name = name
        self.input = input
        self.result = result
        self.isError = isError
    }

    public init(from toolCall: ToolCall) {
        self.id = toolCall.id
        self.name = toolCall.name
        self.input = toolCall.input
        self.result = nil
        self.isError = false
    }

    public var isExecuting: Bool {
        result == nil
    }

    /// Convenience: extract file path from input for display.
    public var filePath: String? {
        input["path"]
    }
}
