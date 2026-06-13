import Foundation
import Security

public enum OAuthTokenStore: Sendable {
    private static let servicePrefix = "com.oakreader.oauth"

    public struct TokenSet: Codable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresAt: Date?
        public let tokenType: String

        public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, tokenType: String = "Bearer") {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.tokenType = tokenType
        }

        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date() >= expiresAt
        }
    }

    // MARK: - Access Token (convenience)

    /// Synchronous access — returns the cached access token only if it's still valid.
    /// Does NOT attempt OAuth refresh. Use [`validAccessToken(for:)`] for the
    /// auto-refreshing async variant; this one is for sync UI checks where it's OK
    /// to fall back to "needs reconnect" momentarily.
    public static func accessToken(for providerId: String) -> String? {
        guard let tokenSet = loadTokenSet(for: providerId) else { return nil }
        if tokenSet.isExpired { return nil }
        return tokenSet.accessToken
    }

    /// True if we have a stored token set that's either still valid OR carries a
    /// refresh token we can use to recover. Drives the "Connected" badge so it
    /// doesn't go grey the moment the access token expires (refresh-on-next-use
    /// will quietly restore it).
    public static func hasRecoverableTokenSet(for providerId: String) -> Bool {
        guard let tokenSet = loadTokenSet(for: providerId) else { return false }
        if !tokenSet.isExpired { return true }
        return tokenSet.refreshToken != nil
    }

    /// Async access — returns a usable access token, refreshing via OAuth if the
    /// cached one has expired. Persists the rotated TokenSet so the next call has
    /// the live refresh token (OpenAI invalidates the old refresh token the moment
    /// it issues a new pair).
    ///
    /// Concurrent callers for the same provider are serialized through
    /// `RefreshCoordinator` so we never POST the same refresh token twice in
    /// parallel — the second response would arrive after the server has already
    /// burned that token.
    public static func validAccessToken(for providerId: String) async -> String? {
        if let tokenSet = loadTokenSet(for: providerId), !tokenSet.isExpired {
            return tokenSet.accessToken
        }
        return await RefreshCoordinator.shared.refreshIfNeeded(providerId: providerId)
    }

    // MARK: - CRUD

    @discardableResult
    public static func store(_ tokenSet: TokenSet, for providerId: String) -> Bool {
        let service = "\(servicePrefix).\(providerId)"
        guard let data = try? JSONEncoder().encode(tokenSet) else { return false }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]

        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[OAuthTokenStore] SecItemAdd failed for \(providerId): OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    public static func loadTokenSet(for providerId: String) -> TokenSet? {
        let service = "\(servicePrefix).\(providerId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    public static func delete(for providerId: String) {
        let service = "\(servicePrefix).\(providerId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Refresh Coordinator

/// Serializes OAuth refreshes per provider so two concurrent chat streams
/// don't both POST the same (single-use) refresh_token and lose the chain.
///
/// While a refresh is in flight, every additional caller awaits the same Task
/// instead of starting another one — pi's `refreshOAuthTokenWithLock` pattern,
/// adapted from cross-process file locking to in-process Swift concurrency
/// because OakReader is a single-process GUI app.
actor RefreshCoordinator {
    static let shared = RefreshCoordinator()

    private var inFlight: [String: Task<String?, Never>] = [:]

    func refreshIfNeeded(providerId: String) async -> String? {
        if let existing = inFlight[providerId] {
            return await existing.value
        }
        let task = Task<String?, Never> { [providerId] in
            let result = await Self.performRefresh(providerId: providerId)
            await Self.shared.clear(providerId: providerId)
            return result
        }
        inFlight[providerId] = task
        return await task.value
    }

    private func clear(providerId: String) {
        inFlight[providerId] = nil
    }

    /// Re-read keychain inside the critical section: another flow may have
    /// refreshed while this one was waiting in line. Cheap, and skips a
    /// network round-trip in the common case.
    private static func performRefresh(providerId: String) async -> String? {
        if let current = OAuthTokenStore.loadTokenSet(for: providerId), !current.isExpired {
            return current.accessToken
        }

        guard let tokenSet = OAuthTokenStore.loadTokenSet(for: providerId),
              let refreshToken = tokenSet.refreshToken else {
            return nil
        }

        guard let info = ProviderRegistry.shared.provider(for: providerId) else {
            return nil
        }

        let tokenURL: URL
        let clientId: String
        switch info.authStrategy {
        case .oauthPKCE(let config):
            tokenURL = config.tokenURL
            clientId = config.clientId
        case .oauthDeviceCode(let config):
            tokenURL = config.tokenURL
            clientId = config.clientId
        case .apiKey, .none:
            return nil
        }

        let service = OAuthService()
        do {
            let newTokenSet = try await service.refreshTokens(
                refreshToken: refreshToken,
                tokenURL: tokenURL,
                clientId: clientId
            )
            _ = OAuthTokenStore.store(newTokenSet, for: providerId)
            return newTokenSet.accessToken
        } catch {
            print("[OAuthTokenStore] Refresh failed for \(providerId): \(error)")
            return nil
        }
    }
}
