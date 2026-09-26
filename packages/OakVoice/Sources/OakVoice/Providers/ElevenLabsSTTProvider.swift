import AVFoundation
import Foundation

/// Cloud STT via the ElevenLabs Scribe `/v1/speech-to-text` endpoint.
public struct ElevenLabsSTTProvider: STTService {
    private let apiKey: String
    private let model: String
    private let languageCode: String?
    private let baseURL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    public init(apiKey: String, model: String = "scribe_v1", languageCode: String? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.languageCode = languageCode
    }

    public func transcribe(audio: AVAudioPCMBuffer) async throws -> TranscriptionResult {
        guard let wav = AudioPCM.wavData(from: audio) else {
            throw VoiceAgentError.sttFailed("Failed to encode audio for ElevenLabs Scribe")
        }

        var form = MultipartFormData()
        form.addField("model_id", model)
        if let languageCode { form.addField("language_code", languageCode) }
        form.addFile("file", filename: "audio.wav", mimeType: "audio/wav", data: wav)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw VoiceAgentError.sttFailed("ElevenLabs Scribe error \(http.statusCode): \(message)")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw VoiceAgentError.sttFailed("ElevenLabs Scribe returned no transcript")
        }
        return TranscriptionResult(text: text, isFinal: true, language: json["language_code"] as? String)
    }
}
