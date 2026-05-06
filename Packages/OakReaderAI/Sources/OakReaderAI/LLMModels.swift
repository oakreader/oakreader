import Foundation

// MARK: - Message types sent to LLM providers

public struct LLMMessage: Sendable {
    public let role: Role
    public let content: [ContentPart]

    public enum Role: String, Sendable {
        case system, user, assistant
    }

    public enum ContentPart: Sendable {
        case text(String)
        case imageBase64(data: String, mediaType: String) // "image/png", "image/jpeg"
        case toolUse(ToolCall)
        case toolResult(ToolResult)
    }

    public init(role: Role, text: String) {
        self.role = role
        self.content = [.text(text)]
    }

    public init(role: Role, content: [ContentPart]) {
        self.role = role
        self.content = content
    }

    /// Convenience: all text parts joined
    public var textContent: String {
        content.compactMap {
            if case .text(let t) = $0 { return t }
            return nil
        }.joined()
    }
}

// MARK: - Streaming types

public enum StreamChunk: Sendable {
    case delta(String)
    case toolUse(ToolCall)
    case finished(stopReason: String?)
    case error(String)
}

public enum StreamEvent: Sendable {
    case delta(String)
    case toolUseStarted(ToolUseRecord)
    case toolUsePending(ToolUseRecord)
    case toolUseCompleted(ToolUseRecord)
    case finished(ChatTurn)
    case error(Error)
}
