import Foundation

/// Snapshot of PDF context to pass across actor boundaries.
public struct PDFContextSnapshot: Sendable {
    public let fileName: String
    public let pageCount: Int
    public let currentPageIndex: Int
    public let currentPageText: String
    public let fullDocumentText: String?   // nil if not needed by skill
    public let selectedText: String?

    public init(
        fileName: String,
        pageCount: Int,
        currentPageIndex: Int,
        currentPageText: String,
        fullDocumentText: String? = nil,
        selectedText: String? = nil
    ) {
        self.fileName = fileName
        self.pageCount = pageCount
        self.currentPageIndex = currentPageIndex
        self.currentPageText = currentPageText
        self.fullDocumentText = fullDocumentText
        self.selectedText = selectedText
    }
}

/// Actor that coordinates message flow: builds prompts, routes to provider, persists turns.
public actor ChatEngine {
    private let router = ProviderRouter()
    private let store: ChatSessionStore

    /// Initialize with a per-document storage path for session files.
    public init(documentStoragePath: URL) {
        self.store = ChatSessionStore(documentStoragePath: documentStoragePath)
    }

    /// Initialize with default centralized storage (fallback).
    public init() {
        self.store = ChatSessionStore()
    }

    // MARK: - Send message

    public func send(
        userContent: String,
        attachments: [ChatAttachment],
        history: [ChatTurn],
        sessionId: UUID,
        config: ProviderConfig,
        skill: Skill?,
        pdfContext: PDFContextSnapshot?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // 1. Build user turn
                    let userTurn = ChatTurn(
                        role: .user,
                        content: userContent,
                        attachments: attachments
                    )
                    try await store.appendTurn(userTurn, sessionId: sessionId)
                    continuation.yield(.finished(userTurn))

                    // 2. Build system prompt
                    let systemPrompt = buildSystemPrompt(skill: skill, context: pdfContext)

                    // 3. Build LLM messages
                    let messages = buildMessages(
                        history: history,
                        userTurn: userTurn
                    )

                    // 4. Get provider and stream
                    let provider = try router.provider(for: config)
                    let stream = provider.sendMessage(
                        messages: messages,
                        model: config.model,
                        systemPrompt: systemPrompt,
                        maxTokens: config.maxTokens
                    )

                    // 5. Create assistant turn and stream deltas
                    var assistantTurn = ChatTurn(
                        role: .assistant,
                        content: "",
                        isStreaming: true,
                        skill: skill?.id
                    )

                    for try await chunk in stream {
                        switch chunk {
                        case .delta(let text):
                            assistantTurn.content += text
                            continuation.yield(.delta(text))
                        case .finished:
                            assistantTurn.isStreaming = false
                            try await store.appendTurn(assistantTurn, sessionId: sessionId)
                            continuation.yield(.finished(assistantTurn))
                            continuation.finish()
                            return
                        case .error(let msg):
                            assistantTurn.isStreaming = false
                            assistantTurn.error = msg
                            try await store.appendTurn(assistantTurn, sessionId: sessionId)
                            continuation.finish(throwing: LLMProviderError.streamError(msg))
                            return
                        }
                    }

                    // Stream ended without explicit finish
                    if assistantTurn.isStreaming {
                        assistantTurn.isStreaming = false
                        try await store.appendTurn(assistantTurn, sessionId: sessionId)
                        continuation.yield(.finished(assistantTurn))
                        continuation.finish()
                    }
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Session management

    public func loadSession(_ sessionId: UUID) async throws -> [ChatTurn] {
        try await store.loadTurns(sessionId: sessionId)
    }

    public func deleteSession(_ sessionId: UUID) async {
        await store.deleteSession(sessionId)
    }

    // MARK: - Private helpers

    private func buildSystemPrompt(skill: Skill?, context: PDFContextSnapshot?) -> String {
        var parts: [String] = []

        // Base system prompt
        parts.append("You are a helpful AI assistant integrated into OakReader, a PDF editor application.")

        // Skill prompt
        if let skill {
            parts.append(skill.systemPrompt)
        }

        // PDF context
        if let ctx = context {
            parts.append("The user has a PDF document open: \"\(ctx.fileName)\" (\(ctx.pageCount) pages).")
            parts.append("Current page: \(ctx.currentPageIndex + 1) of \(ctx.pageCount).")

            if let selected = ctx.selectedText, !selected.isEmpty {
                parts.append("Selected text:\n\"\"\"\n\(selected)\n\"\"\"")
            }

            // Determine context based on skill
            let contextMode = skill?.contextMode ?? .currentPage
            switch contextMode {
            case .fullDocument:
                if let fullText = ctx.fullDocumentText, !fullText.isEmpty {
                    let truncated = String(fullText.prefix(32000))
                    parts.append("Document text:\n\"\"\"\n\(truncated)\n\"\"\"")
                }
            case .currentPage:
                if !ctx.currentPageText.isEmpty {
                    parts.append("Current page text:\n\"\"\"\n\(ctx.currentPageText)\n\"\"\"")
                }
            case .selectedText:
                break // Already handled above
            case .none:
                break
            }
        }

        return parts.joined(separator: "\n\n")
    }

    private func buildMessages(history: [ChatTurn], userTurn: ChatTurn) -> [LLMMessage] {
        var messages: [LLMMessage] = []

        // Add history (skip system turns, they go in system prompt)
        for turn in history where turn.role != .system {
            let role: LLMMessage.Role = turn.role == .user ? .user : .assistant
            messages.append(LLMMessage(role: role, text: turn.content))
        }

        // Build user message with attachments
        var contentParts: [LLMMessage.ContentPart] = []

        for attachment in userTurn.attachments {
            switch attachment.type {
            case .textSelection:
                if let text = attachment.textContent {
                    contentParts.append(.text("[\(attachment.label)]\n> \(text)\n"))
                }
            case .imageCapture:
                if let imageData = attachment.imageData {
                    let base64 = imageData.base64EncodedString()
                    contentParts.append(.imageBase64(data: base64, mediaType: "image/png"))
                }
            }
        }

        contentParts.append(.text(userTurn.content))

        messages.append(LLMMessage(role: .user, content: contentParts))
        return messages
    }
}
