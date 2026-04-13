import Foundation

public struct OpenAIProvider: LLMProviderService {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func sendMessage(
        messages: [LLMMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    let body = buildRequestBody(
                        messages: messages, model: model,
                        systemPrompt: systemPrompt,
                        maxTokens: maxTokens
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
        maxTokens: Int
    ) -> [String: Any] {
        var apiMessages: [[String: Any]] = []

        if let system = systemPrompt {
            apiMessages.append(["role": "system", "content": system])
        }

        for msg in messages {
            let role: String
            switch msg.role {
            case .system: role = "system"
            case .user: role = "user"
            case .assistant: role = "assistant"
            }

            let hasImages = msg.content.contains { part in
                if case .imageBase64 = part { return true }
                return false
            }

            if hasImages {
                let contentParts: [[String: Any]] = msg.content.map { part in
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
                    }
                }
                apiMessages.append(["role": role, "content": contentParts])
            } else {
                apiMessages.append(["role": role, "content": msg.textContent])
            }
        }

        return [
            "model": model,
            "messages": apiMessages,
            "max_tokens": maxTokens,
            "stream": true,
        ]
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

            if let delta = choice["delta"] as? [String: Any],
               let content = delta["content"] as? String
            {
                continuation.yield(.delta(content))
            }

            if let finishReason = choice["finish_reason"] as? String {
                continuation.yield(.finished(stopReason: finishReason))
                continuation.finish()
                return
            }
        }
        continuation.finish()
    }
}
