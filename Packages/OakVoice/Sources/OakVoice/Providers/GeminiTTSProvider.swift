import AVFoundation
import Foundation

/// Cloud TTS via the Gemini `generateContent` endpoint with audio output.
///
/// Gemini returns base64 PCM (24 kHz, signed 16-bit, mono) in
/// `candidates[0].content.parts[0].inlineData.data`.
public struct GeminiTTSProvider: TTSService {
    private let apiKey: String
    private let model: String
    private let defaultVoice: String
    private let baseURL: String

    public nonisolated let sampleRate: Double = 24000

    public init(
        apiKey: String,
        model: String = "gemini-2.5-flash-preview-tts",
        voice: String = "Kore",
        baseURL: String = "https://generativelanguage.googleapis.com/v1beta"
    ) {
        self.apiKey = apiKey
        self.model = model
        self.defaultVoice = voice
        self.baseURL = baseURL
    }

    public func synthesize(
        text: String,
        voice: String?,
        referenceAudioURL: URL?,
        referenceText: String?
    ) async throws -> AVAudioPCMBuffer {
        let url = URL(string: "\(baseURL)/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": ["voiceName": voice ?? defaultVoice],
                    ],
                ],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw VoiceAgentError.ttsFailed("Gemini TTS error \(http.statusCode): \(message)")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]],
            let inlineData = parts.compactMap({ $0["inlineData"] as? [String: Any] }).first,
            let base64 = inlineData["data"] as? String,
            let pcm = Data(base64Encoded: base64),
            let buffer = AudioPCM.bufferFromInt16PCM(pcm, sampleRate: sampleRate)
        else {
            throw VoiceAgentError.ttsFailed("Gemini TTS returned no audio")
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
}
