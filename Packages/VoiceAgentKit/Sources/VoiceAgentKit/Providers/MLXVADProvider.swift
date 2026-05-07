import AVFoundation
import MLX
import MLXAudioVAD

/// VADService implementation using Silero VAD from mlx-audio-swift.
///
/// Silero VAD requires fixed-size chunks (512 samples at 16 kHz).
/// This provider accumulates incoming audio frames and processes
/// them in exact 512-sample windows.
public actor MLXVADProvider: VADService {
    private var model: SileroVAD?
    private var streamingState: SileroVADStreamingState?
    private let repoId: String
    private let threshold: Float
    private let manager: ModelManager?

    /// Whether speech was detected in the previous chunk (for edge detection).
    private var wasSpeaking = false

    /// Accumulator for incoming samples until we have a full VAD window.
    private var sampleAccumulator: [Float] = []

    /// Silero VAD requires exactly this many samples per feed at 16 kHz.
    private static let vadWindowSize = 512

    public init(
        repoId: String = KnownModels.vad[0].repo,
        threshold: Float = 0.5,
        manager: ModelManager? = nil
    ) {
        self.repoId = repoId
        self.threshold = threshold
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
            let isSpeaking = prob >= threshold

            if isSpeaking && !wasSpeaking {
                // Edge: silence → speech. Return immediately — don't process
                // more windows so the pipeline can start buffering audio.
                wasSpeaking = true
                return .speechStart
            } else if !isSpeaking && wasSpeaking {
                // Edge: speech → silence. Mark as priority but continue
                // processing in case speech resumes in the same batch.
                priorityEvent = .speechEnd
                steadyEvent = .silence
            } else if isSpeaking {
                // If we saw speechEnd earlier but speech resumed, cancel it.
                if priorityEvent == .speechEnd {
                    priorityEvent = nil
                }
                steadyEvent = .speechContinuing
            } else {
                steadyEvent = .silence
            }
            wasSpeaking = isSpeaking
        }

        return priorityEvent ?? steadyEvent
    }

    public func reset() async {
        streamingState = nil
        wasSpeaking = false
        sampleAccumulator = []
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
