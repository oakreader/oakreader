import CoreML
import Foundation

/// Runs one utterance through the models and hands back raw audio frames.
///
/// Deliberately narrow: it takes already-prepared text and an already-parsed voice, and emits
/// `Float` samples. It does not chunk text, touch AVFoundation, or know where models came from.
/// That keeps the autoregressive loop — the part where a wrong constant is silently audible
/// rather than a compile error — small enough to read in one sitting.
///
/// ```
/// promptEncoder    text tokens + voice cache  ->  start offset, 12 seeded KV buffers
/// speechGenerator  previous latent + noise    ->  next latent, end-of-speech   (per frame)
/// audioDecoder     latent                     ->  1920 samples @ 24 kHz        (per frame)
/// ```
struct PocketTTSSynthesizer {
    /// 80 ms of mono audio at 24 kHz: the unit the decoder emits per step.
    struct Frame: Sendable {
        let samples: [Float]
    }

    // MARK: - Model geometry
    //
    // Fixed by the converted model and verified against its own `modelDescription`.

    /// CaLM layers exposed as paired `kv_k_N` / `kv_v_N` state buffers.
    static let layerCount = 6
    /// Latent width per autoregressive step.
    private static let latentWidth = 32
    /// Padded width of the `text_tokens` input. Also the hard token limit per utterance.
    static let textTokenCapacity = 128
    /// The decoder's position advances by this much per latent.
    private static let decoderOffsetPerFrame: Int32 = 16
    /// Audio frames per second: one per 80 ms.
    static let frameRate = 12.5

    // MARK: - Generation rules
    //
    // From Kyutai's reference implementation, `pocket_tts/models/tts_model.py` (MIT).

    /// End-of-speech is ignored for this many frames.
    ///
    /// Kyutai's `_MIN_FRAMES_BEFORE_EOS`. Before speech starts, some voices briefly assert
    /// end-of-speech, and without this guard a short prompt ends before its word is spoken.
    private static let minFramesBeforeEndOfSpeech = 6
    /// Sampling temperature. Kyutai's `DEFAULT_TEMPERATURE`.
    ///
    /// Note that both third-party ports use 0.7, which is stale; upstream is 0.3.
    private static let temperature: Float = 0.3
    /// Text tokens assumed per second of speech, for the generation cap.
    private static let tokensPerSecondEstimate = 3.0
    /// Slack added to the generation cap.
    private static let generationPaddingSeconds = 2.0

    private let bundle: PocketTTSModelBundle

    init(bundle: PocketTTSModelBundle) {
        self.bundle = bundle
    }

    /// Synthesize one prepared chunk, calling `emit` as each frame is decoded.
    ///
    /// - Parameters:
    ///   - text: already conditioned by ``PocketTTSTextPreparation``.
    ///   - framesAfterEndOfSpeech: extra frames to run past end-of-speech so the final word is
    ///     not clipped.
    func synthesize(
        text: String,
        voice: PocketTTSVoiceState,
        framesAfterEndOfSpeech: Int,
        emit: (Frame) -> Void
    ) throws {
        var tokens = bundle.tokenizer.encode(text)
        if tokens.count > Self.textTokenCapacity {
            // The chunker keeps chunks near 50 tokens, so this means one unbroken sentence
            // overran. Truncating beats throwing: the reader loses a clause, not the paragraph.
            VoiceAgentLog.ttsWarning(
                "[PocketTTS] chunk encoded to \(tokens.count) tokens; "
                    + "truncating to \(Self.textTokenCapacity)"
            )
            tokens = Array(tokens.prefix(Self.textTokenCapacity))
        }

        // Shared attention cache: seeded from the voice, extended by the prompt encoder, then
        // advanced one position per frame.
        let attentionCache = bundle.speechGenerator.makeState()
        try seed(attentionCache, from: voice)
        let startOffset = try runPromptEncoder(tokens: tokens, voice: voice, cache: attentionCache)

        // Allocated once and mutated in place. Rebuilding these per frame costs 3.1x
        // (0.17 s/frame against 0.054), which is the difference between slower than real time
        // and comfortably faster.
        let decoderState = bundle.audioDecoder.makeState()
        let previousLatent = try Self.array([1, 1, Self.latentWidth], .float32)
        let noise = try Self.array([1, Self.latentWidth], .float32)
        let generatorOffset = try Self.array([1], .int32)
        let latent = try Self.array([1, 1, Self.latentWidth], .float32)
        let decoderOffset = try Self.array([1], .int32)

        // NaN, not zeros. Zeros are out of distribution and make the model assert
        // end-of-speech on frame 1, which truncates every utterance to nothing.
        previousLatent.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for index in 0..<Self.latentWidth { buffer[index] = .nan }
        }

        let generatorInputs = try MLDictionaryFeatureProvider(dictionary: [
            "prev_latent": previousLatent, "noise": noise, "offset": generatorOffset
        ])
        let decoderInputs = try MLDictionaryFeatureProvider(dictionary: [
            "latent": latent, "offset": decoderOffset
        ])

        let frameCap = Self.generationCap(tokenCount: tokens.count)
        var randomness = SystemRandomNumberGenerator()
        var endOfSpeechFrame: Int?
        var frame = 0

        while frame < frameCap {
            try Task.checkCancellation()

            // The model takes its noise as an input, so sampling happens on this side.
            noise.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                for index in 0..<Self.latentWidth {
                    buffer[index] = Self.standardNormal(using: &randomness) * Self.temperature
                }
            }
            generatorOffset[0] = NSNumber(value: startOffset + Int32(frame))

            let step = try bundle.speechGenerator.prediction(
                from: generatorInputs, using: attentionCache
            )
            guard let nextLatent = step.featureValue(for: "next_latent")?.multiArrayValue else {
                throw VoiceAgentError.ttsFailed("speech generator returned no latent")
            }

            // Kyutai's stop rule: take the model's own boolean rather than thresholding the
            // logit, ignore it during the run-up, then run on a few frames so the last word
            // is not clipped.
            let ended = (step.featureValue(for: "is_eos")?.multiArrayValue?[0].floatValue ?? 0) > 0.5
            if ended, endOfSpeechFrame == nil, frame >= Self.minFramesBeforeEndOfSpeech {
                endOfSpeechFrame = frame
            }
            if let endOfSpeechFrame, frame >= endOfSpeechFrame + framesAfterEndOfSpeech { break }

            Self.copy(nextLatent, into: latent)
            decoderOffset[0] = NSNumber(value: Int32(frame) * Self.decoderOffsetPerFrame)
            let decoded = try bundle.audioDecoder.prediction(from: decoderInputs, using: decoderState)
            guard let pcm = decoded.featureValue(for: "pcm")?.multiArrayValue else {
                throw VoiceAgentError.ttsFailed("audio decoder returned no samples")
            }
            emit(Frame(samples: Self.samples(from: pcm)))

            Self.copy(nextLatent, into: previousLatent)
            frame += 1
        }

        if endOfSpeechFrame == nil {
            // Not fatal, but it means the cap ended the utterance rather than the model, so
            // the tail is arbitrary rather than a finished sentence.
            VoiceAgentLog.ttsWarning(
                "[PocketTTS] hit the \(frameCap)-frame cap without end-of-speech"
            )
        }
    }

    // MARK: - Prompt phase

    private func runPromptEncoder(
        tokens: [Int32],
        voice: PocketTTSVoiceState,
        cache: MLState
    ) throws -> Int32 {
        let textTokens = try Self.array([1, Self.textTokenCapacity], .int32)
        textTokens.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for index in 0..<Self.textTokenCapacity { buffer[index] = 0 }
            for (index, token) in tokens.enumerated() { buffer[index] = token }
        }
        let textLength = try Self.array([1], .int32)
        textLength[0] = NSNumber(value: tokens.count)
        let voiceOffset = try Self.array([1], .int32)
        voiceOffset[0] = NSNumber(value: voice.positions)

        let output = try bundle.promptEncoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "text_tokens": textTokens,
                "text_length": textLength,
                "voice_offset": voiceOffset
            ]),
            using: cache
        )
        guard let start = output.featureValue(for: "t_prompt")?.multiArrayValue?[0].int32Value else {
            throw VoiceAgentError.ttsFailed("prompt encoder returned no start offset")
        }
        return start
    }

    /// Write a voice's caches into the model's state buffers, zeroing the unused tail.
    ///
    /// The buffers are `[1, 512, heads, dHead]` Float16 while a voice file holds Float32 over
    /// ~125 positions, so this narrows and pads in a single pass.
    private func seed(_ state: MLState, from voice: PocketTTSVoiceState) throws {
        let used = voice.positions * voice.heads * voice.dHead
        for layer in 0..<Self.layerCount {
            for (name, source) in [
                ("kv_k_\(layer)", voice.keys[layer]),
                ("kv_v_\(layer)", voice.values[layer])
            ] {
                state.withMultiArray(for: name) { (array: MLMultiArray) in
                    array.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in
                        let copyCount = min(used, buffer.count)
                        for index in 0..<copyCount { buffer[index] = Float16(source[index]) }
                        for index in copyCount..<buffer.count { buffer[index] = 0 }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Frames to allow before giving up, scaled to the text.
    ///
    /// Kyutai's `_estimate_max_gen_len`. Without it, a voice that never asserts end-of-speech
    /// carries on babbling well past the sentence.
    static func generationCap(tokenCount: Int) -> Int {
        let seconds = Double(tokenCount) / tokensPerSecondEstimate + generationPaddingSeconds
        return Int((seconds * frameRate).rounded(.up))
    }

    private static func array(_ shape: [Int], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
    }

    private static func copy(_ source: MLMultiArray, into destination: MLMultiArray) {
        source.withUnsafeBufferPointer(ofType: Float.self) { input in
            destination.withUnsafeMutableBufferPointer(ofType: Float.self) { output, _ in
                for index in 0..<min(input.count, output.count) { output[index] = input[index] }
            }
        }
    }

    private static func samples(from pcm: MLMultiArray) -> [Float] {
        pcm.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
    }

    /// Box-Muller normal draw.
    private static func standardNormal(using generator: inout SystemRandomNumberGenerator) -> Float {
        let uniform = Float.random(in: Float.leastNormalMagnitude...1, using: &generator)
        let angle = Float.random(in: 0...1, using: &generator)
        return (-2 * log(uniform)).squareRoot() * cos(2 * .pi * angle)
    }
}
