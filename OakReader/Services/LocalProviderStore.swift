import Foundation
import OakAgent

/// Manages on-machine OpenAI-compatible providers (Ollama, LM Studio).
///
/// Unlike cloud providers, these have no API key and a model list that varies per machine,
/// so their `ProviderInfo` is rebuilt at runtime: the user's chosen server URL and the
/// models discovered from `GET /v1/models` are persisted here and re-registered into the
/// `ProviderRegistry` at launch and whenever they change.
@Observable
final class LocalProviderStore {
    static let shared = LocalProviderStore()

    /// Persisted per-provider configuration. Presence in the map == the user has added it.
    struct Config: Codable, Equatable {
        var apiBase: String
        var modelIDs: [String]
    }

    private static let defaultsKey = "localProviders.v1"

    /// Static templates for the supported local providers (id → built-in definition).
    private static let templates: [String: ProviderInfo] = [
        BuiltInProviders.ollama.id: BuiltInProviders.ollama,
        BuiltInProviders.lmstudio.id: BuiltInProviders.lmstudio,
    ]

    private(set) var configs: [String: Config] = [:]

    private init() {
        load()
    }

    // MARK: - Queries

    /// True if `id` is one of the supported local providers.
    static func isLocalProvider(_ id: String) -> Bool {
        templates[id] != nil
    }

    func isEnabled(_ id: String) -> Bool {
        configs[id] != nil
    }

    /// The API base (e.g. `http://localhost:11434/v1`) the user configured, or the default.
    func apiBase(for id: String) -> String {
        if let stored = configs[id]?.apiBase, !stored.isEmpty {
            return stored
        }
        return Self.defaultAPIBase(for: id)
    }

    func modelIDs(for id: String) -> [String] {
        configs[id]?.modelIDs ?? []
    }

    /// The factory default API base, derived from the template's chat-completions URL.
    static func defaultAPIBase(for id: String) -> String {
        guard let template = templates[id] else { return "" }
        return LocalProviderURL.apiBase(fromChatURL: template.baseURL).absoluteString
    }

    // MARK: - Mutations

    /// Add or update a local provider with a discovered model list, then re-register it.
    func save(id: String, apiBase: String, modelIDs: [String]) {
        guard Self.isLocalProvider(id) else { return }
        configs[id] = Config(apiBase: apiBase, modelIDs: modelIDs)
        persist()
        reregister(id: id)
    }

    /// Remove a local provider: forget its config and restore the empty static template.
    func remove(id: String) {
        guard configs[id] != nil else { return }
        configs[id] = nil
        persist()
        if let template = Self.templates[id] {
            ProviderRegistry.shared.register(template)
        }
    }

    /// Re-register every configured local provider into the registry. Call once at launch.
    func applyAll() {
        for id in configs.keys {
            reregister(id: id)
        }
    }

    // MARK: - Registry

    private func reregister(id: String) {
        guard let template = Self.templates[id], let config = configs[id] else { return }
        guard let base = URL(string: config.apiBase) else { return }
        let chatURL = LocalProviderURL.chatURL(fromAPIBase: base)
        let models = config.modelIDs.map { modelID in
            ModelInfo(
                id: modelID,
                name: modelID,
                providerId: id,
                contextWindow: 32_768,
                maxTokens: 4_096,
                reasoning: false,
                supportsVision: false
            )
        }
        let info = ProviderInfo(
            id: template.id,
            displayName: template.displayName,
            apiFormat: template.apiFormat,
            baseURL: chatURL,
            defaultModelId: config.modelIDs.first ?? "",
            models: models,
            authStrategy: .none,
            customHeaders: template.customHeaders,
            displayOrder: template.displayOrder,
            isLocal: true
        )
        ProviderRegistry.shared.register(info)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Config].self, from: data)
        else { return }
        configs = decoded.filter { Self.isLocalProvider($0.key) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
