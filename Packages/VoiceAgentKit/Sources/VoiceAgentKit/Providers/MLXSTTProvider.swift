import AVFoundation
import MLX
import MLXAudioSTT
import MLXAudioCore

/// STTService implementation using MLX Audio STT (Qwen3-ASR).
public actor MLXSTTProvider: STTService {
    private var model: Qwen3ASRModel?
    private let repoId: String
    private let manager: ModelManager?

    public init(
        repoId: String = KnownModels.stt[0].repo,
        manager: ModelManager? = nil
    ) {
        self.repoId = repoId
        self.manager = manager
    }

    public func transcribe(audio: AVAudioPCMBuffer) async throws -> TranscriptionResult {
        let model = try await ensureModel()
        let audioArray = try pcmBufferToMLXArray(audio)

        let output = model.generate(audio: audioArray)

        return TranscriptionResult(
            text: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
            isFinal: true,
            language: output.language,
            confidence: nil
        )
    }

    public nonisolated func transcribeStream(
        audioStream: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionResult, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Accumulate audio buffers into a single array for batch transcription
                    var allSamples: [Float] = []
                    for await buffer in audioStream {
                        guard let floatData = buffer.floatChannelData else { continue }
                        let count = Int(buffer.frameLength)
                        let samples = Array(UnsafeBufferPointer(start: floatData[0], count: count))
                        allSamples.append(contentsOf: samples)
                    }

                    guard !allSamples.isEmpty else {
                        continuation.finish()
                        return
                    }

                    let model = try await self.ensureModel()
                    let audioArray = MLXArray(allSamples)

                    let stream = model.generateStream(audio: audioArray)

                    var accumulatedText = ""
                    for try await event in stream {
                        switch event {
                        case .token(let token):
                            accumulatedText += token
                            continuation.yield(TranscriptionResult(
                                text: accumulatedText,
                                isFinal: false
                            ))
                        case .result(let output):
                            continuation.yield(TranscriptionResult(
                                text: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                isFinal: true,
                                language: output.language
                            ))
                        case .info:
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: VoiceAgentError.sttFailed(error.localizedDescription))
                }
            }
        }
    }

    private func ensureModel() async throws -> Qwen3ASRModel {
        if let model { return model }

        await manager?.setLoading(repoId)
        do {
            let loaded = try await Qwen3ASRModel.fromPretrained(repoId)
            self.model = loaded
            await manager?.setReady(repoId)
            return loaded
        } catch {
            await manager?.setFailed(repoId, error: error)
            throw VoiceAgentError.modelNotLoaded("STT model failed to load: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helpers

/// Convert an AVAudioPCMBuffer to an MLXArray of Float32 samples.
func pcmBufferToMLXArray(_ buffer: AVAudioPCMBuffer) throws -> MLXArray {
    guard let floatData = buffer.floatChannelData else {
        throw VoiceAgentError.sttFailed("Audio buffer has no float channel data")
    }
    let count = Int(buffer.frameLength)
    let samples = Array(UnsafeBufferPointer(start: floatData[0], count: count))
    return MLXArray(samples)
}
