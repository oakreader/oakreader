import AVFoundation

/// Result of a speech-to-text transcription.
public struct TranscriptionResult: Sendable {
    public let text: String
    public let isFinal: Bool
    public let language: String?
    public let confidence: Float?

    public init(text: String, isFinal: Bool, language: String? = nil, confidence: Float? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.language = language
        self.confidence = confidence
    }
}

/// Protocol for speech-to-text services.
public protocol STTService: Sendable {
    /// Transcribe a single audio buffer.
    func transcribe(audio: AVAudioPCMBuffer) async throws -> TranscriptionResult

    /// Stream transcription results from a continuous audio stream.
    func transcribeStream(audioStream: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptionResult, Error>
}
