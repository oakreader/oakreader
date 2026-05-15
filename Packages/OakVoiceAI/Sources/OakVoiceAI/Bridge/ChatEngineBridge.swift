import Foundation
import OakAgent

/// Bridges OakAgent's ``AgentSession`` to the ``LLMService`` protocol.
///
/// Includes automatic retry with exponential back-off for transient errors
/// (overloaded, rate-limited, timeout) — only before any response deltas
/// have been streamed to avoid duplicate text.
public final class ChatEngineBridge: LLMService, @unchecked Sendable {
    private let session: AgentSession
    private let config: ProviderConfig
    private let sessionId: UUID

    private static let maxRetries = 3
    private static let baseRetryDelay: UInt64 = 500_000_000 // 0.5 s

    public init(
        chatEngine: AgentSession,
        config: ProviderConfig,
        sessionId: UUID = UUID()
    ) {
        self.session = chatEngine
        self.config = config
        self.sessionId = sessionId
    }

    // MARK: - LLMService

    public func respond(
        userMessage: String,
        history: [VoiceMessage],
        systemPrompt: String?
    ) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        let config = self.config
        let sessionId = self.sessionId
        let prompt = systemPrompt ?? "You are a helpful voice assistant."

        let chatHistory = history.map { msg -> Turn in
            let role: Turn.Role
            switch msg.role {
            case .system: role = .system
            case .user: role = .user
            case .assistant: role = .assistant
            }
            return Turn(role: role, content: msg.content, timestamp: msg.timestamp)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var lastError: Error?

                retryLoop: for attempt in 0..<Self.maxRetries {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }

                    if attempt > 0 {
                        let delay = Self.baseRetryDelay * UInt64(1 << (attempt - 1))
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                    }

                    do {
                        let engineStream = await session.send(
                            userContent: userMessage,
                            attachments: [],
                            history: chatHistory,
                            sessionId: sessionId,
                            config: config,
                            systemPrompt: prompt
                        )

                        var gotDelta = false
                        for try await event in engineStream {
                            guard !Task.isCancelled else { break }
                            switch event {
                            case .delta(let text):
                                gotDelta = true
                                continuation.yield(text)
                            case .error(let error):
                                if !gotDelta, Self.isTransient(error) {
                                    lastError = error
                                    continue retryLoop
                                }
                                continuation.finish(throwing: error)
                                return
                            case .thinkingDelta:
                                break
                            case .finished, .toolUseStarted, .toolUsePending, .toolUseCompleted:
                                break
                            }
                        }

                        continuation.finish()
                        return
                    } catch {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        if Self.isTransient(error) {
                            lastError = error
                            continue retryLoop
                        }
                        continuation.finish(throwing: VoiceAgentError.llmFailed(error.localizedDescription))
                        return
                    }
                }

                let msg = lastError?.localizedDescription ?? "Unknown error"
                continuation.finish(throwing: VoiceAgentError.llmFailed("\(msg) (after \(Self.maxRetries) attempts)"))
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private static func isTransient(_ error: Error) -> Bool {
        let desc = error.localizedDescription.lowercased()
        return ["overload", "rate limit", "rate_limit", "too many requests",
                "timeout", "timed out", "529", "503", "429"]
            .contains { desc.contains($0) }
    }
}
