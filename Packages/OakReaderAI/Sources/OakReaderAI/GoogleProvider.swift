import Foundation

public struct GoogleProvider: LLMProviderService {
    private let apiKey: String
    private let baseURL: URL
    private let customHeaders: [String: String]

    public init(apiKey: String, baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/")!, customHeaders: [String: String] = [:]) {
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
                    let url = URL(string: "\(baseURL.absoluteString)\(model):streamGenerateContent?alt=sse&key=\(apiKey)")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    for (key, value) in customHeaders {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    let body = buildRequestBody(
                        messages: messages, systemPrompt: systemPrompt,
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
        systemPrompt: String?,
        maxTokens: Int,
        tools: [ToolDefinition]?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "generationConfig": [
                "maxOutputTokens": maxTokens,
            ] as [String: Any]
        ]

        if let system = systemPrompt {
            body["systemInstruction"] = [
                "parts": [["text": system]]
            ] as [String: Any]
        }

        if let tools, !tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema,
                    ] as [String: Any]
                }
            ] as [String: Any]]
        }

        var contents: [[String: Any]] = []
        for msg in messages where msg.role != .system {
            let role = msg.role == .user ? "user" : "model"

            var parts: [[String: Any]] = []
            for part in msg.content {
                switch part {
                case .text(let text):
                    parts.append(["text": text])
                case .imageBase64(let data, let mediaType):
                    parts.append([
                        "inlineData": [
                            "mimeType": mediaType,
                            "data": data,
                        ] as [String: Any]
                    ])
                case .toolUse(let toolCall):
                    let args: [String: Any] = toolCall.input.reduce(into: [:]) { $0[$1.key] = $1.value }
                    parts.append([
                        "functionCall": [
                            "name": toolCall.name,
                            "args": args,
                        ] as [String: Any]
                    ])
                case .toolResult(let result):
                    parts.append([
                        "functionResponse": [
                            "name": result.toolName,
                            "response": [
                                "content": result.content
                            ] as [String: Any],
                        ] as [String: Any]
                    ])
                }
            }

            contents.append(["role": role, "parts": parts])
        }

        body["contents"] = contents
        return body
    }

    private func parseSSEStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        for try await line in bytes.lines {
            guard !Task.isCancelled else {
                continuation.finish(throwing: LLMProviderError.cancelled)
                return
            }

            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))

            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                continuation.finish(throwing: LLMProviderError.streamError(message))
                return
            }

            if let candidates = json["candidates"] as? [[String: Any]],
               let candidate = candidates.first,
               let content = candidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]]
            {
                for part in parts {
                    if let text = part["text"] as? String {
                        continuation.yield(.delta(text))
                    } else if let functionCall = part["functionCall"] as? [String: Any],
                              let name = functionCall["name"] as? String
                    {
                        let callId = UUID().uuidString
                        let args = functionCall["args"] as? [String: Any] ?? [:]
                        var input: [String: String] = [:]
                        for (key, value) in args {
                            input[key] = "\(value)"
                        }
                        let toolCall = ToolCall(id: callId, name: name, input: input)
                        continuation.yield(.toolUse(toolCall))
                    }
                }

                if let finishReason = candidate["finishReason"] as? String {
                    if finishReason == "STOP" {
                        continuation.yield(.finished(stopReason: finishReason))
                        continuation.finish()
                        return
                    } else if finishReason == "TOOL_USE" || finishReason == "FUNCTION_CALL" {
                        continuation.yield(.finished(stopReason: "tool_use"))
                        continuation.finish()
                        return
                    }
                }
            }
        }
        continuation.finish()
    }
}
