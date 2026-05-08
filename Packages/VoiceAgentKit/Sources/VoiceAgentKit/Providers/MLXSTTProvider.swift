import AVFoundation
import Qwen3ASR
import AudioCommon

/// STTService implementation using speech-swift's Qwen3-ASR.
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
        let samples = pcmBufferToFloats(audio)

        let text = model.transcribe(audio: samples, sampleRate: 16000)

        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            isFinal: true,
            language: nil,
            confidence: nil
        )
    }

    public nonisolated func transcribeStream(
        audioStream: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionResult, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Accumulate all audio buffers into a single sample array
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
                    let text = model.transcribe(audio: allSamples, sampleRate: 16000)

                    continuation.yield(TranscriptionResult(
                        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                        isFinal: true,
                        language: nil,
                        confidence: nil
                    ))

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
            let loaded = try await Qwen3ASRModel.fromPretrained(modelId: repoId)
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

/// Convert an AVAudioPCMBuffer to a [Float] sample array.
func pcmBufferToFloats(_ buffer: AVAudioPCMBuffer) -> [Float] {
    guard let floatData = buffer.floatChannelData else { return [] }
    let count = Int(buffer.frameLength)
    return Array(UnsafeBufferPointer(start: floatData[0], count: count))
}
