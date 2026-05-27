import Foundation

public enum CredentialResolver: Sendable {
    /// Resolve credentials for a provider: Keychain API key → environment variable → OAuth token.
    /// For GitHub Copilot, this also handles the two-step token exchange.
    public static func resolve(for providerId: String) -> String? {
        // 1. Keychain API key
        if let key = KeychainService.apiKey(forProviderId: providerId) {
            return key
        }

        // 2. Environment variable (if configured in provider info)
        if let info = ProviderRegistry.shared.provider(for: providerId) {
            if case .apiKey(let envVar) = info.authStrategy, let envName = envVar {
                if let value = ProcessInfo.processInfo.environment[envName], !value.isEmpty {
                    return value
                }
            }
            // Local providers (Ollama, LM Studio) need no credential — return an empty
            // sentinel so the router builds a provider instead of throwing missingAPIKey.
            if case .none = info.authStrategy {
                return ""
            }
        }

        // 3. OAuth token store
        if let token = OAuthTokenStore.accessToken(for: providerId) {
            // GitHub Copilot needs a second token exchange: GitHub OAuth → Copilot API token
            if providerId == "github-copilot" {
                return CopilotTokenExchange.cachedCopilotToken(gitHubToken: token)
            }
            return token
        }

        return nil
    }

    /// Check if any credential is available for the given provider.
    public static func hasCredentials(for providerId: String) -> Bool {
        resolve(for: providerId) != nil
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

        lock.lock()
        cachedToken = token
        cachedExpiry = expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        lock.unlock()

        return token
    }
}
