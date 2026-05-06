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

    // MARK: - PKCE Flow

    /// Initiate OAuth PKCE authorization: open browser, wait for callback, exchange code for tokens.
    public func authorizePKCE(config: OAuthPKCEConfig) async throws -> OAuthTokenStore.TokenSet {
        // 1. Generate PKCE verifier and challenge
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = UUID().uuidString

        // 2. Build authorization URL
        var components = URLComponents(url: config.authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: "http://localhost:\(config.callbackPort)/callback"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        let authURL = components.url!

        // 3. Start ephemeral HTTP server to receive callback
        let server = EphemeralHTTPServer()

        // 4. Open browser
        await MainActor.run {
            #if canImport(AppKit)
            NSWorkspace.shared.open(authURL)
            #endif
        }

        // 5. Wait for callback
        let callback = try await server.waitForCallback(port: config.callbackPort)

        // Verify state
        if callback.state != state {
            throw OAuthError.invalidCallback
        }

        // 6. Exchange code for tokens
        return try await exchangeCodeForTokens(
            code: callback.code,
            verifier: verifier,
            config: config
        )
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

        let params = [
            "grant_type=authorization_code",
            "client_id=\(config.clientId)",
            "code=\(code)",
            "redirect_uri=http://localhost:\(config.callbackPort)/callback",
            "code_verifier=\(verifier)",
        ].joined(separator: "&")
        request.httpBody = params.data(using: .utf8)

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
