import AVFoundation
import SpeechVAD

/// VADService implementation using speech-swift's Silero VAD.
///
/// Silero VAD requires fixed-size chunks (512 samples at 16 kHz).
/// This provider accumulates incoming audio frames and processes
/// them in exact 512-sample windows.
///
/// Two key improvements over naive thresholding (matching LiveKit/OpenAI):
/// - **Hysteresis**: activation threshold (default 0.5) is higher than
///   deactivation (default 0.35), preventing rapid toggling near the boundary.
/// - **Silence debounce**: `speechEnd` only fires after sustained silence
///   (~500ms at 16kHz), not on the first below-threshold frame.
public actor MLXVADProvider: VADService {
    private var model: SileroVADModel?
    private let repoId: String
    private let threshold: Float
    private let negThreshold: Float
    private let minSilenceWindows: Int
    private let manager: ModelManager?

    /// Whether speech was detected in the previous chunk (for edge detection).
    private var wasSpeaking = false

    /// Accumulator for incoming samples until we have a full VAD window.
    private var sampleAccumulator: [Float] = []

    /// Consecutive below-threshold windows counted during silence debounce.
    private var silenceWindowCount: Int = 0

    /// Silero VAD requires exactly this many samples per feed at 16 kHz.
    private static let vadWindowSize = 512

    public init(
        repoId: String = KnownModels.vad[0].repo,
        threshold: Float = 0.5,
        negThreshold: Float? = nil,
        minSilenceWindows: Int = 16,
        manager: ModelManager? = nil
    ) {
        self.repoId = repoId
        self.threshold = threshold
        self.negThreshold = negThreshold ?? max(threshold - 0.15, 0.01)
        self.minSilenceWindows = minSilenceWindows
        self.manager = manager
    }

    public func process(chunk: AVAudioPCMBuffer) async throws -> VADEvent {
        let model = try await ensureModel()

        guard let floatData = chunk.floatChannelData else {
            throw VoiceAgentError.vadFailed("Audio buffer has no float channel data")
        }

        let frameCount = Int(chunk.frameLength)
        let newSamples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
        sampleAccumulator.append(contentsOf: newSamples)

        // Process all complete windows.
        // Edge transitions (speechStart / speechEnd) take priority over
        // steady-state events (speechContinuing / silence).
        var priorityEvent: VADEvent?
        var steadyEvent: VADEvent = wasSpeaking ? .speechContinuing : .silence

        while sampleAccumulator.count >= Self.vadWindowSize {
            let window = Array(sampleAccumulator.prefix(Self.vadWindowSize))
            sampleAccumulator.removeFirst(Self.vadWindowSize)

            let prob = model.processChunk(window)

            // Hysteresis: use higher threshold to START speech, lower to STOP.
            let effectiveThreshold = wasSpeaking ? negThreshold : threshold
            let isSpeaking = prob >= effectiveThreshold

            if isSpeaking && !wasSpeaking {
                silenceWindowCount = 0
                wasSpeaking = true
                return .speechStart
            } else if !isSpeaking && wasSpeaking {
                silenceWindowCount += 1
                if silenceWindowCount >= minSilenceWindows {
                    priorityEvent = .speechEnd
                    steadyEvent = .silence
                    wasSpeaking = false
                    silenceWindowCount = 0
                } else {
                    steadyEvent = .speechContinuing
                }
            } else if isSpeaking {
                silenceWindowCount = 0
                if priorityEvent == .speechEnd {
                    priorityEvent = nil
                }
                steadyEvent = .speechContinuing
            } else {
                steadyEvent = .silence
            }
        }

        return priorityEvent ?? steadyEvent
    }

    public func reset() async {
        model?.resetState()
        wasSpeaking = false
        sampleAccumulator = []
        silenceWindowCount = 0
    }

    private func ensureModel() async throws -> SileroVADModel {
        if let model { return model }

        await manager?.setLoading(repoId)
        do {
            let loaded = try await SileroVADModel.fromPretrained(modelId: repoId)
            self.model = loaded
            await manager?.setReady(repoId)
            return loaded
        } catch {
            await manager?.setFailed(repoId, error: error)
            throw VoiceAgentError.modelNotLoaded("VAD model failed to load: \(error.localizedDescription)")
        }
    }
}
