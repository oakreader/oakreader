import Foundation

public struct OpenAIProvider: LLMProviderService {
    private let apiKey: String
    private let baseURL: URL
    private let customHeaders: [String: String]

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com/v1/chat/completions")!, customHeaders: [String: String] = [:]) {
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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    for (key, value) in customHeaders {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

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
        var apiMessages: [[String: Any]] = []

        if let system = systemPrompt {
            apiMessages.append(["role": "system", "content": system])
        }

        for msg in messages {
            switch msg.role {
            case .system:
                apiMessages.append(["role": "system", "content": msg.textContent])

            case .user:
                let hasImages = msg.content.contains { part in
                    if case .imageBase64 = part { return true }
                    return false
                }
                let hasToolResults = msg.content.contains { part in
                    if case .toolResult = part { return true }
                    return false
                }

                if hasToolResults {
                    for part in msg.content {
                        if case .toolResult(let result) = part {
                            apiMessages.append([
                                "role": "tool",
                                "tool_call_id": result.toolCallId,
                                "content": result.content,
                            ])
                        }
                    }
                } else if hasImages {
                    let contentParts: [[String: Any]] = msg.content.compactMap { part in
                        switch part {
                        case .text(let text):
                            return ["type": "text", "text": text]
                        case .imageBase64(let data, let mediaType):
                            return [
                                "type": "image_url",
                                "image_url": [
                                    "url": "data:\(mediaType);base64,\(data)"
                                ] as [String: Any],
                            ]
                        default:
                            return nil
                        }
                    }
                    apiMessages.append(["role": "user", "content": contentParts])
                } else {
                    apiMessages.append(["role": "user", "content": msg.textContent])
                }

            case .assistant:
                let hasToolUses = msg.content.contains { part in
                    if case .toolUse = part { return true }
                    return false
                }

                if hasToolUses {
                    var textContent = ""
                    var toolCalls: [[String: Any]] = []
                    for part in msg.content {
                        switch part {
                        case .text(let text):
                            textContent += text
                        case .toolUse(let call):
                            let inputJSON: String
                            if let data = try? JSONSerialization.data(withJSONObject: call.input),
                               let str = String(data: data, encoding: .utf8) {
                                inputJSON = str
                            } else {
                                inputJSON = "{}"
                            }
                            toolCalls.append([
                                "id": call.id,
                                "type": "function",
                                "function": [
                                    "name": call.name,
                                    "arguments": inputJSON,
                                ] as [String: Any],
                            ])
                        default:
                            break
                        }
                    }
                    var assistantMsg: [String: Any] = ["role": "assistant"]
                    if !textContent.isEmpty {
                        assistantMsg["content"] = textContent
                    }
                    assistantMsg["tool_calls"] = toolCalls
                    apiMessages.append(assistantMsg)
                } else {
                    apiMessages.append(["role": "assistant", "content": msg.textContent])
                }
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "max_tokens": maxTokens,
            "stream": true,
        ]

        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema,
                    ] as [String: Any],
                ] as [String: Any]
            }
        }

        return body
    }

    private func parseSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        var toolCallAccumulators: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            guard !Task.isCancelled else {
                continuation.finish(throwing: LLMProviderError.cancelled)
                return
            }

            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))

            if jsonStr.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                continuation.yield(.finished(stopReason: "stop"))
                continuation.finish()
                return
            }

            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first
            else { continue }

            if let delta = choice["delta"] as? [String: Any] {
                if let content = delta["content"] as? String {
                    continuation.yield(.delta(content))
                }

                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for tc in toolCalls {
                        guard let index = tc["index"] as? Int else { continue }

                        if let id = tc["id"] as? String {
                            let funcInfo = tc["function"] as? [String: Any]
                            toolCallAccumulators[index] = (
                                id: id,
                                name: funcInfo?["name"] as? String ?? "",
                                arguments: funcInfo?["arguments"] as? String ?? ""
                            )
                        } else if let funcInfo = tc["function"] as? [String: Any],
                                  let argChunk = funcInfo["arguments"] as? String
                        {
                            toolCallAccumulators[index]?.arguments += argChunk
                        }
                    }
                }
            }

            if let finishReason = choice["finish_reason"] as? String {
                if finishReason == "tool_calls" {
                    for index in toolCallAccumulators.keys.sorted() {
                        if let acc = toolCallAccumulators[index] {
                            let input = parseToolInput(acc.arguments)
                            let toolCall = ToolCall(id: acc.id, name: acc.name, input: input)
                            continuation.yield(.toolUse(toolCall))
                        }
                    }
                    continuation.yield(.finished(stopReason: "tool_calls"))
                    continuation.finish()
                    return
                } else {
                    continuation.yield(.finished(stopReason: finishReason))
                    continuation.finish()
                    return
                }
            }
        }
        continuation.finish()
    }

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
