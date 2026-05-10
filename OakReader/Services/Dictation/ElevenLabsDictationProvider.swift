import AVFoundation
import os
import VoiceAgentKit

private let log = Logger(subsystem: "OakReader", category: "ElevenLabsDictation")

/// Dictation provider that wraps ``ElevenLabsSTTProvider`` from VoiceAgentKit.
///
/// Maps ``TranscriptionResult`` values to ``DictationEvent``:
/// - `isFinal: false` → `.partial(text)`
/// - `isFinal: true`  → `.final(text)`
struct ElevenLabsDictationProvider: DictationProvider {
    private let config: ElevenLabsSTTConfig

    init(apiKey: String, modelId: String = "scribe_v2_realtime", languageCode: String = "en") {
        self.config = ElevenLabsSTTConfig(
            apiKey: apiKey,
            modelId: modelId,
            languageCode: languageCode
        )
    }

    func startDictation(audioStream: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<DictationEvent> {
        let config = self.config
        return AsyncStream { continuation in
            let task = Task {
                let provider = ElevenLabsSTTProvider(config: config)
                let resultStream = provider.transcribeStream(audioStream: audioStream)
                do {
                    for try await result in resultStream {
                        if Task.isCancelled { break }
                        let event: DictationEvent = result.isFinal
                            ? .final(result.text)
                            : .partial(result.text)
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        log.error("ElevenLabs dictation error: \(error.localizedDescription)")
                        continuation.yield(.error(error.localizedDescription))
                    }
                    continuation.finish()
                }
                // Disconnect when done
                await provider.disconnect()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
