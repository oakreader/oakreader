import AVFoundation
import Foundation

/// Cloud TTS via the Fish Audio `/v1/tts` endpoint.
///
/// Requests raw `pcm` output at 24 kHz (signed 16-bit, mono). The optional
/// `referenceId` selects a Fish voice model; empty uses the account default.
public struct FishAudioTTSProvider: TTSService {
    private let apiKey: String
    private let model: String
    private let referenceId: String
    private let baseURL = URL(string: "https://api.fish.audio/v1/tts")!

    public nonisolated let sampleRate: Double = 24000

    public init(apiKey: String, model: String = "s1", referenceId: String = "") {
        self.apiKey = apiKey
        self.model = model
        self.referenceId = referenceId
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
        request.setValue(model, forHTTPHeaderField: "model")

        var body: [String: Any] = [
            "text": text,
            "format": "pcm",
            "sample_rate": Int(sampleRate),
        ]
        // A call-time voice overrides the configured reference id.
        let reference = voice?.isEmpty == false ? voice! : referenceId
        if !reference.isEmpty { body["reference_id"] = reference }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw VoiceAgentError.ttsFailed("Fish Audio TTS error \(http.statusCode): \(message)")
        }

        guard let buffer = AudioPCM.bufferFromInt16PCM(data, sampleRate: sampleRate) else {
            throw VoiceAgentError.ttsFailed("Fish Audio TTS returned no audio")
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
