import Foundation
import OakAI

/// One stateless streaming completion — the single contract behind translation,
/// word define/explain, chat-title generation, and Settings "Test Connection".
///
/// This is the seam for the Node backend migration (docs/architecture/
/// node-backend-migration.md): consumers depend on this instead of
/// `ProviderRouter`/`StreamChunk`, so the transport can move out of process
/// without touching feature code.
struct CompletionRequest: Sendable {
    var providerId: String
    var model: String
    var system: String?
    var user: String
    var maxTokens: Int = 4096
    /// Explicit credential (Test Connection verifies a key before it is saved);
    /// nil resolves normally (Keychain → env var → OAuth).
    var overrideCredential: String? = nil
}

protocol CompletionStreaming: Sendable {
    /// Yields text deltas; finishes when the model is done; throws on any failure
    /// (including provider-reported stream errors). Cancel the consuming task to abort.
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<String, Error>
}

enum CompletionStreamError: LocalizedError {
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .provider(let message): return message
        }
    }
}

/// In-process implementation on OakAI's `ProviderRouter`. The legacy path, and the
/// fallback whenever the Node sidecar is unavailable.
struct LocalCompletionClient: CompletionStreaming {
    private let router = ProviderRouter()

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let config = ProviderConfig(providerId: request.providerId, model: request.model)
                    let service: LLMProviderService
                    if let credential = request.overrideCredential {
                        service = try router.provider(for: config, credential: credential)
                    } else {
                        service = try await router.provider(for: config)
                    }
                    let chunks = service.sendMessage(
                        messages: [LLMMessage(role: .user, text: request.user)],
                        model: request.model,
                        systemPrompt: request.system,
                        maxTokens: request.maxTokens
                    )
                    for try await chunk in chunks {
                        switch chunk {
                        case .delta(let text):
                            continuation.yield(text)
                        case .error(let message):
                            throw CompletionStreamError.provider(message)
                        case .thinking, .toolUse, .toolInputDelta, .finished:
                            break
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
