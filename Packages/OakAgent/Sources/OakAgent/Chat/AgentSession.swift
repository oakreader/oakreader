import Foundation

/// Actor that coordinates message flow: routes to provider, persists turns.
public actor AgentSession {
    private let router = ProviderRouter()
    private let store: SessionStore

    /// Initialize with a centralized chats directory.
    public init(chatsDirectory: URL) {
        self.store = SessionStore(baseDirectory: chatsDirectory)
    }

    // MARK: - Send message

    public func send(
        userContent: String,
        attachments: [TurnAttachment],
        history: [Turn],
        sessionId: UUID,
        config: ProviderConfig,
        systemPrompt: String,
        turnMetadata: [String: String] = [:],
        additionalUserTurns: [Turn] = [],
        tools: [any AgentTool]? = nil,
        toolContext: ToolExecutionContext? = nil,
        agentSkills: [AgentSkill] = [],
        maxIterations: Int = 10,
        toolConfirmation: (@Sendable (ToolCall) async -> Bool)? = nil
    ) -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. Build user turn
                    try Task.checkCancellation()
                    let userTurn = Turn(
                        role: .user,
                        content: userContent,
                        metadata: turnMetadata,
                        attachments: attachments
                    )
                    try await store.appendTurn(userTurn, sessionId: sessionId)
                    continuation.yield(.finished(userTurn))

                    for additionalTurn in additionalUserTurns {
                        try Task.checkCancellation()
                        try await store.appendTurn(additionalTurn, sessionId: sessionId)
                        continuation.yield(.finished(additionalTurn))
                    }

                    // 2. Build final system prompt (append agent skills listing)
                    var finalPrompt = systemPrompt
                    let skillsBlock = SkillPromptFormatter.formatForPrompt(agentSkills)
                    if !skillsBlock.isEmpty {
                        finalPrompt += skillsBlock
                    }

                    // 3. Build initial LLM messages
                    var llmMessages = buildMessages(
                        history: history,
                        userTurn: userTurn,
                        additionalUserTurns: additionalUserTurns
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

                    // 6. Agentic loop
                    for _ in 0..<maxIterations {
                        try Task.checkCancellation()

                        let stream = provider.sendMessage(
                            messages: llmMessages,
                            model: config.model,
                            systemPrompt: finalPrompt,
                            maxTokens: config.maxTokens,
                            tools: toolDefs
                        )

                        var assistantTurn = Turn(
                            role: .assistant,
                            content: "",
                            isStreaming: true
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

    public func loadSession(_ sessionId: UUID) async throws -> [Turn] {
        try await store.loadTurns(sessionId: sessionId)
    }

    public func deleteSession(_ sessionId: UUID) async {
        await store.deleteSession(sessionId)
    }

    // MARK: - Private helpers

    private func buildMessages(history: [Turn], userTurn: Turn, additionalUserTurns: [Turn] = []) -> [LLMMessage] {
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
                messages.append(LLMMessage(role: role, text: Self.modelText(from: turn.content)))
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

        contentParts.append(.text(Self.modelText(from: userTurn.content)))

        messages.append(LLMMessage(role: .user, content: contentParts))

        for turn in additionalUserTurns {
            messages.append(LLMMessage(role: .user, text: Self.modelText(from: turn.content)))
        }

        return messages
    }

    /// UI-only marker used by OakReader chat bubbles. The selected skill is applied
    /// through the system prompt, so do not leak the marker to model providers.
    /// If the user only selected a skill and typed no text, use the skill id as the
    /// provider-facing text so the provider never receives an empty user message.
    private static func modelText(from content: String) -> String {
        var remaining = content
        var skillIds: [String] = []

        while true {
            let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("[[skill:") else { break }
            guard let closeRange = trimmed.range(of: "]]") else { break }

            let valueStart = trimmed.index(trimmed.startIndex, offsetBy: "[[skill:".count)
            let rawSkill = String(trimmed[valueStart..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawSkill.isEmpty { skillIds.append(rawSkill) }
            remaining = String(trimmed[closeRange.upperBound...])
        }

        let text = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if skillIds.isEmpty { return text.isEmpty ? "Go" : text }
        return (text.isEmpty || text == "/") ? (skillIds.first ?? "Go") : text
    }
}
