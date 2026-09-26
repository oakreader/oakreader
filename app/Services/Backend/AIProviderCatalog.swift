import Foundation

/// App-side mirror of the backend's provider catalog. Replaces the old
/// `ProviderRegistry` + `ConfiguredProviderStore` + `LocalProviderStore` +
/// `ProviderEndpointStore` quartet, all deleted with OakAI: the backend
/// (`list_providers`) is the
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
            let result = try await NodeBackend.shared.call(
                RPC.Method.providersList, params: RPC.ProvidersListParams(),
                as: RPC.ProvidersListResult.self)
            providers = result.providers ?? []
            backendError = nil
            var keys: [String: String] = [:]
            for pid in ["openai", "google"] where provider(for: pid)?.auth.configured == true {
                keys[pid] = await Self.apiKey(for: pid)
            }
            sharedVoiceKeys = keys.compactMapValues { $0 }
        } catch {
            backendError = error.localizedDescription
        }
    }

    // MARK: - Mutations (proxy to backend, then refresh)

    /// Every mutation is the same shape: call, refresh on success, surface the
    /// error message on failure. The error is an `RPCErrorObject` now, so a
    /// caller that wants to branch on `.isAuthFailure` can.
    @discardableResult
    @MainActor
    private func mutate<P: Encodable>(_ method: String, _ params: P) async -> String? {
        do {
            try await NodeBackend.shared.call(method, params: params)
            await refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns an error message, or nil on success.
    @MainActor
    func setAPIKey(_ key: String, providerId: String) async -> String? {
        await mutate(RPC.Method.credentialsSet,
                     RPC.CredentialsSetParams(providerId: providerId, key: key))
    }

    @MainActor
    func deleteCredential(providerId: String) async -> String? {
        await mutate(RPC.Method.credentialsDelete,
                     RPC.CredentialsDeleteParams(providerId: providerId))
    }

    /// Empty/nil clears the override.
    @MainActor
    func setBaseUrl(_ baseUrl: String?, providerId: String) async -> String? {
        await mutate(RPC.Method.configSetBaseUrl,
                     RPC.ConfigSetBaseUrlParams(providerId: providerId, baseUrl: baseUrl))
    }

    @MainActor
    func setLocalUrl(_ baseUrl: String, providerId: String) async -> String? {
        if let error = await mutate(RPC.Method.configSetLocalUrl,
                                    RPC.ConfigSetLocalUrlParams(providerId: providerId, baseUrl: baseUrl)) {
            return error
        }
        return await refreshModels(providerId: providerId)
    }

    @MainActor
    func refreshModels(providerId: String? = nil) async -> String? {
        await mutate(RPC.Method.modelsRefresh,
                     RPC.ModelsRefreshParams(providerId: providerId))
    }

    /// Raw stored/resolved API key (used by voice providers that share chat keys).
    static func apiKey(for providerId: String) async -> String? {
        let result = try? await NodeBackend.shared.call(
            RPC.Method.credentialsGet, params: RPC.CredentialsGetParams(providerId: providerId),
            as: RPC.CredentialsGetResult.self)
        guard let key = result?.apiKey, !key.isEmpty, key != "local" else { return nil }
        return key
    }
}
