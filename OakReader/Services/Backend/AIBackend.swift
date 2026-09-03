import Foundation
import OakAI

/// Chooses the completion transport per request: the Node sidecar when enabled
/// and healthy, the in-process OakAI path otherwise. See
/// docs/architecture/node-backend-migration.md.
enum AIBackend {
    static let completions: any CompletionStreaming = RoutingCompletionClient()
}

struct RoutingCompletionClient: CompletionStreaming {
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let transport = await Self.route(request)
                do {
                    for try await delta in transport.stream(request) {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func route(_ request: CompletionRequest) async -> any CompletionStreaming {
        guard Preferences.shared.nodeBackendEnabled else { return LocalCompletionClient() }
        // OAuth-strategy providers (ChatGPT-login Codex, Copilot) stay on the
        // in-process path in Phase 1: their token exchange / non-standard wire
        // formats aren't ported to the sidecar yet.
        if let info = ProviderRegistry.shared.provider(for: request.providerId) {
            switch info.authStrategy {
            case .oauthPKCE, .oauthDeviceCode:
                return LocalCompletionClient()
            case .apiKey, .none:
                break
            }
        }
        guard await NodeBackend.shared.ensureRunning() else { return LocalCompletionClient() }
        return NodeCompletionClient()
    }
}
