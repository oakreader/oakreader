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
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
        ]

        if let system = systemPrompt {
            body["system"] = system
        }

        let apiMessages: [[String: Any]] = messages.compactMap { msg in
            guard msg.role != .system else { return nil }
            let role = msg.role == .user ? "user" : "assistant"

            // Check if we have image content
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
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mediaType,
                                "data": data,
                            ] as [String: Any],
                        ]
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
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   let text = delta["text"] as? String
                {
                    continuation.yield(.delta(text))
                }
            case "message_stop":
                continuation.yield(.finished(stopReason: "end_turn"))
                continuation.finish()
                return
            case "message_delta":
                if let delta = json["delta"] as? [String: Any],
                   let stopReason = delta["stop_reason"] as? String
                {
                    continuation.yield(.finished(stopReason: stopReason))
                    continuation.finish()
                    return
                }
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
}
