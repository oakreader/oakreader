import Foundation
import OakReaderAI

/// LLMService implementation that bridges to OakReaderAI's ChatEngine.
public final class ChatEngineBridge: LLMService, @unchecked Sendable {
    private let chatEngine: ChatEngine
    private let config: ProviderConfig
    private let sessionId: UUID

    /// - Parameters:
    ///   - chatEngine: The OakReaderAI chat engine to delegate to.
    ///   - config: Provider configuration (determines which LLM provider/model to use).
    ///   - sessionId: Session identifier for conversation persistence.
    public init(
        chatEngine: ChatEngine,
        config: ProviderConfig,
        sessionId: UUID = UUID()
    ) {
        self.chatEngine = chatEngine
        self.config = config
        self.sessionId = sessionId
    }

    public func respond(
        userMessage: String,
        history: [VoiceMessage],
        systemPrompt: String?
    ) -> AsyncThrowingStream<String, Error> {
        // Capture all values needed for the Task closure
        let chatEngine = self.chatEngine
        let config = self.config
        let sessionId = self.sessionId

        // Build a voice skill with the system prompt
        let skill: Skill? = systemPrompt.map { prompt in
            Skill(
                id: "voice-agent",
                name: "Voice Agent",
                description: "Voice conversation assistant",
                systemPrompt: prompt,
                icon: "waveform",
                contextMode: .none
            )
        }

        // Map VoiceMessage history to ChatTurn history
        let chatHistory = history.map { msg -> ChatTurn in
            let role: ChatTurn.ChatRole
            switch msg.role {
            case .system: role = .system
            case .user: role = .user
            case .assistant: role = .assistant
            }
            return ChatTurn(
                role: role,
                content: msg.content,
                timestamp: msg.timestamp
            )
        }

        return AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    // Call actor-isolated send() from async context
                    let engineStream = await chatEngine.send(
                        userContent: userMessage,
                        attachments: [],
                        history: chatHistory,
                        sessionId: sessionId,
                        config: config,
                        skill: skill,
                        pdfContext: nil,
                        toolExecutor: nil
                    )

                    for try await event in engineStream {
                        guard !Task.isCancelled else { break }
                        switch event {
                        case .delta(let text):
                            continuation.yield(text)
                        case .finished, .toolUseStarted, .toolUsePending, .toolUseCompleted:
                            break
                        case .error(let error):
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: VoiceAgentError.llmFailed(error.localizedDescription))
                    }
                }
            }

            // Cancel the underlying Task when the stream consumer stops iterating
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
