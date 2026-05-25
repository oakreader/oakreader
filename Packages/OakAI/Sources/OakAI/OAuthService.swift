import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

public struct DeviceCodeResponse: Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: String
    public let expiresIn: Int
    public let interval: Int
}

public actor OAuthService {

    public init() {}

    // MARK: - PKCE Flow

    /// Initiate OAuth PKCE authorization: open browser, wait for callback, exchange code for tokens.
    /// - Parameter onManualCodeInput: Optional async closure that returns a user-pasted redirect URL or code.
    ///   Races with the browser callback — whichever resolves first wins (following pi's pattern).
    public func authorizePKCE(
        config: OAuthPKCEConfig,
        onManualCodeInput: (@Sendable () async throws -> String)? = nil
    ) async throws -> OAuthTokenStore.TokenSet {
        // 1. Generate PKCE verifier and challenge
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = UUID().uuidString

        // 2. Build authorization URL
        let redirectURI = "http://localhost:\(config.callbackPort)\(config.callbackPath)"
        var components = URLComponents(url: config.authorizationURL, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        for (key, value) in config.additionalAuthParams {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems

        let authURL = components.url!

        // 3. Start ephemeral HTTP server to receive callback
        let server = EphemeralHTTPServer(callbackPath: config.callbackPath)

        // 4. If manual input is available, start a task that races with the browser callback.
        //    Manual input resolves the server's continuation via provideManualResult.
        var manualTask: Task<Void, Never>?
        if let onManualCodeInput {
            manualTask = Task {
                do {
                    let input = try await onManualCodeInput()
                    let parsed = Self.parseAuthorizationInput(input)
                    if let code = parsed.code {
                        await server.provideManualResult(code: code, state: parsed.state)
                    }
                } catch {
                    // Cancelled or error — browser callback path still active.
                }
            }
        }

        // 5. Open browser
        #if canImport(AppKit)
        _ = await MainActor.run { NSWorkspace.shared.open(authURL) }
        #endif

        // 6. Wait for callback (from browser redirect OR manual input)
        let callback: EphemeralHTTPServer.CallbackResult
        do {
            callback = try await server.waitForCallback(port: config.callbackPort)
        } catch {
            manualTask?.cancel()
            await server.cancel()
            throw error
        }
        manualTask?.cancel()

        // Verify state (only if present — manual paste may omit it, following pi's pattern)
        if let callbackState = callback.state, callbackState != state {
            throw OAuthError.invalidCallback
        }

        // 7. Exchange code for tokens
        return try await exchangeCodeForTokens(
            code: callback.code,
            verifier: verifier,
            config: config
        )
    }

    // MARK: - Authorization Input Parsing

    /// Parse a pasted redirect URL, query string, or raw code into (code, state) components.
    /// Handles: full URL, query string with code=, code#state, or bare code value.
    static func parseAuthorizationInput(_ input: String) -> (code: String?, state: String?) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return (nil, nil) }

        // Try as full URL
        if let components = URLComponents(string: value) {
            let items = components.queryItems ?? []
            let code = items.first(where: { $0.name == "code" })?.value
            let state = items.first(where: { $0.name == "state" })?.value
            if code != nil { return (code, state) }
        }

        // Try code#state format
        if value.contains("#") {
            let parts = value.split(separator: "#", maxSplits: 1)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : nil)
        }

        // Try as query string (code=xxx&state=yyy)
        if value.contains("code=") {
            let components = URLComponents(string: "?\(value)")
            let items = components?.queryItems ?? []
            let code = items.first(where: { $0.name == "code" })?.value
            let state = items.first(where: { $0.name == "state" })?.value
            return (code, state)
        }

        // Treat as raw code
        return (value, nil)
    }

    // MARK: - Device Code Flow

    /// Initiate device code authorization. Returns the device code response for display, and a stream that resolves when the token is obtained.
    public func authorizeDeviceCode(config: DeviceCodeConfig) async throws -> (DeviceCodeResponse, Task<OAuthTokenStore.TokenSet, Error>) {
        // 1. Request device code
        var request = URLRequest(url: config.deviceAuthURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let bodyDict: [String: String] = [
            "client_id": config.clientId,
            "scope": config.scopes.joined(separator: " "),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed("Device code request failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verificationURI = json["verification_uri"] as? String
        else {
            throw OAuthError.tokenExchangeFailed("Invalid device code response")
        }

        let expiresIn = json["expires_in"] as? Int ?? 900
        let interval = json["interval"] as? Int ?? 5

        let deviceResponse = DeviceCodeResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            expiresIn: expiresIn,
            interval: interval
        )

        // 2. Start polling for token in background
        let pollTask = Task<OAuthTokenStore.TokenSet, Error> {
            try await self.pollForToken(
                deviceCode: deviceCode,
                config: config,
                interval: interval,
                expiresIn: expiresIn
            )
        }

        return (deviceResponse, pollTask)
    }

    // MARK: - Private PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncoded()
    }

    private func exchangeCodeForTokens(code: String, verifier: String, config: OAuthPKCEConfig) async throws -> OAuthTokenStore.TokenSet {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let redirectURI = "http://localhost:\(config.callbackPort)\(config.callbackPath)"
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        // URLComponents.percentEncodedQuery properly encodes form values
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw OAuthError.tokenExchangeFailed(body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw OAuthError.tokenExchangeFailed("Invalid token response")
        }

        let refreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? Int
        let tokenType = json["token_type"] as? String ?? "Bearer"

        return OAuthTokenStore.TokenSet(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            tokenType: tokenType
        )
    }

    // MARK: - Private Device Code Helpers

    private func pollForToken(deviceCode: String, config: DeviceCodeConfig, interval: Int, expiresIn: Int) async throws -> OAuthTokenStore.TokenSet {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var pollInterval = TimeInterval(interval)

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            guard !Task.isCancelled else { throw CancellationError() }

            var request = URLRequest(url: config.tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let bodyDict: [String: String] = [
                "client_id": config.clientId,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { continue }

            if httpResponse.statusCode == 200 {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accessToken = json["access_token"] as? String
                else {
                    throw OAuthError.tokenExchangeFailed("Invalid token response")
                }

                let refreshToken = json["refresh_token"] as? String
                let expiresIn = json["expires_in"] as? Int
                let tokenType = json["token_type"] as? String ?? "Bearer"

                return OAuthTokenStore.TokenSet(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiresAt: expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                    tokenType: tokenType
                )
            }

            // Parse error response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String
            {
                switch error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    pollInterval += 5
                    continue
                case "expired_token":
                    throw OAuthError.deviceCodeExpired
                case "access_denied":
                    throw OAuthError.deviceCodeDenied
                default:
                    throw OAuthError.tokenExchangeFailed(error)
                }
            }
        }

        throw OAuthError.deviceCodeExpired
    }
}

// MARK: - Base64 URL Encoding

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
