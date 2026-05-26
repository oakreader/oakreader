import Foundation
import OakAI

/// Registry of available web search providers.
/// Resolves which provider to use based on user preference and available credentials.
final class WebSearchProviderRegistry: @unchecked Sendable {
    static let shared = WebSearchProviderRegistry()

    let allProviders: [any WebSearchProvider] = [
        DuckDuckGoSearchProvider(),
        BraveSearchProvider(),
        TavilySearchProvider(),
        ExaSearchProvider(),
        SerperSearchProvider(),
    ]

    /// Providers that require an API key.
    var keyedProviders: [any WebSearchProvider] {
        allProviders.filter(\.requiresAPIKey)
    }

    /// Resolve the active provider using this precedence:
    /// 1. User-selected provider in Preferences (if credentials available)
    /// 2. First provider with configured credentials
    /// 3. DuckDuckGo fallback (no key required)
    func activeProvider() -> any WebSearchProvider {
        let selectedId = Preferences.shared.webSearchProviderId

        // If user explicitly selected a provider, use it if credentials are available
        if selectedId != "auto",
           let selected = allProviders.first(where: { $0.id == selectedId }) {
            if !selected.requiresAPIKey || Self.hasAPIKey(for: selected) {
                return selected
            }
        }

        // Auto: find first keyed provider with credentials
        for provider in keyedProviders {
            if Self.hasAPIKey(for: provider) {
                return provider
            }
        }

        // Fallback: DuckDuckGo (always available)
        return allProviders[0]
    }

    /// All providers that currently have credentials configured.
    func configuredProviders() -> [any WebSearchProvider] {
        allProviders.filter { provider in
            !provider.requiresAPIKey || Self.hasAPIKey(for: provider)
        }
    }

    /// Look up a provider by ID.
    func provider(for id: String) -> (any WebSearchProvider)? {
        allProviders.first { $0.id == id }
    }

    /// Resolve API key for a web search provider.
    /// Fallback chain: Keychain → environment variable → nil.
    /// (CredentialResolver.resolve only checks env vars for ProviderRegistry-registered LLM providers,
    /// so web search providers need this explicit env var check.)
    static func resolveAPIKey(for provider: any WebSearchProvider) -> String? {
        // 1. Keychain
        if let key = KeychainService.apiKey(forProviderId: provider.id), !key.isEmpty {
            return key
        }
        // 2. Environment variable
        if let envVar = provider.envVar,
           let value = ProcessInfo.processInfo.environment[envVar], !value.isEmpty {
            return value
        }
        return nil
    }

    /// Check if a web search provider has credentials configured.
    static func hasAPIKey(for provider: any WebSearchProvider) -> Bool {
        resolveAPIKey(for: provider) != nil
    }
}
