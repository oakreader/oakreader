import Foundation
import OakAgent

/// One-time migration of AI provider configuration into the Node backend:
/// - API keys from the Keychain (the old OakAI credential store)
/// - base-URL overrides from UserDefaults (`providerEndpoints.v1`)
/// - local provider URLs from UserDefaults (`localProviders.v1`)
///
/// OAuth sign-ins (Codex, Copilot) are not migrated — token shapes differ;
/// users re-connect once from Settings. Keychain entries are left in place
/// (harmless, and a downgrade path).
enum BackendCredentialMigrator {
    private static let doneKey = "backendCredentialMigration.v1"

    static func runIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        guard await NodeBackend.shared.ensureRunning() else { return }  // retry next launch

        let catalog = AIProviderCatalog.shared
        await catalog.refresh()
        guard catalog.backendError == nil, !catalog.providers.isEmpty else { return }

        // 1. API keys: Keychain → backend, only where the backend has nothing.
        for provider in catalog.providers where !provider.auth.configured {
            if let key = KeychainService.apiKey(forProviderId: provider.id) {
                _ = await catalog.setAPIKey(key, providerId: provider.id)
            }
        }

        // 2. Endpoint overrides (providerId → raw base URL, `#` marker preserved).
        if let data = UserDefaults.standard.data(forKey: "providerEndpoints.v1"),
           let overrides = try? JSONDecoder().decode([String: String].self, from: data) {
            for (providerId, baseUrl) in overrides where !baseUrl.isEmpty {
                _ = await catalog.setBaseUrl(baseUrl, providerId: providerId)
            }
        }

        // 3. Local providers (Ollama / LM Studio server URLs).
        struct LocalConfig: Decodable { var apiBase: String }
        if let data = UserDefaults.standard.data(forKey: "localProviders.v1"),
           let configs = try? JSONDecoder().decode([String: LocalConfig].self, from: data) {
            for (providerId, config) in configs where !config.apiBase.isEmpty {
                _ = await catalog.setLocalUrl(config.apiBase, providerId: providerId)
            }
        }

        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
