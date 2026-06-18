import Foundation

// MARK: - API Format

public enum APIFormat: String, Codable, Sendable {
    case anthropicMessages
    case openaiCompletions
    case openaiResponses
    case googleGenerativeAI
}

// MARK: - Auth Strategy

public enum AuthStrategy: Sendable {
    case apiKey(envVar: String?)
    case oauthPKCE(OAuthPKCEConfig)
    case oauthDeviceCode(DeviceCodeConfig)
    case none
}

// MARK: - OAuth Configurations

public struct OAuthPKCEConfig: Sendable {
    public let clientId: String
    public let authorizationURL: URL
    public let tokenURL: URL
    public let scopes: [String]
    public let callbackPort: Int
    public let callbackPath: String
    public let additionalAuthParams: [String: String]

    public init(
        clientId: String,
        authorizationURL: URL,
        tokenURL: URL,
        scopes: [String],
        callbackPort: Int,
        callbackPath: String = "/callback",
        additionalAuthParams: [String: String] = [:]
    ) {
        self.clientId = clientId
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.callbackPort = callbackPort
        self.callbackPath = callbackPath
        self.additionalAuthParams = additionalAuthParams
    }
}

public struct DeviceCodeConfig: Sendable {
    public let clientId: String
    public let deviceAuthURL: URL
    public let tokenURL: URL
    public let scopes: [String]

    public init(clientId: String, deviceAuthURL: URL, tokenURL: URL, scopes: [String]) {
        self.clientId = clientId
        self.deviceAuthURL = deviceAuthURL
        self.tokenURL = tokenURL
        self.scopes = scopes
    }
}

// MARK: - Provider Info

public struct ProviderInfo: Identifiable, Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let apiFormat: APIFormat
    public let baseURL: URL
    public let defaultModelId: String
    public let models: [ModelInfo]
    public let authStrategy: AuthStrategy
    public let customHeaders: [String: String]
    /// Lower values appear first in the provider list. Default is 100.
    public let displayOrder: Int
    /// True for on-machine OpenAI-compatible servers (Ollama, LM Studio): no API key,
    /// editable base URL, and a model list discovered at runtime rather than hardcoded.
    public let isLocal: Bool

    public init(
        id: String,
        displayName: String,
        apiFormat: APIFormat,
        baseURL: URL,
        defaultModelId: String,
        models: [ModelInfo],
        authStrategy: AuthStrategy = .apiKey(envVar: nil),
        customHeaders: [String: String] = [:],
        displayOrder: Int = 100,
        isLocal: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.apiFormat = apiFormat
        self.baseURL = baseURL
        self.defaultModelId = defaultModelId
        self.models = models
        self.authStrategy = authStrategy
        self.customHeaders = customHeaders
        self.displayOrder = displayOrder
        self.isLocal = isLocal
    }

    // MARK: - Hashable (by id only — AuthStrategy is not Hashable)

    public static func == (lhs: ProviderInfo, rhs: ProviderInfo) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Local Provider URL Helpers

/// URL math for OpenAI-compatible local servers. A provider's `baseURL` stores the full
/// chat-completions endpoint (e.g. `http://localhost:11434/v1/chat/completions`); these
/// helpers convert between that, the API base (`.../v1`), and the models endpoint.
public enum LocalProviderURL {
    /// Strip a trailing `/chat/completions` to recover the API base (e.g. `.../v1`).
    public static func apiBase(fromChatURL chatURL: URL) -> URL {
        let s = chatURL.absoluteString
        let suffix = "/chat/completions"
        if s.hasSuffix(suffix) {
            return URL(string: String(s.dropLast(suffix.count))) ?? chatURL
        }
        return chatURL
    }

    /// Append `/chat/completions` to an API base, tolerating a trailing slash.
    public static func chatURL(fromAPIBase apiBase: URL) -> URL {
        appending("chat/completions", to: apiBase)
    }

    /// Append `/models` to an API base, tolerating a trailing slash.
    public static func modelsURL(fromAPIBase apiBase: URL) -> URL {
        appending("models", to: apiBase)
    }

    private static func appending(_ path: String, to base: URL) -> URL {
        var s = base.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/" + path) ?? base
    }

    // MARK: - Cloud Endpoint Override

    /// Build the full request endpoint from a user-typed base URL for a cloud provider
    /// (e.g. a proxy / relay / 中转站). The path suffix differs per API format, so the
    /// user supplies only the host/base and we append the format-specific path.
    ///
    /// Suffix-marker convention (matches Cherry Studio's, which relay vendors already
    /// document to their users):
    ///   - ending `#`  → use the URL **exactly** as typed (marker stripped); append nothing.
    ///   - otherwise   → treat as the API base and append this format's endpoint path,
    ///                    de-duplicating any `/v1` (or `/v1beta`) the user already typed.
    ///
    /// Returns `nil` for empty/invalid input so callers fall back to the default.
    public static func endpointURL(base rawInput: String, format: APIFormat) -> URL? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // `#` = send exactly as typed.
        if trimmed.hasSuffix("#") {
            return URL(string: String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces))
        }

        var base = trimmed
        while base.hasSuffix("/") { base.removeLast() }

        // (versionPrefix, tail) for each format. Default path == "\(versionPrefix)/\(tail)".
        let versionPrefix: String
        let tail: String
        switch format {
        case .anthropicMessages:  versionPrefix = "v1";     tail = "messages"
        case .openaiCompletions:  versionPrefix = "v1";     tail = "chat/completions"
        case .openaiResponses:    versionPrefix = "v1";     tail = "responses"
        case .googleGenerativeAI: versionPrefix = "v1beta"; tail = "models"
        }
        let fullSuffix = "\(versionPrefix)/\(tail)"

        let assembled: String
        if base.hasSuffix("/\(fullSuffix)") || base.hasSuffix(fullSuffix) {
            // User already typed the whole path.
            assembled = base
        } else if base.hasSuffix("/\(versionPrefix)") {
            // User typed `.../v1` — append only the tail.
            assembled = "\(base)/\(tail)"
        } else {
            assembled = "\(base)/\(fullSuffix)"
        }

        // Google's endpoint conventionally carries a trailing slash (model is appended later).
        return URL(string: format == .googleGenerativeAI ? "\(assembled)/" : assembled)
    }
}
