import Foundation
import Network

/// Lightweight NWListener-based HTTP server for OAuth callbacks.
/// Starts on a specified port, waits for a single GET request to the callback path,
/// extracts code/state, returns success HTML, and shuts down.
public actor EphemeralHTTPServer {
    private let callbackPath: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<CallbackResult, Error>?

    public struct CallbackResult: Sendable {
        public let code: String
        public let state: String?
    }

    public init(callbackPath: String = "/auth/callback") {
        self.callbackPath = callbackPath
    }

    /// Start the server and wait for the OAuth callback. Returns the authorization code when received.
    /// Automatically cancels the listener when the calling Task is cancelled.
    public func waitForCallback(port: Int, timeoutSeconds: Int = 120) async throws -> CallbackResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                self.continuation = cont

                do {
                    let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: UInt16(port)))

                    listener.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .failed(let error):
                            Task { await self?.fail(with: error) }
                        case .waiting(let error):
                            // Port in use or network unavailable — fail instead of hanging.
                            Task { await self?.fail(with: error) }
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { await self?.handleConnection(connection) }
                    }

                    self.listener = listener
                    listener.start(queue: .global(qos: .userInitiated))

                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                        await self?.fail(with: OAuthError.timeout)
                    }
                } catch {
                    cont.resume(throwing: error)
                    self.continuation = nil
                }
            }
        } onCancel: { [self] in
            Task { await self.cancel() }
        }
    }

    /// Cancel the server and clean up resources.
    public func cancel() {
        fail(with: CancellationError())
    }

    /// Manually provide the authorization result (e.g. from a pasted redirect URL).
    /// Resolves the pending `waitForCallback` as if the browser callback arrived.
    public func provideManualResult(code: String, state: String? = nil) {
        succeed(with: CallbackResult(code: code, state: state))
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            Task { await self?.processRequest(connection: connection, data: data, error: error) }
        }
    }

    private func processRequest(connection: NWConnection, data: Data?, error: NWError?) {
        // Connection-level errors just drop the connection — don't fail the flow.
        guard error == nil, let data, let request = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }

        guard let parsed = HTTPRequestLine.parse(request) else {
            respond(connection: connection, status: "400 Bad Request", body: "Malformed request.")
            return
        }
        guard parsed.method == "GET" else {
            respond(connection: connection, status: "405 Method Not Allowed", body: "Only GET is supported.")
            return
        }
        // Ignore non-callback paths (e.g. /favicon.ico) without failing the flow.
        guard parsed.path == callbackPath else {
            respond(connection: connection, status: "404 Not Found", body: "Not found.")
            return
        }
        guard let code = parsed.queryItems?["code"] else {
            respond(connection: connection, status: "400 Bad Request", body: "Missing authorization code.")
            return
        }

        let successHTML = """
            <html><body style="font-family:system-ui;text-align:center;padding-top:60px;">
            <h2>Authorization Successful</h2>
            <p>You can close this window and return to OakReader.</p>
            </body></html>
            """
        respond(connection: connection, status: "200 OK", body: successHTML, raw: true)
        succeed(with: CallbackResult(code: code, state: parsed.queryItems?["state"]))
    }

    // MARK: - Response Helpers

    private func respond(connection: NWConnection, status: String, body: String, raw: Bool = false) {
        let content = raw ? body : "<html><body style=\"font-family:system-ui;text-align:center;padding-top:60px;\"><p>\(body)</p></body></html>"
        let http = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(content)"
        connection.send(content: http.data(using: .utf8)!, completion: .contentProcessed { _ in
            connection.cancel()
        })
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

// MARK: - Minimal HTTP Request Line Parser

private struct HTTPRequestLine {
    let method: String
    let path: String
    let queryItems: [String: String]?

    static func parse(_ raw: String) -> HTTPRequestLine? {
        guard let firstLine = raw.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let pathAndQuery = String(parts[1])
        guard let components = URLComponents(string: pathAndQuery) else { return nil }

        let items = components.queryItems?.reduce(into: [String: String]()) { dict, item in
            if let value = item.value { dict[item.name] = value }
        }

        return HTTPRequestLine(method: method, path: components.path, queryItems: items)
    }
}

// MARK: - OAuth Errors

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
