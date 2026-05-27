import AVFoundation
import OakVoice

/// Transcribes a recorded audio file to text.
///
/// On-device (MLX) transcription was removed. Cloud transcription (ElevenLabs
/// Scribe, Fish Audio, Gemini, OpenAI Whisper) is not yet wired in, so this
/// service currently reports as unavailable. The transcribe affordances in the
/// UI are gated on `Preferences.voiceSTTModel` being non-empty, which no longer
/// happens, so this path is not reached until cloud STT lands.
@Observable
final class RecordingTranscriptionService {
    enum Status: Sendable {
        case idle
        case loading
        case transcribing(Double)
        case completed(String)
        case failed(String)
    }

    private(set) var status: Status = .idle

    @MainActor
    func transcribe(audioURL: URL, sttModel: String) async throws -> String {
        status = .failed("Transcription unavailable")
        throw TranscriptionError.unavailable
    }

    enum TranscriptionError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: "Audio transcription is temporarily unavailable. Cloud transcription is coming soon."
            }
        }
    }
}
