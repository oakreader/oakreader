import Foundation
import OakAgent

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

    /// Initialize with a centralized chats directory.
    public init(chatsDirectory: URL) {
        self.store = ChatSessionStore(baseDirectory: chatsDirectory)
    }

    // MARK: - Send message

    public func send(
        userContent: String,
        attachments: [ChatAttachment],
        history: [ChatTurn],
        sessionId: UUID,
        config: ProviderConfig,
        skill: Skill?,
        pdfContext: PDFContextSnapshot?,
        tools: [any AgentTool]? = nil,
        toolContext: ToolExecutionContext? = nil,
        agentSkills: [AgentSkill] = [],
        toolConfirmation: (@Sendable (ToolCall) async -> Bool)? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. Build user turn
                    try Task.checkCancellation()
                    let userTurn = ChatTurn(
                        role: .user,
                        content: userContent,
                        attachments: attachments
                    )
                    try await store.appendTurn(userTurn, sessionId: sessionId)
                    continuation.yield(.finished(userTurn))

                    // 2. Build system prompt
                    var systemPrompt = buildSystemPrompt(skill: skill, context: pdfContext)

                    // Append agent skills listing (file-based skills)
                    let skillsBlock = SkillPromptFormatter.formatForPrompt(agentSkills)
                    if !skillsBlock.isEmpty {
                        systemPrompt += skillsBlock
                    }

                    // 3. Build initial LLM messages
                    var llmMessages = buildMessages(
                        history: history,
                        userTurn: userTurn
                    )

                    // 4. Get provider
                    let provider = try router.provider(for: config)

                    // 5. Determine tools
                    let activeTools = tools ?? []
                    let toolDefs: [ToolDefinition]? = activeTools.isEmpty ? nil : activeTools.map { $0.definition }

                    // Build tool lookup for execution
                    var toolsByName: [String: any AgentTool] = [:]
                    for tool in activeTools {
                        toolsByName[tool.name] = tool
                    }
                    let ctx = toolContext

                    // 6. Agentic loop — up to 10 iterations
                    let maxIterations = 10
                    for _ in 0..<maxIterations {
                        try Task.checkCancellation()

                        let stream = provider.sendMessage(
                            messages: llmMessages,
                            model: config.model,
                            systemPrompt: systemPrompt,
                            maxTokens: config.maxTokens,
                            tools: toolDefs
                        )

                        var assistantTurn = ChatTurn(
                            role: .assistant,
                            content: "",
                            isStreaming: true,
                            skill: skill?.id
                        )
                        var toolCalls: [ToolCall] = []

                        for try await chunk in stream {
                            try Task.checkCancellation()

                            switch chunk {
                            case .delta(let text):
                                assistantTurn.content += text
                                continuation.yield(.delta(text))
                            case .toolUse(let toolCall):
                                toolCalls.append(toolCall)
                            case .finished(let reason):
                                _ = reason
                            case .error(let msg):
                                assistantTurn.isStreaming = false
                                assistantTurn.error = msg
                                try await store.appendTurn(assistantTurn, sessionId: sessionId)
                                continuation.finish(throwing: LLMProviderError.streamError(msg))
                                return
                            }
                        }

                        if !toolCalls.isEmpty, let toolContext = ctx {
                            // Execute tools and collect results
                            var toolUseRecords: [ToolUseRecord] = []
                            var toolResults: [ToolResult] = []

                            for call in toolCalls {
                                try Task.checkCancellation()

                                var record = ToolUseRecord(from: call)

                                // If confirmation callback is set, ask for approval
                                if let confirmationCallback = toolConfirmation {
                                    record.status = .pending
                                    continuation.yield(.toolUsePending(record))

                                    let approved = await confirmationCallback(call)
                                    if !approved {
                                        record.status = .denied
                                        record.result = "User denied tool execution."
                                        record.isError = true
                                        let deniedResult = ToolResult(
                                            toolCallId: call.id,
                                            toolName: call.name,
                                            content: "User denied tool execution.",
                                            isError: true
                                        )
                                        toolResults.append(deniedResult)
                                        toolUseRecords.append(record)
                                        continuation.yield(.toolUseCompleted(record))
                                        continue
                                    }
                                }

                                record.status = .executing
                                continuation.yield(.toolUseStarted(record))

                                // Execute via AgentTool
                                if let tool = toolsByName[call.name] {
                                    do {
                                        let output = try await tool.execute(input: call.input, context: toolContext)
                                        record.result = output.content
                                        record.isError = output.isError
                                        record.status = .completed
                                        toolResults.append(ToolResult(
                                            toolCallId: call.id,
                                            toolName: call.name,
                                            content: output.content,
                                            isError: output.isError
                                        ))
                                    } catch {
                                        record.result = "Tool error: \(error.localizedDescription)"
                                        record.isError = true
                                        record.status = .completed
                                        toolResults.append(ToolResult(
                                            toolCallId: call.id,
                                            toolName: call.name,
                                            content: "Tool error: \(error.localizedDescription)",
                                            isError: true
                                        ))
                                    }
                                } else {
                                    record.result = "Unknown tool: \(call.name)"
                                    record.isError = true
                                    record.status = .completed
                                    toolResults.append(ToolResult(
                                        toolCallId: call.id,
                                        toolName: call.name,
                                        content: "Unknown tool: \(call.name)",
                                        isError: true
                                    ))
                                }

                                toolUseRecords.append(record)
                                continuation.yield(.toolUseCompleted(record))
                            }

                            // Persist the assistant turn with tool uses
                            assistantTurn.isStreaming = false
                            assistantTurn.toolUses = toolUseRecords
                            try await store.appendTurn(assistantTurn, sessionId: sessionId)
                            continuation.yield(.finished(assistantTurn))

                            // Append assistant message (with tool use blocks) and
                            // user message (with tool results) to conversation for next iteration
                            var assistantParts: [LLMMessage.ContentPart] = []
                            if !assistantTurn.content.isEmpty {
                                assistantParts.append(.text(assistantTurn.content))
                            }
                            for call in toolCalls {
                                assistantParts.append(.toolUse(call))
                            }
                            llmMessages.append(LLMMessage(role: .assistant, content: assistantParts))

                            var resultParts: [LLMMessage.ContentPart] = []
                            for result in toolResults {
                                resultParts.append(.toolResult(result))
                            }
                            llmMessages.append(LLMMessage(role: .user, content: resultParts))

                            // Continue the loop for the next LLM response
                            continue
                        }

                        // No tool calls — final response
                        assistantTurn.isStreaming = false
                        try await store.appendTurn(assistantTurn, sessionId: sessionId)
                        continuation.yield(.finished(assistantTurn))
                        continuation.finish()
                        return
                    }

                    // Exhausted max iterations
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
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
        parts.append("You are a helpful AI assistant integrated into OakReader, a document reader application. Do not praise questions or validate premises — if the user is wrong, say so directly. If uncertain, say so; do not fabricate citations or facts. Do not change your answer under pressure unless new evidence is presented.")

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

            // Reconstruct tool use/result content parts from persisted tool records
            if turn.role == .assistant && !turn.toolUses.isEmpty {
                var parts: [LLMMessage.ContentPart] = []
                if !turn.content.isEmpty {
                    parts.append(.text(turn.content))
                }
                for record in turn.toolUses {
                    let call = ToolCall(id: record.id, name: record.name, input: record.input)
                    parts.append(.toolUse(call))
                }
                messages.append(LLMMessage(role: .assistant, content: parts))

                // Add tool results as a user message
                var resultParts: [LLMMessage.ContentPart] = []
                for record in turn.toolUses {
                    let result = ToolResult(
                        toolCallId: record.id,
                        toolName: record.name,
                        content: record.result ?? "",
                        isError: record.isError
                    )
                    resultParts.append(.toolResult(result))
                }
                messages.append(LLMMessage(role: .user, content: resultParts))
            } else {
                messages.append(LLMMessage(role: role, text: turn.content))
            }
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
