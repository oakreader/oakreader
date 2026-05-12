import Foundation
import OakAI

@Observable
final class ConfiguredProviderStore {
    static let shared = ConfiguredProviderStore()

    private(set) var configuredLLMProviderIds: Set<String> = []

    var isElevenLabsConfigured: Bool {
        !Preferences.shared.elevenLabsAPIKey.isEmpty
    }

    /// All providers that have valid credentials configured.
    var configuredLLMProviders: [ProviderInfo] {
        ProviderRegistry.shared.allProviders.filter { configuredLLMProviderIds.contains($0.id) }
    }

    /// All models from configured providers, paired with their provider.
    var availableLLMModels: [(provider: ProviderInfo, model: ModelInfo)] {
        configuredLLMProviders.flatMap { provider in
            provider.models.map { (provider: provider, model: $0) }
        }
    }

    /// Providers that are not yet configured.
    var unconfiguredLLMProviders: [ProviderInfo] {
        ProviderRegistry.shared.allProviders.filter { !configuredLLMProviderIds.contains($0.id) }
    }

    private init() {
        refresh()
    }

    func refresh() {
        var ids = Set<String>()
        for provider in ProviderRegistry.shared.allProviders {
            if CredentialResolver.hasCredentials(for: provider.id) {
                ids.insert(provider.id)
            }
        }
        configuredLLMProviderIds = ids
    }
}
