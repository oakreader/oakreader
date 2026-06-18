import AVFoundation
import Foundation

/// Cloud STT via the Gemini `generateContent` endpoint with audio input.
///
/// Uploads the audio inline (base64 WAV) alongside a transcription instruction
/// and reads the transcript back from the model's text response.
public struct GeminiSTTProvider: STTService {
    private let apiKey: String
    private let model: String
    private let baseURL: String

    public init(
        apiKey: String,
        model: String = "gemini-2.5-flash",
        baseURL: String = "https://generativelanguage.googleapis.com/v1beta"
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }

    public func transcribe(audio: AVAudioPCMBuffer) async throws -> TranscriptionResult {
        guard let wav = AudioPCM.wavData(from: audio) else {
            throw VoiceAgentError.sttFailed("Failed to encode audio for Gemini transcription")
        }

        let url = URL(string: "\(baseURL)/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [[
                "parts": [
                    ["text": "Transcribe this audio verbatim. Return only the transcript text, with no commentary."],
                    ["inlineData": ["mimeType": "audio/wav", "data": wav.base64EncodedString()]],
                ],
            ]],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw VoiceAgentError.sttFailed("Gemini transcription error \(http.statusCode): \(message)")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        else {
            throw VoiceAgentError.sttFailed("Gemini transcription returned no text")
        }

        let text = parts.compactMap { $0["text"] as? String }.joined()
        return TranscriptionResult(text: text, isFinal: true)
    }
}
