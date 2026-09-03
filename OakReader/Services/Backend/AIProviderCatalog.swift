import Foundation

/// App-side mirror of the backend's provider catalog. Replaces the old
/// `ProviderRegistry` + `ConfiguredProviderStore` + `LocalProviderStore` +
/// `ProviderEndpointStore` quartet: the backend (`list_providers`) is the
/// single source of truth; this store caches it for synchronous SwiftUI reads
/// and proxies every mutation back to the backend.
@Observable
final class AIProviderCatalog {
    static let shared = AIProviderCatalog()

    private(set) var providers: [BackendProviderSummary] = []
    private(set) var isLoading = false
    /// Non-nil when the sidecar can't be reached (e.g. Node missing).
    private(set) var backendError: String?
    /// Cached chat API keys for providers that double as voice providers
    /// (OpenAI, Gemini) — voice construction is synchronous, so the keys are
    /// mirrored here on every refresh.
    private(set) var sharedVoiceKeys: [String: String] = [:]

    private init() {}

    // MARK: - Queries (sync, over the cached snapshot)

    func provider(for id: String) -> BackendProviderSummary? {
        providers.first { $0.id == id }
    }

    var configuredProviders: [BackendProviderSummary] {
        providers.filter { $0.auth.configured && !$0.models.isEmpty }
    }

    var unconfiguredProviders: [BackendProviderSummary] {
        providers.filter { !($0.auth.configured && !$0.models.isEmpty) }
    }

    /// All models from configured providers, minus user-disabled ones.
    var availableModels: [(provider: BackendProviderSummary, model: BackendModelSummary)] {
        let disabled = Preferences.shared.disabledModelIds
        return configuredProviders.flatMap { provider in
            provider.models
                .filter { !disabled.contains($0.id) }
                .map { (provider: provider, model: $0) }
        }
    }

    /// The provider chat should actually use: the stored preference when it is
    /// configured, otherwise the first configured provider.
    func resolvedProviderId(preferred: String) -> String {
        if provider(for: preferred)?.auth.configured == true { return preferred }
        return configuredProviders.first?.id ?? preferred
    }

    /// Validated model id for a provider: the stored choice when it exists in
    /// the catalog, else the provider's default, else "".
    func resolvedModelId(providerId: String, stored: String) -> String {
        guard let info = provider(for: providerId) else { return stored }
        if !stored.isEmpty, info.models.contains(where: { $0.id == stored }) { return stored }
        return info.defaultModel ?? info.models.first?.id ?? stored
    }

    func modelInfo(providerId: String, modelId: String) -> BackendModelSummary? {
        provider(for: providerId)?.models.first { $0.id == modelId }
    }

    // MARK: - Refresh

    @MainActor
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let id = await NodeBackend.shared.makeRequestId(prefix: "cat")
            let response = try await NodeBackend.shared.request(
                BackendCommand(id: id, type: "list_providers"))
            if let list = response.providers {
                providers = list
                backendError = nil
                var keys: [String: String] = [:]
                for pid in ["openai", "google"] where provider(for: pid)?.auth.configured == true {
                    keys[pid] = await Self.apiKey(for: pid)
                }
                sharedVoiceKeys = keys.compactMapValues { $0 }
            } else {
                backendError = response.message ?? "Failed to load providers"
            }
        } catch {
            backendError = error.localizedDescription
        }
    }

    // MARK: - Mutations (proxy to backend, then refresh)

    @discardableResult
    @MainActor
    private func perform(_ type: String, _ configure: (inout BackendCommand) -> Void) async -> String? {
        do {
            var command = BackendCommand(
                id: await NodeBackend.shared.makeRequestId(prefix: "m"), type: type)
            configure(&command)
            let response = try await NodeBackend.shared.request(command)
            if response.success != true {
                return response.message ?? "\(type) failed"
            }
            await refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns an error message, or nil on success.
    @MainActor
    func setAPIKey(_ key: String, providerId: String) async -> String? {
        await perform("set_api_key") { $0.providerId = providerId; $0.key = key }
    }

    @MainActor
    func deleteCredential(providerId: String) async -> String? {
        await perform("delete_credential") { $0.providerId = providerId }
    }

    /// Empty/nil clears the override.
    @MainActor
    func setBaseUrl(_ baseUrl: String?, providerId: String) async -> String? {
        await perform("set_base_url") { $0.providerId = providerId; $0.baseUrl = baseUrl }
    }

    @MainActor
    func setLocalUrl(_ baseUrl: String, providerId: String) async -> String? {
        if let error = await perform("set_local_url", { $0.providerId = providerId; $0.baseUrl = baseUrl }) {
            return error
        }
        return await refreshModels(providerId: providerId)
    }

    @MainActor
    func refreshModels(providerId: String? = nil) async -> String? {
        await perform("refresh_models") { $0.providerId = providerId }
    }

    /// Raw stored/resolved API key (used by voice providers that share chat keys).
    static func apiKey(for providerId: String) async -> String? {
        let id = await NodeBackend.shared.makeRequestId(prefix: "gk")
        let response = try? await NodeBackend.shared.request(
            BackendCommand(id: id, type: "get_api_key", providerId: providerId))
        guard let key = response?.apiKey, !key.isEmpty, key != "local" else { return nil }
        return key
    }
}
