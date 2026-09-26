import Foundation
import OakAgent

/// Drop-in replacement for OakAgent's old in-process `AgentSession`: same
/// `send(...)` surface, same `SessionEvent` semantics, same JSONL persistence —
/// but the LLM loop runs in the Node sidecar. Tools still execute here, in
/// Swift, against local app state: the backend asks via `tool_exec` events and
/// this engine replies with `tool_result` after the confirmation gate.
actor BackendChatEngine {
    private let store: SessionStore

    init(chatsDirectory: URL) {
        self.store = SessionStore(baseDirectory: chatsDirectory)
    }

    // MARK: - Send message

    func send(
        userContent: String,
        attachments: [TurnAttachment],
        history: [Turn],
        sessionId: UUID,
        config: AIRequestConfig,
        systemPrompt: String,
        turnMetadata: [String: String] = [:],
        additionalUserTurns: [Turn] = [],
        tools: [any AgentTool]? = nil,
        toolContext: ToolExecutionContext? = nil,
        agentSkills: [AgentSkill] = [],
        maxIterations: Int = 10,
        toolConfirmation: (@Sendable (ToolCall, ToolCategory) async -> Bool)? = nil
    ) -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. Build + persist the user turn(s)
                    try Task.checkCancellation()
                    let userTurn = Turn(
                        role: .user, content: userContent,
                        metadata: turnMetadata, attachments: attachments
                    )
                    try await store.appendTurn(userTurn, sessionId: sessionId)
                    continuation.yield(.finished(userTurn))

                    for additionalTurn in additionalUserTurns {
                        try Task.checkCancellation()
                        try await store.appendTurn(additionalTurn, sessionId: sessionId)
                        continuation.yield(.finished(additionalTurn))
                    }

                    // 2. Final system prompt (append agent-skills listing)
                    var finalPrompt = systemPrompt
                    finalPrompt += SkillPromptFormatter.promptSection(
                        skills: agentSkills,
                        hasReadTool: (tools ?? []).contains { $0.name == "read" }
                    )

                    // 3. Wire history
                    let wireMessages = Self.buildWireMessages(
                        history: history, userTurn: userTurn,
                        additionalUserTurns: additionalUserTurns
                    )

                    // 4. Tools
                    let activeTools = tools ?? []
                    var toolsByName: [String: any AgentTool] = [:]
                    for tool in activeTools { toolsByName[tool.name] = tool }
                    let toolDefs = activeTools.map { tool in
                        WireToolDef(
                            name: tool.name,
                            description: tool.description,
                            inputSchema: AnyJSONObject(tool.inputSchema)
                        )
                    }

                    // 5. Run the backend loop, executing tools as it asks.
                    let requestId = await NodeBackend.shared.makeRequestId(prefix: "chat")
                    let command = BackendCommand(
                        id: requestId,
                        type: "chat",
                        providerId: config.providerId,
                        model: config.model,
                        system: finalPrompt,
                        messages: wireMessages,
                        tools: toolDefs.isEmpty ? nil : toolDefs,
                        reasoning: config.reasoningEffort,
                        maxIterations: maxIterations
                    )

                    var assistantTurn = Turn(role: .assistant, content: "", isStreaming: true)
                    var iterationRecords: [ToolUseRecord] = []
                    var expectedToolCalls = 0

                    func finishIteration() async throws {
                        assistantTurn.isStreaming = false
                        if !iterationRecords.isEmpty { assistantTurn.toolUses = iterationRecords }
                        try await store.appendTurn(assistantTurn, sessionId: sessionId)
                        continuation.yield(.finished(assistantTurn))
                        assistantTurn = Turn(role: .assistant, content: "", isStreaming: true)
                        iterationRecords = []
                        expectedToolCalls = 0
                    }

                    do {
                    for try await event in await NodeBackend.shared.events(for: command) {
                        try Task.checkCancellation()
                        switch event.type {
                        case "delta":
                            if let text = event.text {
                                assistantTurn.content += text
                                continuation.yield(.delta(text))
                            }

                        case "thinking":
                            if let text = event.text {
                                assistantTurn.thinking = (assistantTurn.thinking ?? "") + text
                                continuation.yield(.thinkingDelta(text))
                            }

                        case "assistant":
                            // Authoritative snapshot of this iteration.
                            assistantTurn.content = event.text ?? assistantTurn.content
                            if let thinking = event.thinking { assistantTurn.thinking = thinking }
                            expectedToolCalls = event.toolCalls?.count ?? 0
                            if expectedToolCalls == 0 {
                                try await finishIteration()
                            }

                        case "tool_exec":
                            guard let callId = event.callId, let name = event.name else { break }
                            let input = ToolInput(jsonObject: (event.args ?? [:]).mapValues(\.anyValue))
                            let call = ToolCall(id: callId, name: name, input: input)
                            var record = ToolUseRecord(from: call)

                            var approved = true
                            if let confirm = toolConfirmation {
                                let category = toolsByName[name]?.category ?? .readOnly
                                record.status = .pending
                                continuation.yield(.toolUsePending(record))
                                approved = await confirm(call, category)
                            }

                            let resultContent: String
                            let resultIsError: Bool
                            if !approved {
                                record.status = .denied
                                record.result = "User denied tool execution."
                                record.isError = true
                                resultContent = "User denied tool execution."
                                resultIsError = true
                            } else {
                                record.status = .executing
                                continuation.yield(.toolUseStarted(record))
                                if let tool = toolsByName[name], let context = toolContext {
                                    do {
                                        let output = try await tool.execute(input: input, context: context)
                                        record.result = output.content
                                        record.isError = output.isError
                                        resultContent = output.content
                                        resultIsError = output.isError
                                    } catch {
                                        record.result = "Tool error: \(error.localizedDescription)"
                                        record.isError = true
                                        resultContent = record.result ?? ""
                                        resultIsError = true
                                    }
                                } else {
                                    record.result = "Unknown tool: \(name)"
                                    record.isError = true
                                    resultContent = record.result ?? ""
                                    resultIsError = true
                                }
                                record.status = .completed
                            }
                            iterationRecords.append(record)
                            continuation.yield(.toolUseCompleted(record))

                            await NodeBackend.shared.send(BackendCommand(
                                id: requestId, type: "tool_result",
                                callId: callId, content: resultContent, isError: resultIsError
                            ))

                            // Last tool of the iteration settles the turn.
                            if iterationRecords.count == expectedToolCalls {
                                try await finishIteration()
                            }

                        case "done":
                            // Normal completion — the final iteration already settled
                            // on its `assistant` snapshot.
                            break

                        default:
                            break
                        }
                    }
                    } catch let streamError where !(streamError is CancellationError) {
                        // Persist the partial turn with the error so a reloaded
                        // session still shows what streamed before the failure.
                        assistantTurn.isStreaming = false
                        assistantTurn.error = streamError.localizedDescription
                        try? await store.appendTurn(assistantTurn, sessionId: sessionId)
                        throw streamError
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    // Persist the partial turn with the error so history shows it.
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

    func loadSession(_ sessionId: UUID) async throws -> [Turn] {
        try await store.loadTurns(sessionId: sessionId)
    }

    func deleteSession(_ sessionId: UUID) async {
        await store.deleteSession(sessionId)
    }

    // MARK: - Wire building (mirrors the old AgentSession.buildMessages)

    static func buildWireMessages(
        history: [Turn], userTurn: Turn, additionalUserTurns: [Turn] = []
    ) -> [WireMessage] {
        var messages: [WireMessage] = []

        for turn in history where turn.role != .system {
            if turn.role == .assistant && !turn.toolUses.isEmpty {
                messages.append(.assistant(
                    text: turn.content,
                    thinking: nil,
                    toolCalls: turn.toolUses.map {
                        WireToolCall(id: $0.id, name: $0.name, args: AnyJSONObject($0.input.jsonObject))
                    }
                ))
                for record in turn.toolUses {
                    messages.append(.toolResult(
                        callId: record.id, name: record.name,
                        content: record.result ?? "", isError: record.isError
                    ))
                }
            } else if turn.role == .user {
                // Carry attachments (e.g. captured images) through history so
                // follow-up questions can still reference them.
                messages.append(.user(parts: userContentParts(for: turn)))
            } else {
                messages.append(.assistant(text: modelText(from: turn.content), thinking: nil, toolCalls: []))
            }
        }

        messages.append(.user(parts: userContentParts(for: userTurn)))
        for turn in additionalUserTurns {
            messages.append(.user(parts: [.text(modelText(from: turn.content))]))
        }
        return messages
    }

    /// UI-only skill marker (`[[skill:id]]`) must not leak to providers; when the
    /// user only selected a skill and typed nothing, send the skill id instead of
    /// an empty message.
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

    /// Attachments (text selections + captured images) followed by the typed text.
    private static func userContentParts(for turn: Turn) -> [WirePart] {
        var parts: [WirePart] = []
        for attachment in turn.attachments {
            switch attachment.type {
            case .textSelection:
                if let text = attachment.textContent {
                    parts.append(.text("[\(attachment.label)]\n> \(text)\n"))
                }
            case .imageCapture:
                if let imageData = attachment.imageData {
                    parts.append(.image(data: imageData.base64EncodedString(), mimeType: "image/png"))
                }
            }
        }
        parts.append(.text(modelText(from: turn.content)))
        return parts
    }
}
