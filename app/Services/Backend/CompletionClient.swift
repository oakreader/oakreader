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
    /// PNG data sent alongside the text, for a model that can see.
    ///
    /// The wire already carried image parts for the agentic loop; only this
    /// one-shot struct flattened everything to two strings.
    var images: [Data] = []
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

    /// Images first, then the text — the order every vision API expects, so the
    /// words read as being about the picture rather than the other way round.
    private static func parts(for request: CompletionRequest) -> [WirePart] {
        var parts: [WirePart] = request.images.map {
            .image(data: $0.base64EncodedString(), mimeType: "image/png")
        }
        parts.append(.text(request.user))
        return parts
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let params = RPC.CompleteParams(
                        providerId: request.providerId,
                        model: request.model,
                        system: request.system,
                        messages: [.user(parts: Self.parts(for: request))],
                        maxTokens: request.maxTokens,
                        apiKey: request.overrideCredential,
                        baseUrl: request.overrideBaseUrl
                    )
                    for try await event in await NodeBackend.shared.stream(
                        RPC.Method.complete, params: params
                    ) {
                        guard case .notification(let method, let raw) = event,
                              method == RPC.Method.chatDelta,
                              let p = try? RPCCoding.decode(RPC.ChatDeltaParams.self, from: raw)
                        else { continue }
                        continuation.yield(p.text)
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
