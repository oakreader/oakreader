import Foundation

public enum CredentialResolver: Sendable {
    /// Synchronous resolve — returns whatever is immediately available without
    /// touching the network. OAuth providers return nil here once their access
    /// token expires, even if a refresh token is stored. Use [`resolveAsync`]
    /// when you can `await` — that variant will refresh.
    ///
    /// Resolution order: Keychain API key → environment variable → cached OAuth access token.
    public static func resolve(for providerId: String) -> String? {
        if let key = nonOAuthCredential(for: providerId) {
            return key
        }

        // OAuth: cached access token only (no refresh in the sync path).
        if let token = OAuthTokenStore.accessToken(for: providerId) {
            return applyProviderSpecificExchange(token: token, providerId: providerId)
        }
        return nil
    }

    /// Async resolve — same as [`resolve`] but auto-refreshes OAuth access
    /// tokens via the stored refresh token when the cached one has expired.
    /// This is the path the chat / Test Connection / model-discovery flows
    /// should use.
    public static func resolveAsync(for providerId: String) async -> String? {
        if let key = nonOAuthCredential(for: providerId) {
            return key
        }

        if let token = await OAuthTokenStore.validAccessToken(for: providerId) {
            return applyProviderSpecificExchange(token: token, providerId: providerId)
        }
        return nil
    }

    /// True iff we either have valid credentials right now OR can recover them
    /// without user interaction (i.e. an OAuth refresh token is stored).
    ///
    /// This is what drives the "Connected" badge in Settings, so it needs to
    /// stay true through expiry — otherwise the badge ping-pongs every hour as
    /// the access token rolls over.
    public static func hasCredentials(for providerId: String) -> Bool {
        if nonOAuthCredential(for: providerId) != nil {
            return true
        }
        return OAuthTokenStore.hasRecoverableTokenSet(for: providerId)
    }

    // MARK: - Shared helpers

    /// API-key / env-var / local-provider sentinel. Pulled out so the sync
    /// and async resolvers can share the non-OAuth path.
    private static func nonOAuthCredential(for providerId: String) -> String? {
        if let key = KeychainService.apiKey(forProviderId: providerId) {
            return key
        }
        guard let info = ProviderRegistry.shared.provider(for: providerId) else {
            return nil
        }
        if case .apiKey(let envVar) = info.authStrategy, let envName = envVar,
           let value = ProcessInfo.processInfo.environment[envName], !value.isEmpty {
            return value
        }
        // Local providers (Ollama, LM Studio) need no credential — return an empty
        // sentinel so the router builds a provider instead of throwing missingAPIKey.
        if case .none = info.authStrategy {
            return ""
        }
        return nil
    }

    /// GitHub Copilot is special — its OAuth token is exchanged for a short-lived
    /// Copilot API token via a second API call.
    private static func applyProviderSpecificExchange(token: String, providerId: String) -> String? {
        if providerId == "github-copilot" {
            return CopilotTokenExchange.cachedCopilotToken(gitHubToken: token)
        }
        return token
    }
}

// MARK: - Copilot Two-Step Token Exchange

/// Exchanges a GitHub OAuth token for a Copilot API token (cached for the token's lifetime).
enum CopilotTokenExchange {
    private static let lock = NSLock()
    private static var cachedToken: String?
    private static var cachedExpiry: Date?

    static func cachedCopilotToken(gitHubToken: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        // Return cached token if still valid
        if let token = cachedToken, let expiry = cachedExpiry, Date() < expiry {
            return token
        }

        // Synchronous exchange (called from non-async context)
        // Use a semaphore to bridge async/sync boundary
        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached {
            result = await Self.exchangeToken(gitHubToken: gitHubToken)
            semaphore.signal()
        }
        semaphore.wait()

        return result
    }

    private static func exchangeToken(gitHubToken: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/copilot_internal/v2/token") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(gitHubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String
        else {
            return nil
        }

        let expiresAt = json["expires_at"] as? Int
        cacheToken(token, expiresAt: expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        return token
    }

    /// Sync writer pulled out so async callers don't lock NSLock directly —
    /// Swift 6 forbids `NSLock.lock()` inside async functions.
    private static func cacheToken(_ token: String, expiresAt: Date?) {
        lock.lock()
        defer { lock.unlock() }
        cachedToken = token
        cachedExpiry = expiresAt
    }
}
