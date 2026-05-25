import Foundation

/// Routes to the correct LLM provider based on configuration.
public struct ProviderRouter: Sendable {
    public init() {}

    public func provider(for config: ProviderConfig) throws -> LLMProviderService {
        guard let credential = CredentialResolver.resolve(for: config.providerId) else {
            throw LLMProviderError.missingAPIKey
        }
        return try provider(for: config, credential: credential)
    }

    /// Create a provider with an explicit credential, bypassing CredentialResolver.
    public func provider(for config: ProviderConfig, credential: String) throws -> LLMProviderService {
        guard let info = ProviderRegistry.shared.provider(for: config.providerId) else {
            throw LLMProviderError.unknownProvider(config.providerId)
        }

        switch info.apiFormat {
        case .anthropicMessages:
            return AnthropicProvider(apiKey: credential, baseURL: info.baseURL, customHeaders: info.customHeaders)
        case .openaiCompletions:
            return OpenAIProvider(apiKey: credential, baseURL: info.baseURL, customHeaders: info.customHeaders)
        case .openaiResponses:
            return OpenAIResponsesProvider(apiKey: credential, baseURL: info.baseURL, customHeaders: info.customHeaders)
        case .googleGenerativeAI:
            return GoogleProvider(apiKey: credential, baseURL: info.baseURL, customHeaders: info.customHeaders)
        }
    }
}
