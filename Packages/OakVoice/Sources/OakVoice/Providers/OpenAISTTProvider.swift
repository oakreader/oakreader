import AVFoundation
import Foundation

/// Cloud STT via the OpenAI `/v1/audio/transcriptions` endpoint.
public struct OpenAISTTProvider: STTService {
    private let apiKey: String
    private let model: String
    private let language: String?
    private let baseURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    public init(apiKey: String, model: String = "gpt-4o-transcribe", language: String? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
    }

    public func transcribe(audio: AVAudioPCMBuffer) async throws -> TranscriptionResult {
        guard let wav = AudioPCM.wavData(from: audio) else {
            throw VoiceAgentError.sttFailed("Failed to encode audio for OpenAI transcription")
        }

        var form = MultipartFormData()
        form.addField("model", model)
        form.addField("response_format", "json")
        if let language { form.addField("language", language) }
        form.addFile("file", filename: "audio.wav", mimeType: "audio/wav", data: wav)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw VoiceAgentError.sttFailed("OpenAI transcription error \(http.statusCode): \(message)")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw VoiceAgentError.sttFailed("OpenAI transcription returned no text")
        }
        return TranscriptionResult(text: text, isFinal: true, language: language)
    }
}
