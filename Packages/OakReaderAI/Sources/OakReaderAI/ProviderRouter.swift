import Foundation

/// Routes to the correct LLM provider based on configuration.
public struct ProviderRouter: Sendable {
    public init() {}

    public func provider(for config: ProviderConfig) throws -> LLMProviderService {
        guard let info = ProviderRegistry.shared.provider(for: config.providerId) else {
            throw LLMProviderError.unknownProvider(config.providerId)
        }

        guard let credential = CredentialResolver.resolve(for: config.providerId) else {
            throw LLMProviderError.missingAPIKey
        }

        switch info.apiFormat {
        case .anthropicMessages:
            return AnthropicProvider(apiKey: credential, baseURL: info.baseURL, customHeaders: info.customHeaders)
        case .openaiCompletions:
            return OpenAIProvider(apiKey: credential, baseURL: info.baseURL, customHeaders: info.customHeaders)
        case .googleGenerativeAI:
            return GoogleProvider(apiKey: credential, baseURL: info.baseURL, customHeaders: info.customHeaders)
        }
    }
}
