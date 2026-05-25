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

    public init(
        id: String,
        displayName: String,
        apiFormat: APIFormat,
        baseURL: URL,
        defaultModelId: String,
        models: [ModelInfo],
        authStrategy: AuthStrategy = .apiKey(envVar: nil),
        customHeaders: [String: String] = [:],
        displayOrder: Int = 100
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
    }

    // MARK: - Hashable (by id only — AuthStrategy is not Hashable)

    public static func == (lhs: ProviderInfo, rhs: ProviderInfo) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
