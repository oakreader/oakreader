import Foundation
import OakAI

// MARK: - Tool Use Status

public enum ToolUseStatus: String, Codable, Sendable {
    case pending = "awaitingConfirmation"
    case executing
    case completed
    case denied
}

// MARK: - Tool Use Record (persisted in JSONL and rendered in UI)

public struct ToolUseRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let input: ToolInput
    public var result: String?
    public var isError: Bool
    public var status: ToolUseStatus

    public init(id: String, name: String, input: ToolInput, result: String? = nil, isError: Bool = false, status: ToolUseStatus = .executing) {
        self.id = id
        self.name = name
        self.input = input
        self.result = result
        self.isError = isError
        self.status = status
    }

    public init(from toolCall: ToolCall) {
        self.id = toolCall.id
        self.name = toolCall.name
        self.input = toolCall.input
        self.result = nil
        self.isError = false
        self.status = .executing
    }

    // Custom Decodable for backward compatibility with old JSONL files without status field
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        input = try container.decode(ToolInput.self, forKey: .input)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        status = try container.decodeIfPresent(ToolUseStatus.self, forKey: .status) ?? (result != nil ? .completed : .executing)
    }

    public var isExecuting: Bool {
        status == .executing
    }

    /// Convenience: extract file path from input for display.
    public var filePath: String? {
        input["path"]
    }
}
