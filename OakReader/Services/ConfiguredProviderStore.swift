import Foundation
import OakAgent

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
    /// Models that the user has toggled off are excluded.
    var availableLLMModels: [(provider: ProviderInfo, model: ModelInfo)] {
        let disabled = Preferences.shared.disabledModelIds
        return configuredLLMProviders.flatMap { provider in
            provider.models
                .filter { !disabled.contains($0.id) }
                .map { (provider: provider, model: $0) }
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
