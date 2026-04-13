import Foundation

/// Routes to the correct LLM provider based on configuration.
public struct ProviderRouter: Sendable {
    public init() {}

    public func provider(for config: ProviderConfig) throws -> LLMProviderService {
        switch config.provider {
        case .openai:
            guard let key = KeychainService.apiKey(for: .openai) else {
                throw LLMProviderError.missingAPIKey
            }
            return OpenAIProvider(apiKey: key)
        case .anthropic:
            guard let key = KeychainService.apiKey(for: .anthropic) else {
                throw LLMProviderError.missingAPIKey
            }
            return AnthropicProvider(apiKey: key)
        case .google:
            guard let key = KeychainService.apiKey(for: .google) else {
                throw LLMProviderError.missingAPIKey
            }
            return GoogleProvider(apiKey: key)
        }
    }
}
