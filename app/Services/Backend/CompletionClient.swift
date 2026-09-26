import Foundation

/// Provider/model selection for one AI request. Replaces OakAI's
/// `ProviderConfig` — resolution (credentials, endpoints, model catalog)
/// happens in the Node backend; this is just the address.
struct AIRequestConfig: Sendable {
    var providerId: String
    var model: String
    /// pi-ai thinking level ("low" | "medium" | "high" | …); nil = no thinking.
    var reasoningEffort: String?

    init(providerId: String, model: String, reasoningEffort: String? = nil) {
        self.providerId = providerId
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

/// One stateless streaming completion — the contract behind translation,
/// word define/explain, chat-title generation, and Settings "Test Connection".
struct CompletionRequest: Sendable {
    var providerId: String
    var model: String
    var system: String?
    var user: String
    var maxTokens: Int = 4096
    /// Explicit credential (Test Connection verifies a key before it is saved).
    var overrideCredential: String? = nil
    /// Explicit endpoint base (Test Connection dry-runs a typed base URL).
    var overrideBaseUrl: String? = nil
}

protocol CompletionStreaming: Sendable {
    /// Yields text deltas; finishes when the model is done; throws on any failure.
    /// Cancel the consuming task to abort.
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<String, Error>
}

/// The completion transport. All AI traffic runs through the Node sidecar.
enum AIBackend {
    static let completions: any CompletionStreaming = NodeCompletionClient()
}

struct NodeCompletionClient: CompletionStreaming {
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let id = await NodeBackend.shared.makeRequestId(prefix: "c")
                    let command = BackendCommand(
                        id: id,
                        type: "complete",
                        providerId: request.providerId,
                        model: request.model,
                        system: request.system,
                        messages: [.user(parts: [.text(request.user)])],
                        maxTokens: request.maxTokens,
                        apiKey: request.overrideCredential,
                        baseUrl: request.overrideBaseUrl
                    )
                    for try await event in await NodeBackend.shared.events(for: command) {
                        if event.type == "delta", let text = event.text {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
