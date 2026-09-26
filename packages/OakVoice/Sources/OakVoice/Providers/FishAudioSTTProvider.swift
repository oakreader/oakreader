import AVFoundation
import Foundation

/// Cloud STT via the Fish Audio `/v1/asr` endpoint.
public struct FishAudioSTTProvider: STTService {
    private let apiKey: String
    private let language: String?
    private let baseURL = URL(string: "https://api.fish.audio/v1/asr")!

    public init(apiKey: String, language: String? = nil) {
        self.apiKey = apiKey
        self.language = language
    }

    public func transcribe(audio: AVAudioPCMBuffer) async throws -> TranscriptionResult {
        guard let wav = AudioPCM.wavData(from: audio) else {
            throw VoiceAgentError.sttFailed("Failed to encode audio for Fish Audio ASR")
        }

        var form = MultipartFormData()
        if let language { form.addField("language", language) }
        form.addFile("audio", filename: "audio.wav", mimeType: "audio/wav", data: wav)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw VoiceAgentError.sttFailed("Fish Audio ASR error \(http.statusCode): \(message)")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw VoiceAgentError.sttFailed("Fish Audio ASR returned no transcript")
        }
        return TranscriptionResult(text: text, isFinal: true, language: language)
    }
}
