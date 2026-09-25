import Foundation

/// One-time migration of AI provider *configuration* into the Node backend:
/// - base-URL overrides from UserDefaults (`providerEndpoints.v1`)
/// - local provider URLs from UserDefaults (`localProviders.v1`)
///
/// API keys are not migrated, because there is nowhere to migrate them to: the
/// backend reads credentials back out of this app's Keychain over the protocol
/// (`BackendCredentialResponder`), and a key saved under the old plain-string
/// scheme is served as a fallback there. The Keychain never stopped being the
/// store.
///
/// OAuth sign-ins (Codex, Copilot) are not migrated — token shapes differ;
/// users re-connect once from Settings.
enum BackendCredentialMigrator {
    private static let doneKey = "backendCredentialMigration.v1"

    static func runIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        guard await NodeBackend.shared.ensureRunning() else { return }  // retry next launch

        let catalog = AIProviderCatalog.shared
        await catalog.refresh()
        guard catalog.backendError == nil, !catalog.providers.isEmpty else { return }

        // 1. Endpoint overrides (providerId → raw base URL, `#` marker preserved).
        if let data = UserDefaults.standard.data(forKey: "providerEndpoints.v1"),
           let overrides = try? JSONDecoder().decode([String: String].self, from: data) {
            for (providerId, baseUrl) in overrides where !baseUrl.isEmpty {
                _ = await catalog.setBaseUrl(baseUrl, providerId: providerId)
            }
        }

        // 2. Local providers (Ollama / LM Studio server URLs).
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
