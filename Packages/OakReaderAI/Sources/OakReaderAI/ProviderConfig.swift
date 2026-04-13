import Foundation

// MARK: - AI Provider

public enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case openai
    case anthropic
    case google

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google Gemini"
        }
    }

    public var defaultModel: String {
        switch self {
        case .openai: return "gpt-5.4"
        case .anthropic: return "claude-sonnet-4-6"
        case .google: return "gemini-2.5-flash"
        }
    }

    public var models: [ModelInfo] {
        switch self {
        case .openai:
            return [
                // GPT-5.4 series
                ModelInfo(id: "gpt-5.4", name: "GPT-5.4", provider: .openai, contextWindow: 1_000_000, maxTokens: 128_000, reasoning: false, supportsVision: true),
                ModelInfo(id: "gpt-5.4-mini", name: "GPT-5.4 mini", provider: .openai, contextWindow: 400_000, maxTokens: 128_000, reasoning: false, supportsVision: true),
                ModelInfo(id: "gpt-5.4-nano", name: "GPT-5.4 nano", provider: .openai, contextWindow: 400_000, maxTokens: 128_000, reasoning: false, supportsVision: true),
                // GPT-4.1 series
                ModelInfo(id: "gpt-4.1", name: "GPT-4.1", provider: .openai, contextWindow: 1_000_000, maxTokens: 32_768, reasoning: false, supportsVision: true),
                ModelInfo(id: "gpt-4.1-mini", name: "GPT-4.1 mini", provider: .openai, contextWindow: 1_000_000, maxTokens: 32_768, reasoning: false, supportsVision: true),
                ModelInfo(id: "gpt-4.1-nano", name: "GPT-4.1 nano", provider: .openai, contextWindow: 1_000_000, maxTokens: 32_768, reasoning: false, supportsVision: true),
                // Reasoning models
                ModelInfo(id: "o4-mini", name: "o4-mini", provider: .openai, contextWindow: 200_000, maxTokens: 100_000, reasoning: true, supportsVision: true),
                ModelInfo(id: "o3", name: "o3", provider: .openai, contextWindow: 200_000, maxTokens: 100_000, reasoning: true, supportsVision: true),
                ModelInfo(id: "o3-pro", name: "o3-pro", provider: .openai, contextWindow: 200_000, maxTokens: 100_000, reasoning: true, supportsVision: true),
            ]
        case .anthropic:
            return [
                ModelInfo(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", provider: .anthropic, contextWindow: 200_000, maxTokens: 16_000, reasoning: false, supportsVision: true),
                ModelInfo(id: "claude-opus-4-6", name: "Claude Opus 4.6", provider: .anthropic, contextWindow: 200_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
                ModelInfo(id: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5", provider: .anthropic, contextWindow: 200_000, maxTokens: 16_000, reasoning: false, supportsVision: true),
                ModelInfo(id: "claude-opus-4-5-20251101", name: "Claude Opus 4.5", provider: .anthropic, contextWindow: 200_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
                ModelInfo(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4", provider: .anthropic, contextWindow: 200_000, maxTokens: 16_000, reasoning: false, supportsVision: true),
                ModelInfo(id: "claude-opus-4-20250514", name: "Claude Opus 4", provider: .anthropic, contextWindow: 200_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
                ModelInfo(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", provider: .anthropic, contextWindow: 200_000, maxTokens: 8_192, reasoning: false, supportsVision: true),
            ]
        case .google:
            return [
                ModelInfo(id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro", provider: .google, contextWindow: 1_000_000, maxTokens: 65_536, reasoning: true, supportsVision: true),
                ModelInfo(id: "gemini-3.1-flash-lite-preview", name: "Gemini 3.1 Flash Lite", provider: .google, contextWindow: 1_000_000, maxTokens: 65_536, reasoning: false, supportsVision: true),
                ModelInfo(id: "gemini-3-pro-preview", name: "Gemini 3 Pro", provider: .google, contextWindow: 1_000_000, maxTokens: 65_536, reasoning: true, supportsVision: true),
                ModelInfo(id: "gemini-3-flash-preview", name: "Gemini 3 Flash", provider: .google, contextWindow: 1_000_000, maxTokens: 65_536, reasoning: false, supportsVision: true),
                ModelInfo(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", provider: .google, contextWindow: 1_000_000, maxTokens: 65_536, reasoning: true, supportsVision: true),
                ModelInfo(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", provider: .google, contextWindow: 1_000_000, maxTokens: 65_536, reasoning: true, supportsVision: true),
                ModelInfo(id: "gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite", provider: .google, contextWindow: 1_000_000, maxTokens: 65_536, reasoning: false, supportsVision: true),
            ]
        }
    }

    public var supportsVision: Bool { true }
}

// MARK: - Model Info (per-model metadata, like pi-mono)

public struct ModelInfo: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let provider: AIProvider
    public let contextWindow: Int
    public let maxTokens: Int
    public let reasoning: Bool
    public let supportsVision: Bool

    public init(id: String, name: String, provider: AIProvider, contextWindow: Int, maxTokens: Int, reasoning: Bool, supportsVision: Bool) {
        self.id = id
        self.name = name
        self.provider = provider
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.reasoning = reasoning
        self.supportsVision = supportsVision
    }
}

// MARK: - Model Registry

public enum ModelRegistry {
    /// Look up model info by ID across all providers.
    public static func model(for id: String) -> ModelInfo? {
        for provider in AIProvider.allCases {
            if let model = provider.models.first(where: { $0.id == id }) {
                return model
            }
        }
        return nil
    }
}

// MARK: - Provider Configuration

public struct ProviderConfig: Codable, Sendable {
    public var provider: AIProvider
    public var model: String

    /// Resolved model info — maxTokens, temperature come from here, not user config.
    public var modelInfo: ModelInfo? {
        provider.models.first { $0.id == model }
    }

    public var maxTokens: Int {
        modelInfo?.maxTokens ?? 4096
    }

    public init(
        provider: AIProvider = .anthropic,
        model: String? = nil
    ) {
        self.provider = provider
        self.model = model ?? provider.defaultModel
    }
}
