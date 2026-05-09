import AVFoundation

/// Voice activity detection events.
public enum VADEvent: Sendable {
    case speechStart
    case speechEnd
    case speechContinuing
    case silence
}

/// Protocol for voice activity detection services.
public protocol VADService: Sendable {
    /// Process an audio chunk and return the detected voice activity event.
    func process(chunk: AVAudioPCMBuffer) async throws -> VADEvent

    /// Reset internal state (e.g., between utterances).
    func reset() async
}
