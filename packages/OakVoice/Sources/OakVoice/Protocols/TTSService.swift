import AVFoundation

/// Protocol for text-to-speech services.
public protocol TTSService: Sendable {
    /// The output sample rate of synthesized audio.
    var sampleRate: Double { get }

    /// Synthesize a complete utterance into a single audio buffer.
    func synthesize(text: String, voice: String?, referenceAudioURL: URL?, referenceText: String?) async throws -> AVAudioPCMBuffer

    /// Stream synthesized audio buffers for incremental playback.
    func synthesizeStream(text: String, voice: String?, referenceAudioURL: URL?, referenceText: String?) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
}

public extension TTSService {
    func synthesize(text: String, voice: String?) async throws -> AVAudioPCMBuffer {
        try await synthesize(text: text, voice: voice, referenceAudioURL: nil, referenceText: nil)
    }

    func synthesize(text: String, voice: String?, referenceAudioURL: URL?) async throws -> AVAudioPCMBuffer {
        try await synthesize(text: text, voice: voice, referenceAudioURL: referenceAudioURL, referenceText: nil)
    }

    func synthesizeStream(text: String, voice: String?) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        synthesizeStream(text: text, voice: voice, referenceAudioURL: nil, referenceText: nil)
    }

    func synthesizeStream(text: String, voice: String?, referenceAudioURL: URL?) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        synthesizeStream(text: text, voice: voice, referenceAudioURL: referenceAudioURL, referenceText: nil)
    }
}
