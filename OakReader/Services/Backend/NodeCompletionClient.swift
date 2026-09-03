import Foundation
import OakAI

/// `CompletionStreaming` over the Node sidecar. The shell keeps resolving the
/// provider (registry + endpoint overrides) and the credential (Keychain → env
/// var → OAuth); the sidecar only transports. Phase 3 moves resolution across.
struct NodeCompletionClient: CompletionStreaming {
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let info = ProviderRegistry.shared.provider(for: request.providerId) else {
                        throw LLMProviderError.unknownProvider(request.providerId)
                    }
                    var credential = request.overrideCredential
                    if credential == nil {
                        credential = await CredentialResolver.resolveAsync(for: request.providerId)
                        guard credential != nil else { throw LLMProviderError.missingAPIKey }
                    }
                    let api = BackendAPI(info.apiFormat)
                    let spec = BackendModelSpec(
                        api: api,
                        baseUrl: api.apiBase(fromEndpoint: info.baseURL),
                        id: request.model,
                        headers: info.customHeaders.isEmpty ? nil : info.customHeaders
                    )
                    let deltas = await NodeBackend.shared.complete(
                        model: spec,
                        apiKey: credential?.isEmpty == true ? nil : credential,
                        system: request.system,
                        user: request.user,
                        maxTokens: request.maxTokens
                    )
                    for try await delta in deltas {
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
}
