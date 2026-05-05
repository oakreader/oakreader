import Foundation

// MARK: - Provider Protocol

public protocol LLMProviderService: Sendable {
    func sendMessage(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int
    ) -> AsyncThrowingStream<StreamChunk, Error>

    func sendMessage(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int,
        tools: [ToolDefinition]?
    ) -> AsyncThrowingStream<StreamChunk, Error>
}

extension LLMProviderService {
    public func sendMessage(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int,
        tools: [ToolDefinition]?
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        // Default: ignore tools and delegate to the base method
        sendMessage(messages: messages, model: model, systemPrompt: systemPrompt, maxTokens: maxTokens)
    }
}

// MARK: - Provider Errors

public enum LLMProviderError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse(Int)
    case decodingError(String)
    case streamError(String)
    case networkError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key not configured. Open AI Settings to add your key."
        case .invalidResponse(let code): return "API returned status \(code)"
        case .decodingError(let msg): return "Failed to decode response: \(msg)"
        case .streamError(let msg): return "Stream error: \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .cancelled: return "Request cancelled"
        }
    }
}
