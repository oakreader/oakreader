import AVFoundation
import Foundation

/// Cloud TTS via the OpenAI `/v1/audio/speech` endpoint.
///
/// Requests raw `pcm` output (24 kHz, signed 16-bit, mono) so the bytes map
/// directly onto an `AVAudioPCMBuffer` without any container decoding.
public struct OpenAITTSProvider: TTSService {
    private let apiKey: String
    private let model: String
    private let defaultVoice: String
    private let baseURL: URL

    public nonisolated let sampleRate: Double = 24000

    public init(
        apiKey: String,
        model: String = "gpt-4o-mini-tts",
        voice: String = "alloy",
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/speech")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.defaultVoice = voice
        self.baseURL = endpoint
    }

    public func synthesize(
        text: String,
        voice: String?,
        referenceAudioURL: URL?,
        referenceText: String?
    ) async throws -> AVAudioPCMBuffer {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": text,
            "voice": voice ?? defaultVoice,
            "response_format": "pcm",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)

        guard let buffer = AudioPCM.bufferFromInt16PCM(data, sampleRate: sampleRate) else {
            throw VoiceAgentError.ttsFailed("OpenAI TTS returned no audio")
        }
        return buffer
    }

    public func synthesizeStream(
        text: String,
        voice: String?,
        referenceAudioURL: URL?,
        referenceText: String?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let buffer = try await synthesize(
                        text: text, voice: voice,
                        referenceAudioURL: referenceAudioURL, referenceText: referenceText
                    )
                    continuation.yield(buffer)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw VoiceAgentError.ttsFailed("OpenAI TTS error \(http.statusCode): \(message)")
        }
    }
}
