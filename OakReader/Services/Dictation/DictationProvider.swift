import AVFoundation

/// Events emitted by a dictation provider during real-time transcription.
enum DictationEvent: Sendable {
    /// Interim (partial) transcription text — keep replacing the placeholder.
    case partial(String)
    /// Final committed transcription text — insert permanently and advance cursor.
    case final(String)
    /// An error occurred during dictation.
    case error(String)
}

/// A provider that converts a stream of audio buffers into dictation events.
///
/// Conforming types wrap an underlying STT engine (e.g. ElevenLabs Scribe,
/// on-device MLX, or OpenAI Realtime) and expose a uniform event stream
/// for the ``DictationService`` orchestrator.
protocol DictationProvider: Sendable {
    /// Begin transcribing audio from the given stream.
    ///
    /// Returns an `AsyncStream` of ``DictationEvent`` values. The stream
    /// finishes when the audio stream ends or the provider encounters a
    /// terminal error.
    func startDictation(audioStream: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<DictationEvent>
}
