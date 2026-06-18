import Foundation
import OakAgent

/// Per-provider base-URL overrides for cloud LLM providers.
///
/// Lets a user point any built-in provider (Anthropic, OpenAI, …) at a proxy / relay /
/// 中转站 while keeping its API key, model list, auth header, and request format unchanged.
///
/// The override is keyed by **`providerId`**, NOT by `apiFormat`: 14 built-in providers share
/// `.openaiCompletions`, so a format-keyed override would redirect all of them at once. Keying
/// by provider is the same granularity Cherry Studio uses (one base URL per provider entry).
///
/// Like `LocalProviderStore`, an overridden provider's `ProviderInfo` is rebuilt at runtime —
/// only its `baseURL` is swapped — and re-registered into `ProviderRegistry` at launch and
/// whenever the override changes. The path suffix per format is handled by
/// `LocalProviderURL.endpointURL(base:format:)`.
@Observable
final class ProviderEndpointStore {
    static let shared = ProviderEndpointStore()

    private static let defaultsKey = "providerEndpoints.v1"

    /// providerId → raw user-typed base URL (may carry a trailing `#` / `/` marker).
    private(set) var overrides: [String: String] = [:]

    /// The factory-default `ProviderInfo` per provider, snapshotted before any override is
    /// applied, so clearing an override can restore the original endpoint exactly.
    private var defaults: [String: ProviderInfo] = [:]

    private init() {
        for provider in ProviderRegistry.shared.allProviders {
            defaults[provider.id] = provider
        }
        load()
    }

    // MARK: - Queries

    /// The raw override string the user typed, or "" if none.
    func override(for id: String) -> String {
        overrides[id] ?? ""
    }

    func hasOverride(_ id: String) -> Bool {
        !(overrides[id] ?? "").isEmpty
    }

    /// The provider's factory-default endpoint as a string — for display and reset.
    func defaultBase(for id: String) -> String {
        defaults[id]?.baseURL.absoluteString ?? ""
    }

    /// What to show in the field: the override if set, otherwise the default endpoint.
    func displayedBase(for id: String) -> String {
        let o = overrides[id] ?? ""
        return o.isEmpty ? defaultBase(for: id) : o
    }

    // MARK: - Mutations

    /// Set (or, if empty/equal-to-default, clear) a provider's base-URL override, then
    /// re-register it. Clearing when the value resolves to the factory default keeps no
    /// stale override, so a future change to the built-in default propagates automatically.
    func setOverride(_ raw: String, for id: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = defaults[id] ?? ProviderRegistry.shared.provider(for: id)
        if trimmed.isEmpty {
            clearOverride(for: id)
            return
        }
        if let template,
           let resolved = LocalProviderURL.endpointURL(base: trimmed, format: template.apiFormat),
           resolved == template.baseURL {
            clearOverride(for: id)
            return
        }
        overrides[id] = trimmed
        persist()
        reregister(id: id)
    }

    /// Forget a provider's override and restore its built-in endpoint.
    func clearOverride(for id: String) {
        guard overrides[id] != nil else { return }
        overrides[id] = nil
        persist()
        if let original = defaults[id] {
            ProviderRegistry.shared.register(original)
        }
    }

    /// Re-register every overridden provider into the registry. Call once at launch,
    /// after the built-ins (and local providers) are in place.
    func applyAll() {
        for id in overrides.keys {
            reregister(id: id)
        }
    }

    // MARK: - Registry

    private func reregister(id: String) {
        guard let template = defaults[id] ?? ProviderRegistry.shared.provider(for: id),
              let raw = overrides[id],
              let endpoint = LocalProviderURL.endpointURL(base: raw, format: template.apiFormat)
        else { return }

        // Clone the template, swapping only the endpoint. Everything else (key/auth, models,
        // headers, format) is unchanged, so the existing request path keeps working.
        let info = ProviderInfo(
            id: template.id,
            displayName: template.displayName,
            apiFormat: template.apiFormat,
            baseURL: endpoint,
            defaultModelId: template.defaultModelId,
            models: template.models,
            authStrategy: template.authStrategy,
            customHeaders: template.customHeaders,
            displayOrder: template.displayOrder,
            isLocal: template.isLocal
        )
        ProviderRegistry.shared.register(info)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        overrides = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
