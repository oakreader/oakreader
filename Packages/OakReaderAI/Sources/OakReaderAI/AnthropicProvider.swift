import Foundation

public struct AnthropicProvider: LLMProviderService {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String) {
        self.apiKey = apiKey
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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let body = buildRequestBody(
                        messages: messages, model: model,
                        systemPrompt: systemPrompt,
                        maxTokens: maxTokens,
                        tools: tools
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
                        continuation.finish(throwing: LLMProviderError.invalidResponse(httpResponse.statusCode))
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

    private func buildRequestBody(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int,
        tools: [ToolDefinition]?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
        ]

        if let system = systemPrompt {
            body["system"] = system
        }

        // Add tools if provided
        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema,
                ] as [String: Any]
            }
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
                            "input": toolCall.input,
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

        body["messages"] = apiMessages
        return body
    }

    private func parseSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        // State for accumulating tool use blocks
        var currentToolId: String?
        var currentToolName: String?
        var currentToolInput = ""

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
                   let blockType = contentBlock["type"] as? String,
                   blockType == "tool_use"
                {
                    currentToolId = contentBlock["id"] as? String
                    currentToolName = contentBlock["name"] as? String
                    currentToolInput = ""
                }

            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any] {
                    let deltaType = delta["type"] as? String
                    if deltaType == "text_delta", let text = delta["text"] as? String {
                        continuation.yield(.delta(text))
                    } else if deltaType == "input_json_delta",
                              let partial = delta["partial_json"] as? String
                    {
                        currentToolInput += partial
                    }
                }

            case "content_block_stop":
                // If we were accumulating a tool use block, emit it
                if let toolId = currentToolId, let toolName = currentToolName {
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

    /// Parse accumulated JSON string into a [String: String] dictionary.
    private func parseToolInput(_ jsonString: String) -> [String: String] {
        guard !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var result: [String: String] = [:]
        for (key, value) in obj {
            result[key] = "\(value)"
        }
        return result
    }
}
