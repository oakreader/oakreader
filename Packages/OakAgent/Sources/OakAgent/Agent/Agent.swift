import Foundation

/// Agentic loop: sends messages to an LLM provider, executes tools, and iterates.
public actor Agent {
    private let tools: [any AgentTool]
    private let toolsByName: [String: any AgentTool]
    private let context: ToolExecutionContext
    private let config: AgentConfiguration

    public init(
        tools: [any AgentTool],
        context: ToolExecutionContext,
        config: AgentConfiguration = .default
    ) {
        self.tools = tools
        self.context = context
        self.config = config
        var byName: [String: any AgentTool] = [:]
        for tool in tools {
            byName[tool.name] = tool
        }
        self.toolsByName = byName
    }

    /// Tool definitions to send to the LLM.
    public var toolDefinitions: [ToolDefinition] {
        tools.map { $0.definition }
    }

    /// Run the agentic loop with the given provider and messages.
    ///
    /// Streams ``AgentEvent`` values as the LLM responds and tools execute.
    /// The loop continues until the LLM responds without tool calls, or
    /// ``AgentConfiguration/maxIterations`` is reached.
    public func run(
        provider: LLMProviderService,
        messages: inout [LLMMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int,
        toolConfirmation: (@Sendable (ToolCall) async -> Bool)? = nil
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        // Capture mutable messages by copying
        let initialMessages = messages
        let toolDefs = tools.isEmpty ? nil : toolDefinitions
        let maxIter = config.maxIterations
        let toolsByName = self.toolsByName
        let context = self.context

        // Append the agent skills listing (no-op when there is no read tool or no skills).
        var fullSystemPrompt = systemPrompt ?? ""
        fullSystemPrompt += SkillPromptFormatter.promptSection(
            skills: config.skills,
            hasReadTool: toolsByName["read"] != nil
        )
        let resolvedSystemPrompt: String? = fullSystemPrompt.isEmpty ? nil : fullSystemPrompt

        return AsyncThrowingStream { continuation in
            let task = Task {
                var llmMessages = initialMessages

                for _ in 0..<maxIter {
                    try Task.checkCancellation()

                    let stream = provider.sendMessage(
                        messages: llmMessages,
                        model: model,
                        systemPrompt: resolvedSystemPrompt,
                        maxTokens: maxTokens,
                        tools: toolDefs
                    )

                    var responseText = ""
                    var toolCalls: [ToolCall] = []

                    for try await chunk in stream {
                        try Task.checkCancellation()

                        switch chunk {
                        case .delta(let text):
                            responseText += text
                            continuation.yield(.delta(text))
                        case .thinking:
                            break // Agent does not use thinking
                        case .toolUse(let toolCall):
                            toolCalls.append(toolCall)
                        case .toolInputDelta:
                            break // Agent path does not surface streaming tool input
                        case .finished:
                            break
                        case .error(let msg):
                            continuation.finish(throwing: LLMProviderError.streamError(msg))
                            return
                        }
                    }

                    if !toolCalls.isEmpty {
                        var toolUseRecords: [ToolUseRecord] = []
                        var toolResults: [ToolResult] = []

                        for call in toolCalls {
                            try Task.checkCancellation()

                            var record = ToolUseRecord(from: call)

                            // Confirmation flow
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

                            // Execute
                            guard let tool = toolsByName[call.name] else {
                                record.status = .completed
                                record.result = "Unknown tool: \(call.name)"
                                record.isError = true
                                toolResults.append(ToolResult(
                                    toolCallId: call.id,
                                    toolName: call.name,
                                    content: "Unknown tool: \(call.name)",
                                    isError: true
                                ))
                                toolUseRecords.append(record)
                                continuation.yield(.toolUseCompleted(record))
                                continue
                            }

                            do {
                                let output = try await tool.execute(input: call.input, context: context)
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

                            toolUseRecords.append(record)
                            continuation.yield(.toolUseCompleted(record))
                        }

                        continuation.yield(.iterationCompleted(text: responseText, toolUses: toolUseRecords))

                        // Append to conversation for next iteration
                        var assistantParts: [LLMMessage.ContentPart] = []
                        if !responseText.isEmpty {
                            assistantParts.append(.text(responseText))
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

                        continue
                    }

                    // No tool calls — final response
                    continuation.yield(.iterationCompleted(text: responseText, toolUses: []))
                    continuation.finish()
                    return
                }

                // Exhausted max iterations
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
