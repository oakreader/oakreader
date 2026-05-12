import Foundation
import Network

/// Lightweight NWListener-based HTTP server for OAuth callbacks.
/// Starts on a specified port, waits for a single GET /callback request, extracts code/state, returns success HTML, and shuts down.
public actor EphemeralHTTPServer {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<CallbackResult, Error>?

    public struct CallbackResult: Sendable {
        public let code: String
        public let state: String?
    }

    /// Start the server and wait for a callback. Returns the authorization code when received.
    public func waitForCallback(port: Int, timeoutSeconds: Int = 120) async throws -> CallbackResult {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            do {
                let params = NWParameters.tcp
                let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: UInt16(port)))

                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        Task { await self?.fail(with: error) }
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    Task { await self?.handleConnection(connection) }
                }

                self.listener = listener
                listener.start(queue: .global(qos: .userInitiated))

                // Timeout
                Task {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                    await self.fail(with: OAuthError.timeout)
                }
            } catch {
                cont.resume(throwing: error)
                self.continuation = nil
            }
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            Task {
                if let error {
                    await self?.fail(with: error)
                    return
                }

                guard let data, let requestString = String(data: data, encoding: .utf8) else {
                    await self?.fail(with: OAuthError.invalidCallback)
                    return
                }

                // Parse GET /callback?code=...&state=...
                guard let firstLine = requestString.split(separator: "\r\n").first else {
                    await self?.fail(with: OAuthError.invalidCallback)
                    return
                }

                let parts = firstLine.split(separator: " ")
                guard parts.count >= 2, parts[0] == "GET" else {
                    await self?.fail(with: OAuthError.invalidCallback)
                    return
                }

                let pathAndQuery = String(parts[1])
                guard let components = URLComponents(string: pathAndQuery),
                      let queryItems = components.queryItems,
                      let code = queryItems.first(where: { $0.name == "code" })?.value
                else {
                    await self?.fail(with: OAuthError.invalidCallback)
                    return
                }

                let state = queryItems.first(where: { $0.name == "state" })?.value

                // Send success HTML response
                let html = """
                    <html><body style="font-family:system-ui;text-align:center;padding-top:60px;">
                    <h2>Authorization Successful</h2>
                    <p>You can close this window and return to OakReader.</p>
                    </body></html>
                    """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(html)"
                let responseData = response.data(using: .utf8)!

                connection.send(content: responseData, completion: .contentProcessed { _ in
                    connection.cancel()
                })

                await self?.succeed(with: CallbackResult(code: code, state: state))
            }
        }
    }

    private func succeed(with result: CallbackResult) {
        listener?.cancel()
        listener = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func fail(with error: Error) {
        listener?.cancel()
        listener = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

public enum OAuthError: LocalizedError, Sendable {
    case timeout
    case invalidCallback
    case tokenExchangeFailed(String)
    case deviceCodeExpired
    case deviceCodeDenied

    public var errorDescription: String? {
        switch self {
        case .timeout: return "OAuth callback timed out"
        case .invalidCallback: return "Invalid OAuth callback received"
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .deviceCodeExpired: return "Device code expired. Please try again."
        case .deviceCodeDenied: return "Authorization was denied."
        }
    }
}
