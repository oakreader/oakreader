import Foundation

/// Provider for OpenAI's Responses API (used by ChatGPT subscription via OAuth).
/// Endpoint: `{baseURL}/codex/responses`
/// Auth: Bearer token + `chatgpt-account-id` extracted from the JWT.
public struct OpenAIResponsesProvider: LLMProviderService {
    private let apiKey: String
    private let baseURL: URL
    private let customHeaders: [String: String]

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
        customHeaders: [String: String] = [:]
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.customHeaders = customHeaders
    }

    // MARK: - LLMProviderService

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
                    let endpoint = baseURL.appendingPathComponent("codex/responses")
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
                    request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")

                    // Extract chatgpt-account-id from the JWT token
                    if let accountId = Self.extractAccountId(from: apiKey) {
                        request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
                    }

                    for (key, value) in customHeaders {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    let body = buildRequestBody(
                        messages: messages,
                        model: model,
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
                        continuation.finish(throwing: LLMProviderError.invalidResponse(httpResponse.statusCode, errorBody.isEmpty ? nil : errorBody))
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

    // MARK: - JWT account ID extraction

    /// Decode the JWT payload and extract `chatgpt_account_id` from the
    /// `https://api.openai.com/auth` claim.
    static func extractAccountId(from token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var base64 = String(segments[1])
        // Pad to a multiple of 4 for base64 decoding
        while base64.count % 4 != 0 { base64.append("=") }
        // JWT uses URL-safe base64
        base64 = base64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authClaim = json["https://api.openai.com/auth"] as? [String: Any],
              let accountId = authClaim["chatgpt_account_id"] as? String
        else { return nil }

        return accountId
    }

    // MARK: - Request body (Responses API format)

    private func buildRequestBody(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int,
        tools: [ToolDefinition]?
    ) -> [String: Any] {
        var input: [[String: Any]] = []

        for msg in messages {
            switch msg.role {
            case .system:
                // System messages go into the input array with role "system"
                input.append([
                    "role": "system",
                    "content": msg.textContent,
                ])

            case .user:
                let hasToolResults = msg.content.contains { part in
                    if case .toolResult = part { return true }
                    return false
                }

                if hasToolResults {
                    for part in msg.content {
                        if case .toolResult(let result) = part {
                            input.append([
                                "type": "function_call_output",
                                "call_id": result.toolCallId,
                                "output": result.content,
                            ])
                        }
                    }
                } else {
                    let hasImages = msg.content.contains { part in
                        if case .imageBase64 = part { return true }
                        return false
                    }

                    if hasImages {
                        var contentParts: [[String: Any]] = []
                        for part in msg.content {
                            switch part {
                            case .text(let text):
                                contentParts.append([
                                    "type": "input_text",
                                    "text": text,
                                ])
                            case .imageBase64(let data, let mediaType):
                                contentParts.append([
                                    "type": "input_image",
                                    "image_url": "data:\(mediaType);base64,\(data)",
                                ])
                            default:
                                break
                            }
                        }
                        input.append([
                            "role": "user",
                            "content": contentParts,
                        ])
                    } else {
                        input.append([
                            "role": "user",
                            "content": msg.textContent,
                        ])
                    }
                }

            case .assistant:
                let hasToolUses = msg.content.contains { part in
                    if case .toolUse = part { return true }
                    return false
                }

                if hasToolUses {
                    // Emit text part first if present
                    let text = msg.textContent
                    if !text.isEmpty {
                        input.append([
                            "type": "message",
                            "role": "assistant",
                            "content": [["type": "output_text", "text": text]],
                        ])
                    }
                    // Each tool use becomes a function_call item
                    for part in msg.content {
                        if case .toolUse(let call) = part {
                            let argsJSON: String
                            if let data = try? JSONSerialization.data(withJSONObject: call.input.jsonObject),
                               let str = String(data: data, encoding: .utf8) {
                                argsJSON = str
                            } else {
                                argsJSON = "{}"
                            }
                            input.append([
                                "type": "function_call",
                                "call_id": call.id,
                                "name": call.name,
                                "arguments": argsJSON,
                            ])
                        }
                    }
                } else {
                    input.append([
                        "type": "message",
                        "role": "assistant",
                        "content": [["type": "output_text", "text": msg.textContent]],
                    ])
                }
            }
        }

        var body: [String: Any] = [
            "model": model,
            "input": input,
            "store": false,
            "stream": true,
        ]

        body["instructions"] = systemPrompt ?? "You are a helpful assistant."

        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.inputSchema,
                ] as [String: Any]
            }
        }

        return body
    }

    // MARK: - SSE parsing (Responses API events)

    private func parseSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        // Accumulate function calls keyed by ITEM id (`item_id`), because that is
        // what the `response.function_call_arguments.delta`/`.done` events carry —
        // they do NOT include `call_id`. We still remember `call_id` separately
        // since that is the id the tool result must reference on the way back.
        var toolCallAccumulators: [String: (callId: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            guard !Task.isCancelled else {
                continuation.finish(throwing: LLMProviderError.cancelled)
                return
            }

            // Skip non-data lines (event:, empty lines, comments)
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard !jsonStr.isEmpty else { continue }

            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = json["type"] as? String
            else { continue }

            switch eventType {
            // Text delta
            case "response.output_text.delta":
                if let delta = json["delta"] as? String {
                    continuation.yield(.delta(delta))
                }

            // Reasoning / thinking summary delta
            case "response.reasoning_summary_text.delta":
                if let delta = json["delta"] as? String {
                    continuation.yield(.thinking(delta))
                }

            // A new output item was added — check if it's a function call
            case "response.output_item.added":
                if let item = json["item"] as? [String: Any],
                   let itemType = item["type"] as? String,
                   itemType == "function_call",
                   let itemId = item["id"] as? String
                {
                    let callId = item["call_id"] as? String ?? itemId
                    let name = item["name"] as? String ?? ""
                    toolCallAccumulators[itemId] = (
                        callId: callId,
                        name: name,
                        arguments: item["arguments"] as? String ?? ""
                    )
                }

            // Function call arguments streaming — keyed by `item_id`.
            case "response.function_call_arguments.delta":
                if let itemId = json["item_id"] as? String,
                   let delta = json["delta"] as? String
                {
                    toolCallAccumulators[itemId]?.arguments += delta
                    if let acc = toolCallAccumulators[itemId] {
                        continuation.yield(.toolInputDelta(
                            id: acc.callId, name: acc.name, partialJSON: acc.arguments
                        ))
                    }
                }

            // Function call arguments complete — keyed by `item_id`. The event's
            // own `arguments` field is the authoritative full string; fall back
            // to what we accumulated from deltas.
            case "response.function_call_arguments.done":
                if let itemId = json["item_id"] as? String,
                   let acc = toolCallAccumulators.removeValue(forKey: itemId)
                {
                    let argsString = (json["arguments"] as? String) ?? acc.arguments
                    let input = parseToolInput(argsString)
                    let toolCall = ToolCall(id: acc.callId, name: acc.name, input: input)
                    continuation.yield(.toolUse(toolCall))
                }

            // Response completed
            case "response.completed":
                let stopReason: String?
                if let resp = json["response"] as? [String: Any] {
                    stopReason = resp["status"] as? String
                } else {
                    stopReason = "stop"
                }
                // Flush any remaining tool calls
                for (_, acc) in toolCallAccumulators {
                    let input = parseToolInput(acc.arguments)
                    continuation.yield(.toolUse(ToolCall(id: acc.callId, name: acc.name, input: input)))
                }
                toolCallAccumulators.removeAll()
                continuation.yield(.finished(stopReason: stopReason))
                continuation.finish()
                return

            // Error events
            case "response.failed":
                let message: String
                if let resp = json["response"] as? [String: Any],
                   let error = resp["error"] as? [String: Any],
                   let msg = error["message"] as? String
                {
                    message = msg
                } else {
                    message = "Response failed"
                }
                continuation.finish(throwing: LLMProviderError.streamError(message))
                return

            case "error":
                let message = (json["message"] as? String) ?? "Unknown error"
                continuation.finish(throwing: LLMProviderError.streamError(message))
                return

            default:
                // Ignore other event types (response.created, response.in_progress, etc.)
                break
            }
        }
        // Stream ended without explicit completion
        continuation.yield(.finished(stopReason: nil))
        continuation.finish()
    }

    private func parseToolInput(_ jsonString: String) -> ToolInput {
        ToolInput(json: jsonString)
    }
}
