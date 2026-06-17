import Foundation

public struct AnthropicProvider: LLMProviderService {
    private let apiKey: String
    private let baseURL: URL
    private let customHeaders: [String: String]

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!, customHeaders: [String: String] = [:]) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.customHeaders = customHeaders
    }

    public func sendMessage(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        sendMessage(messages: messages, model: model, systemPrompt: systemPrompt, maxTokens: maxTokens, tools: nil)
    }

    public func sendMessage(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int,
        tools: [ToolDefinition]?
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        sendMessage(messages: messages, model: model, systemPrompt: systemPrompt, maxTokens: maxTokens, tools: tools, thinkingBudget: nil, thinkingEffort: nil)
    }

    public func sendMessage(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int,
        tools: [ToolDefinition]?,
        thinkingBudget: Int?,
        thinkingEffort: String?
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    for (key, value) in customHeaders {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    let body = buildRequestBody(
                        messages: messages, model: model,
                        systemPrompt: systemPrompt,
                        maxTokens: maxTokens,
                        tools: tools,
                        thinkingBudget: thinkingBudget,
                        thinkingEffort: thinkingEffort
                    )
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMProviderError.networkError("Invalid response"))
                        return
                    }
                    guard httpResponse.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        let detail = Self.extractErrorMessage(errorBody) ?? "status \(httpResponse.statusCode)"
                        continuation.finish(throwing: LLMProviderError.invalidResponse(httpResponse.statusCode, detail))
                        return
                    }

                    try await parseSSEStream(bytes: bytes, continuation: continuation)
                } catch is CancellationError {
                    continuation.finish(throwing: LLMProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Models that support adaptive thinking (type: "adaptive" + output_config.effort)
    /// instead of budget-based thinking (type: "enabled" + budget_tokens).
    private static func supportsAdaptiveThinking(_ modelId: String) -> Bool {
        modelId.contains("opus-4-6") || modelId.contains("opus-4.6") ||
        modelId.contains("opus-4-7") || modelId.contains("opus-4.7") ||
        modelId.contains("sonnet-4-6") || modelId.contains("sonnet-4.6")
    }

    private func buildRequestBody(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int,
        tools: [ToolDefinition]?,
        thinkingBudget: Int? = nil,
        thinkingEffort: String? = nil
    ) -> [String: Any] {
        let useAdaptive = Self.supportsAdaptiveThinking(model)

        // For budget-based thinking, max_tokens must be > budget_tokens.
        var effectiveMaxTokens = maxTokens
        if let budget = thinkingBudget, budget > 0, !useAdaptive {
            effectiveMaxTokens = max(maxTokens, budget + 1024)
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": effectiveMaxTokens,
            "stream": true,
        ]

        // Extended thinking support
        if let effort = thinkingEffort, effort != "off" {
            if useAdaptive {
                // Opus 4.6+, Sonnet 4.6: adaptive thinking with effort level
                body["thinking"] = [
                    "type": "adaptive",
                    "display": "summarized",
                ] as [String: Any]
                body["output_config"] = [
                    "effort": effort,
                ] as [String: Any]
            } else if let budget = thinkingBudget, budget > 0 {
                // Older models: budget-based thinking
                body["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": budget,
                    "display": "summarized",
                ] as [String: Any]
            }
        }

        // Prompt caching. Anthropic caches the request prefix in the order
        // tools → system → messages, up to each `cache_control` breakpoint, and
        // reads it back at ~10% of the input cost on the next turn (5-min TTL).
        // We place a breakpoint on the (stable) tools block, on the system
        // prompt, and on the last message (below) so a multi-turn chat — and
        // especially a tool-result-heavy agent loop — reuses the bulk of its
        // input instead of re-billing it every turn. Breakpoints are ignored
        // for free when the prefix is below the cache minimum, so this is safe
        // for short prompts. Anthropic-only; no other provider is affected.

        if let system = systemPrompt, !system.isEmpty {
            body["system"] = [
                [
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"],
                ] as [String: Any]
            ]
        }

        if let tools, !tools.isEmpty {
            var toolBlocks: [[String: Any]] = tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema,
                ] as [String: Any]
            }
            // A breakpoint on the final tool caches the whole tools prefix.
            toolBlocks[toolBlocks.count - 1]["cache_control"] = ["type": "ephemeral"]
            body["tools"] = toolBlocks
        }

        let apiMessages: [[String: Any]] = messages.compactMap { msg in
            guard msg.role != .system else { return nil }
            let role: String
            switch msg.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            default: return nil
            }

            let hasComplexContent = msg.content.contains { part in
                switch part {
                case .text: return false
                case .imageBase64, .toolUse, .toolResult: return true
                }
            }

            if hasComplexContent {
                let contentParts: [[String: Any]] = msg.content.compactMap { part in
                    switch part {
                    case .text(let text):
                        return ["type": "text", "text": text]
                    case .imageBase64(let data, let mediaType):
                        return [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mediaType,
                                "data": data,
                            ] as [String: Any],
                        ]
                    case .toolUse(let toolCall):
                        return [
                            "type": "tool_use",
                            "id": toolCall.id,
                            "name": toolCall.name,
                            "input": toolCall.input.jsonObject,
                        ] as [String: Any]
                    case .toolResult(let result):
                        return [
                            "type": "tool_result",
                            "tool_use_id": result.toolCallId,
                            "content": result.content,
                            "is_error": result.isError,
                        ] as [String: Any]
                    }
                }
                return ["role": role, "content": contentParts]
            } else {
                return ["role": role, "content": msg.textContent]
            }
        }

        // Cache the conversation history: put a breakpoint on the last message's
        // final content block. Each turn appends after it, so the prior-turn
        // prefix (tools + system + history) is served from cache next turn. The
        // block must be in array form for `cache_control` to attach, so coerce a
        // plain string body into a single text block first.
        var cachedMessages = apiMessages
        if let lastIdx = cachedMessages.indices.last {
            var last = cachedMessages[lastIdx]
            if let text = last["content"] as? String {
                last["content"] = [["type": "text", "text": text] as [String: Any]]
            }
            if var blocks = last["content"] as? [[String: Any]], !blocks.isEmpty {
                blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
                last["content"] = blocks
                cachedMessages[lastIdx] = last
            }
        }

        body["messages"] = cachedMessages
        return body
    }

    private func parseSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        var currentToolId: String?
        var currentToolName: String?
        var currentToolInput = ""
        var isThinkingBlock = false

        for try await line in bytes.lines {
            guard !Task.isCancelled else {
                continuation.finish(throwing: LLMProviderError.cancelled)
                return
            }

            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            switch type {
            case "content_block_start":
                if let contentBlock = json["content_block"] as? [String: Any],
                   let blockType = contentBlock["type"] as? String
                {
                    switch blockType {
                    case "tool_use":
                        currentToolId = contentBlock["id"] as? String
                        currentToolName = contentBlock["name"] as? String
                        currentToolInput = ""
                        isThinkingBlock = false
                    case "thinking":
                        isThinkingBlock = true
                    default:
                        isThinkingBlock = false
                    }
                }

            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any] {
                    let deltaType = delta["type"] as? String
                    if deltaType == "thinking_delta", let text = delta["thinking"] as? String {
                        continuation.yield(.thinking(text))
                    } else if deltaType == "text_delta", let text = delta["text"] as? String {
                        continuation.yield(.delta(text))
                    } else if deltaType == "input_json_delta",
                              let partial = delta["partial_json"] as? String
                    {
                        currentToolInput += partial
                        continuation.yield(.toolInputDelta(
                            id: currentToolId ?? "",
                            name: currentToolName ?? "",
                            partialJSON: currentToolInput
                        ))
                    }
                }

            case "content_block_stop":
                if isThinkingBlock {
                    isThinkingBlock = false
                } else if let toolId = currentToolId, let toolName = currentToolName {
                    let input = parseToolInput(currentToolInput)
                    let toolCall = ToolCall(id: toolId, name: toolName, input: input)
                    continuation.yield(.toolUse(toolCall))
                    currentToolId = nil
                    currentToolName = nil
                    currentToolInput = ""
                }

            case "message_delta":
                if let delta = json["delta"] as? [String: Any],
                   let stopReason = delta["stop_reason"] as? String
                {
                    continuation.yield(.finished(stopReason: stopReason))
                    continuation.finish()
                    return
                }

            case "message_stop":
                continuation.yield(.finished(stopReason: "end_turn"))
                continuation.finish()
                return

            case "error":
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String
                {
                    continuation.finish(throwing: LLMProviderError.streamError(message))
                    return
                }

            default:
                break
            }
        }
        continuation.finish()
    }

    private func parseToolInput(_ jsonString: String) -> ToolInput {
        ToolInput(json: jsonString)
    }

    /// Extract human-readable message from Anthropic error JSON.
    private static func extractErrorMessage(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return nil }
        return message
    }
}
