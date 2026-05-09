import AVFoundation
import MLX
import MLXAudioVAD

/// VADService implementation using Silero VAD from mlx-audio-swift.
///
/// Silero VAD requires fixed-size chunks (512 samples at 16 kHz).
/// This provider accumulates incoming audio frames and processes
/// them in exact 512-sample windows.
///
/// Two key improvements over naive thresholding (matching LiveKit/OpenAI):
/// - **Hysteresis**: activation threshold (default 0.5) is higher than
///   deactivation (default 0.35), preventing rapid toggling near the boundary.
/// - **Silence debounce**: `speechEnd` only fires after sustained silence
///   (~500ms at 16kHz), not on the first below-threshold frame. This prevents
///   mid-sentence pauses from fragmenting the utterance.
public actor MLXVADProvider: VADService {
    private var model: SileroVAD?
    private var streamingState: SileroVADStreamingState?
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

    /// - Parameters:
    ///   - repoId: HuggingFace repo for the Silero VAD model.
    ///   - threshold: Activation threshold — speech starts when probability ≥ this value.
    ///     LiveKit, OpenAI, and Silero all default to 0.5.
    ///   - negThreshold: Deactivation threshold — speech continues while probability ≥ this
    ///     value and ends when it drops below. Defaults to `threshold − 0.15` (LiveKit convention).
    ///   - minSilenceWindows: Number of consecutive below-threshold VAD windows required
    ///     before firing `speechEnd`. At 16 kHz / 512 samples per window (32ms each),
    ///     16 windows ≈ 500ms — matching LiveKit (550ms) and OpenAI (500ms) defaults.
    ///   - manager: Optional model manager for loading state reporting.
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

        let sampleRate = Int(chunk.format.sampleRate)

        if streamingState == nil {
            streamingState = try model.initialState(batchSize: 1, sampleRate: sampleRate)
        }

        // Process all complete windows.
        // Edge transitions (speechStart / speechEnd) take priority over
        // steady-state events (speechContinuing / silence) to avoid
        // losing critical events when multiple windows are processed.
        var priorityEvent: VADEvent?
        var steadyEvent: VADEvent = wasSpeaking ? .speechContinuing : .silence

        while sampleAccumulator.count >= Self.vadWindowSize {
            let window = Array(sampleAccumulator.prefix(Self.vadWindowSize))
            sampleAccumulator.removeFirst(Self.vadWindowSize)

            let audioArray = MLXArray(window)
            let (probability, newState) = try model.feed(
                chunk: audioArray,
                state: streamingState,
                sampleRate: sampleRate
            )
            streamingState = newState

            let prob = probability.item(Float.self)
            // Hysteresis: use higher threshold to START speech, lower to STOP.
            let effectiveThreshold = wasSpeaking ? negThreshold : threshold
            let isSpeaking = prob >= effectiveThreshold

            if isSpeaking && !wasSpeaking {
                // Edge: silence → speech. Return immediately — don't process
                // more windows so the pipeline can start buffering audio.
                silenceWindowCount = 0
                wasSpeaking = true
                return .speechStart
            } else if !isSpeaking && wasSpeaking {
                // Potential speech → silence. Debounce: require sustained silence
                // before confirming speechEnd (~500ms at 16kHz default).
                silenceWindowCount += 1
                if silenceWindowCount >= minSilenceWindows {
                    // Confirmed end — enough sustained silence
                    priorityEvent = .speechEnd
                    steadyEvent = .silence
                    wasSpeaking = false
                    silenceWindowCount = 0
                } else {
                    // Still debouncing — report as continuing (speech hasn't
                    // officially ended yet, this may be a mid-sentence pause)
                    steadyEvent = .speechContinuing
                }
            } else if isSpeaking {
                // Speech continuing — reset silence debounce counter
                silenceWindowCount = 0
                if priorityEvent == .speechEnd {
                    priorityEvent = nil
                }
                steadyEvent = .speechContinuing
            } else {
                steadyEvent = .silence
            }
            // Note: wasSpeaking is managed explicitly in each branch above
            // (set true in speechStart, set false in confirmed speechEnd).
        }

        return priorityEvent ?? steadyEvent
    }

    public func reset() async {
        streamingState = nil
        wasSpeaking = false
        sampleAccumulator = []
        silenceWindowCount = 0
    }

    private func ensureModel() async throws -> SileroVAD {
        if let model { return model }

        await manager?.setLoading(repoId)
        do {
            let loaded = try await SileroVAD.fromPretrained(repoId)
            self.model = loaded
            await manager?.setReady(repoId)
            return loaded
        } catch {
            await manager?.setFailed(repoId, error: error)
            throw VoiceAgentError.modelNotLoaded("VAD model failed to load: \(error.localizedDescription)")
        }
    }
}
