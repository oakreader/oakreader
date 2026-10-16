import Foundation

/// Drop-in replacement for OakAgent's old in-process `AgentSession`: same
/// `send(...)` surface, same `SessionEvent` semantics — but the LLM loop runs
/// in the Node sidecar. Tools still execute here, in Swift, against local app
/// state: the backend asks via `tool/execute` and this engine answers after
/// the confirmation gate.
///
/// History is a pi session file the core owns: it reads the file, runs the
/// loop and appends each entry, sending the same entry on `chat/entry`. This
/// engine only sends the user's message and reads the file back to draw it.
actor BackendChatEngine {
    private let store: SessionStore

    init(chatsDirectory: URL) {
        self.store = SessionStore(baseDirectory: chatsDirectory)
    }

    // MARK: - Send message

    func send(
        userContent: String,
        attachments: [TurnAttachment],
        sessionId: UUID,
        config: AIRequestConfig,
        systemPrompt: String,
        turnMetadata: [String: String] = [:],
        tools: [any AgentTool]? = nil,
        toolContext: ToolExecutionContext? = nil,
        maxIterations: Int = 10,
        toolConfirmation: (@Sendable (ToolCall, ToolCategory) async -> Bool)? = nil
    ) -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. The user turn. The core stores it as a pi user message.
                    try Task.checkCancellation()
                    let userTurn = Turn(
                        role: .user, content: userContent,
                        metadata: turnMetadata, attachments: attachments
                    )
                    continuation.yield(.finished(userTurn))
                    let userMessage = PiMessage.user(PiMessage.userParts(for: userTurn), at: userTurn.timestamp)

                    // 2. Tools
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

                    // 3. Run the backend loop, executing tools as it asks. The
                    //    system prompt arrives complete: the core composes
                    //    policy, mixins and the skills listing together.
                    let params = RPC.ChatParams(
                        providerId: config.providerId,
                        model: config.model,
                        system: systemPrompt,
                        sessionId: sessionId.uuidString,
                        user: userMessage,
                        display: PiSession.display(for: userTurn),
                        tools: toolDefs,
                        maxTokens: nil,
                        reasoning: config.reasoningEffort,
                        maxIterations: maxIterations
                    )

                    var assistantTurn = Turn(role: .assistant, content: "", isStreaming: true)
                    var iterationRecords: [ToolUseRecord] = []
                    // The calls the last assistant message made, and how many
                    // of their results have arrived.
                    var pendingCalls: [ToolCall] = []
                    var settledCalls = 0
                    // Uptime of this iteration's first thinking token, until the
                    // first answer token or tool call ends the thinking.
                    var thinkingStart: TimeInterval?
                    func endThinking() {
                        guard let start = thinkingStart else { return }
                        thinkingStart = nil
                        let seconds = ProcessInfo.processInfo.systemUptime - start
                        assistantTurn.thinkingSeconds = seconds
                        continuation.yield(.thinkingFinished(seconds: seconds))
                    }

                    func finishIteration() {
                        assistantTurn.isStreaming = false
                        if !iterationRecords.isEmpty { assistantTurn.toolUses = iterationRecords }
                        continuation.yield(.finished(assistantTurn))
                        assistantTurn = Turn(role: .assistant, content: "", isStreaming: true)
                        iterationRecords = []
                        pendingCalls = []
                        settledCalls = 0
                        thinkingStart = nil
                    }

                    for try await streamEvent in await NodeBackend.shared.stream(
                        RPC.Method.chat, params: params
                    ) {
                        try Task.checkCancellation()

                        // Progress notifications shape the turn as it streams.
                        if case .notification(let method, let raw) = streamEvent {
                            switch method {
                            case RPC.Method.chatDelta:
                                guard let p = try? RPCCoding.decode(RPC.ChatDeltaParams.self, from: raw) else { break }
                                endThinking()
                                assistantTurn.content += p.text
                                continuation.yield(.delta(p.text))

                            case RPC.Method.chatThinking:
                                guard let p = try? RPCCoding.decode(RPC.ChatThinkingParams.self, from: raw) else { break }
                                if assistantTurn.thinking == nil {
                                    thinkingStart = ProcessInfo.processInfo.systemUptime
                                }
                                assistantTurn.thinking = (assistantTurn.thinking ?? "") + p.text
                                continuation.yield(.thinkingDelta(p.text))

                            case RPC.Method.chatToolCall:
                                guard let p = try? RPCCoding.decode(RPC.ChatToolCallParams.self, from: raw) else { break }
                                endThinking()
                                continuation.yield(.toolInputDelta(
                                    id: p.callId, name: p.name,
                                    input: ToolInput(jsonObject: p.args.mapValues(\.anyValue))))

                            case RPC.Method.chatEntry:
                                // The core already wrote this entry to the session
                                // file. Only messages change what is drawn.
                                guard let p = try? RPCCoding.decode(RPC.ChatEntryParams.self, from: raw),
                                      p.entry["type"]?.stringValue == "message",
                                      let message = p.entry["message"] else { break }
                                switch PiMessage.role(message) {
                                case "assistant":
                                    // Authoritative: replaces what the deltas built.
                                    endThinking()
                                    assistantTurn.content = PiMessage.text(message)
                                    if let thinking = PiMessage.thinking(message) { assistantTurn.thinking = thinking }
                                    if let failure = PiMessage.failure(message) { assistantTurn.error = failure }
                                    pendingCalls = PiMessage.toolCalls(message)
                                    if pendingCalls.isEmpty { finishIteration() }

                                case "toolResult":
                                    let callId = message["toolCallId"]?.stringValue
                                    // pi answers some calls itself, such as one whose
                                    // arguments failed validation. Show those too.
                                    if !iterationRecords.contains(where: { $0.id == callId }),
                                       let call = pendingCalls.first(where: { $0.id == callId }) {
                                        var record = ToolUseRecord(from: call)
                                        record.result = PiMessage.text(message)
                                        record.isError = message["isError"]?.boolValue ?? false
                                        record.status = .completed
                                        iterationRecords.append(record)
                                        continuation.yield(.toolUseCompleted(record))
                                    }
                                    settledCalls += 1
                                    // The last result of the iteration settles the turn.
                                    if settledCalls == pendingCalls.count { finishIteration() }

                                default:
                                    break
                                }

                            default:
                                break
                            }
                            continue
                        }

                        // The only reverse call this request makes is tool execution.
                        guard case .request(let rpcId, let method, let raw) = streamEvent,
                              method == RPC.Method.toolExecute,
                              let p = try? RPCCoding.decode(RPC.ToolExecuteParams.self, from: raw)
                        else { continue }

                        do {
                            // The model's id, so this record replaces the preview
                            // drawn from chat/toolcall instead of adding a second row.
                            let callId = p.callId ?? rpcId
                            let name = p.name
                            let input = ToolInput(jsonObject: p.args.mapValues(\.anyValue))
                            let call = ToolCall(id: callId, name: name, input: input)
                            var record = ToolUseRecord(from: call)

                            var approved = true
                            if let confirm = toolConfirmation {
                                let category = toolsByName[name]?.category(for: input) ?? .readOnly
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

                            await NodeBackend.shared.respond(
                                to: rpcId,
                                with: RPC.ToolExecuteResult(
                                    content: resultContent, isError: resultIsError, denied: !approved))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    // A provider failure is already in the session file as a
                    // failed reply. A failure before the loop, such as an
                    // unknown model, is shown here and not stored.
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
}
