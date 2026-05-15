import Foundation

/// A message in a voice conversation.
public struct VoiceMessage: Sendable {
    public enum Role: Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String
    public let timestamp: Date

    public init(role: Role, content: String, timestamp: Date = Date()) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// Protocol for LLM interaction in the voice pipeline.
public protocol LLMService: Sendable {
    /// Stream a response from the LLM given the user message, conversation history, and system prompt.
    func respond(
        userMessage: String,
        history: [VoiceMessage],
        systemPrompt: String?
    ) -> AsyncThrowingStream<String, Error>
}
