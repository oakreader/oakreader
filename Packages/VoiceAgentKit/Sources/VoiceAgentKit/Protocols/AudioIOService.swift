import AVFoundation

/// Protocol for capturing audio from a microphone or other input source.
public protocol AudioCaptureService: Sendable {
    /// Start capturing audio at the given sample rate. Returns a stream of audio buffers.
    func startCapture(sampleRate: Double) throws -> AsyncStream<AVAudioPCMBuffer>

    /// Stop capturing audio.
    func stopCapture()
}

/// Protocol for playing audio through speakers or other output.
public protocol AudioPlaybackService: Sendable {
    /// Whether audio is currently being played.
    var isPlaying: Bool { get }

    /// Play a stream of audio buffers. Returns when playback completes or is stopped.
    func play(buffers: AsyncThrowingStream<AVAudioPCMBuffer, Error>) async throws

    /// Stop any ongoing playback immediately.
    func stop()
}
