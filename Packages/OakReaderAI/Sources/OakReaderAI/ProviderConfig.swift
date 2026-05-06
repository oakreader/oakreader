import Foundation

// MARK: - AI Provider (deprecated — use ProviderRegistry + providerId strings)

@available(*, deprecated, message: "Use ProviderRegistry with string provider IDs instead")
public enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case openai
    case anthropic
    case google

    public var id: String { rawValue }

    public var displayName: String {
        ProviderRegistry.shared.provider(for: rawValue)?.displayName ?? rawValue
    }

    public var defaultModel: String {
        ProviderRegistry.shared.provider(for: rawValue)?.defaultModelId ?? ""
    }

    public var models: [ModelInfo] {
        ProviderRegistry.shared.provider(for: rawValue)?.models ?? []
    }

    public var supportsVision: Bool { true }
}

// MARK: - Model Info (per-model metadata)

public struct ModelInfo: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let providerId: String
    public let contextWindow: Int
    public let maxTokens: Int
    public let reasoning: Bool
    public let supportsVision: Bool

    public init(id: String, name: String, providerId: String, contextWindow: Int, maxTokens: Int, reasoning: Bool, supportsVision: Bool) {
        self.id = id
        self.name = name
        self.providerId = providerId
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.reasoning = reasoning
        self.supportsVision = supportsVision
    }

    // Backward-compatible coding: "provider" key maps to providerId
    private enum CodingKeys: String, CodingKey {
        case id, name, providerId = "provider", contextWindow, maxTokens, reasoning, supportsVision
    }
}

// MARK: - Model Registry

public enum ModelRegistry {
    /// Look up model info by ID across all providers.
    public static func model(for id: String) -> ModelInfo? {
        ProviderRegistry.shared.model(for: id)
    }
}

// MARK: - Provider Configuration

public struct ProviderConfig: Codable, Sendable {
    public var providerId: String
    public var model: String

    /// Resolved model info — maxTokens come from here, not user config.
    public var modelInfo: ModelInfo? {
        ProviderRegistry.shared.provider(for: providerId)?.models.first { $0.id == model }
    }

    public var maxTokens: Int {
        modelInfo?.maxTokens ?? 4096
    }

    public init(
        providerId: String = "anthropic",
        model: String? = nil
    ) {
        self.providerId = providerId
        self.model = model ?? ProviderRegistry.shared.provider(for: providerId)?.defaultModelId ?? ""
    }

    // Backward-compatible coding: "provider" key maps to providerId
    private enum CodingKeys: String, CodingKey {
        case providerId = "provider"
        case model
    }
}
