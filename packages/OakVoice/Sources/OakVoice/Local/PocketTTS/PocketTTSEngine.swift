import AVFoundation
import CoreML
import Foundation

/// On-device text-to-speech using Kyutai's Pocket TTS, converted to Core ML.
///
/// The only TTS provider here that needs no API key and no network at synthesis time. Three
/// models run per utterance:
///
/// ```
/// prompt_phase   text tokens + voice cache  ->  AR start offset, 12 seeded KV buffers
/// calm_stateful  prev latent + noise        ->  next latent, is_eos      (once per 80 ms)
/// mimi_stateful  latent                     ->  1920 PCM samples @ 24 kHz
/// ```
///
/// `prompt_phase` runs once; the other two run once per 80 ms frame and share nothing but the
/// latent. Three details below were measured rather than assumed, and all three matter:
///
/// * **Compute units differ per model.** `prompt_phase` cannot use the Neural Engine at all —
///   its multi-position attention fails `ANECCompile` with error -14 — so it runs CPU+GPU.
///   `calm_stateful` benchmarks fastest on CPU alone (0.0104 s/frame against 0.0219 on `.all`),
///   and `mimi_stateful` fastest on `.all` (0.0322 s/frame against 0.1219 on the ANE, which is
///   by far the worst option). The mix reaches 3.3-3.8x real time on an M5.
/// * **The first autoregressive input is NaN, not zeros.** Zeros are out of distribution and
///   make the model assert end-of-speech on frame 1, which truncates every utterance.
/// * **Per-frame inputs are allocated once and mutated.** Rebuilding the `MLMultiArray`s and
///   the feature provider each frame cost 3.1x (0.17 s/frame against 0.054).
public actor PocketTTSEngine: TTSService {
    // MARK: - Model geometry
    //
    // Fixed by the converted model. Verified against its own `modelDescription`.

    /// CaLM layers exposed as paired `kv_k_N` / `kv_v_N` state buffers.
    private static let layerCount = 6
    /// Latent width per autoregressive step.
    private static let latentDimension = 32
    /// Padded width of the `text_tokens` input.
    private static let textTokenCapacity = 128
    /// PCM samples the decoder emits per step: 80 ms at 24 kHz.
    private static let samplesPerFrame = 1920
    /// The decoder's position advances by this much per latent.
    private static let decoderOffsetPerFrame: Int32 = 16

    // MARK: - Generation rules
    //
    // From Kyutai's reference implementation (`pocket_tts/models/tts_model.py`, MIT).

    /// End-of-speech is ignored for this many frames.
    ///
    /// Kyutai's `_MIN_FRAMES_BEFORE_EOS`. Before speech starts, some voices briefly cross the
    /// threshold, and without this guard a short prompt ends before its word is spoken.
    private static let minFramesBeforeEOS = 6
    /// Sampling temperature. Kyutai's `DEFAULT_TEMPERATURE`.
    private static let temperature: Float = 0.3
    /// Seconds of audio assumed per text token, for the generation cap.
    private static let tokensPerSecondEstimate = 3.0
    /// Slack added to the generation cap.
    private static let generationPaddingSeconds = 2.0
    /// Frames per second of audio: 1 / 0.08.
    private static let frameRate = 12.5

    public nonisolated var sampleRate: Double { 24_000 }

    // MARK: - State

    private let store: PocketTTSModelStore
    private var promptModel: MLModel?
    private var calmModel: MLModel?
    private var decoderModel: MLModel?
    private var tokenizer: PocketTTSTokenizer?
    /// Parsed voice caches, kept because one is ~6 MB and re-reading it per utterance is waste.
    private var voiceStates: [String: PocketTTSVoiceState] = [:]

    public init(store: PocketTTSModelStore = .shared) {
        self.store = store
    }

    /// Load the models and tokenizer, downloading them first if needed.
    ///
    /// Separate from `init` so the caller can show download progress, and idempotent so it can
    /// be called before every utterance without cost.
    public func prepare(
        onDownloadProgress: (@Sendable (PocketTTSModelStore.Progress) -> Void)? = nil
    ) async throws {
        if promptModel != nil, calmModel != nil, decoderModel != nil, tokenizer != nil { return }
        try await store.installIfNeeded(onProgress: onDownloadProgress)

        let started = Date()
        // See the note on compute units in the type documentation.
        promptModel = try load(.promptPhase, units: .cpuAndGPU)
        calmModel = try load(.calmStateful, units: .cpuOnly)
        decoderModel = try load(.mimiStateful, units: .all)
        tokenizer = try PocketTTSTokenizer(
            tokenizerJSONURL: store.installedURL(for: .tokenizer)
        )
        VoiceAgentLog.ttsInfo(
            "[PocketTTS] loaded models in \(String(format: "%.2f", -started.timeIntervalSinceNow))s"
        )
    }

    private func load(_ artifact: PocketTTSModelStore.Artifact, units: MLComputeUnits) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        do {
            return try MLModel(contentsOf: store.installedURL(for: artifact), configuration: configuration)
        } catch {
            throw VoiceAgentError.modelNotLoaded("\(artifact.displayName): \(error)")
        }
    }

    /// Release the models. Called when the user switches to a cloud provider.
    public func unload() {
        promptModel = nil
        calmModel = nil
        decoderModel = nil
        voiceStates.removeAll()
        VoiceAgentLog.ttsInfo("[PocketTTS] unloaded models")
    }

    // MARK: - TTSService

    public nonisolated func synthesize(
        text: String,
        voice: String?,
        referenceAudioURL: URL?,
        referenceText: String?
    ) async throws -> AVAudioPCMBuffer {
        var buffers: [AVAudioPCMBuffer] = []
        for try await buffer in synthesizeStream(
            text: text, voice: voice, referenceAudioURL: referenceAudioURL, referenceText: referenceText
        ) {
            buffers.append(buffer)
        }
        guard let merged = AudioPCM.merge(buffers) else {
            throw VoiceAgentError.ttsFailed("synthesis produced no audio")
        }
        return merged
    }

    /// Stream one buffer per 80 ms frame, so playback starts long before synthesis ends.
    ///
    /// `referenceAudioURL` and `referenceText` are ignored: cloning a voice from arbitrary audio
    /// needs the `voice_prompt_phase` model, which this engine does not install. Voices come
    /// from the catalog instead.
    public nonisolated func synthesizeStream(
        text: String,
        voice: String?,
        referenceAudioURL: URL?,
        referenceText: String?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let voiceID = voice ?? PocketTTSVoiceCatalog.defaultVoiceID
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.generate(text: text, voiceID: voiceID) { buffer in
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Generation

    private func generate(
        text: String,
        voiceID: String,
        emit: @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws {
        try await prepare()
        guard let tokenizer, let promptModel, let calmModel, let decoderModel else {
            throw VoiceAgentError.modelNotLoaded("Pocket TTS")
        }
        let voiceState = try await voiceState(for: voiceID)

        let chunks = PocketTTSTextPreparation.splitIntoChunks(text, tokenizer: tokenizer)
        guard !chunks.isEmpty else { return }

        // Every chunk re-seeds the voice cache, so chunks stay independent and drift cannot
        // accumulate across a long passage.
        for chunk in chunks {
            try Task.checkCancellation()
            let prepared = PocketTTSTextPreparation.prepare(chunk)
            try generateChunk(
                prepared.text,
                framesAfterEOS: prepared.framesAfterEOSGuess + 2,
                voiceState: voiceState,
                tokenizer: tokenizer,
                promptModel: promptModel,
                calmModel: calmModel,
                decoderModel: decoderModel,
                emit: emit
            )
        }
    }

    private func generateChunk(
        _ text: String,
        framesAfterEOS: Int,
        voiceState: PocketTTSVoiceState,
        tokenizer: PocketTTSTokenizer,
        promptModel: MLModel,
        calmModel: MLModel,
        decoderModel: MLModel,
        emit: @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        var tokens = tokenizer.encode(text)
        if tokens.count > Self.textTokenCapacity {
            // The chunker keeps chunks to 50 tokens, so this means one unbroken sentence
            // overran. Truncating beats throwing: the reader loses a clause, not the paragraph.
            VoiceAgentLog.ttsWarning(
                "[PocketTTS] chunk encoded to \(tokens.count) tokens; truncating to \(Self.textTokenCapacity)"
            )
            tokens = Array(tokens.prefix(Self.textTokenCapacity))
        }

        // Shared attention cache: seeded from the voice, extended by the prompt, then advanced
        // one position per frame.
        let kvState = calmModel.makeState()
        try seed(kvState, from: voiceState)

        let textTokens = try multiArray([1, Self.textTokenCapacity], .int32)
        textTokens.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for index in 0..<Self.textTokenCapacity { buffer[index] = 0 }
            for (index, token) in tokens.enumerated() { buffer[index] = token }
        }
        let textLength = try multiArray([1], .int32)
        textLength[0] = NSNumber(value: tokens.count)
        let voiceOffset = try multiArray([1], .int32)
        voiceOffset[0] = NSNumber(value: voiceState.positions)

        let promptOutput = try promptModel.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "text_tokens": textTokens,
                "text_length": textLength,
                "voice_offset": voiceOffset
            ]),
            using: kvState
        )
        guard let promptEnd = promptOutput.featureValue(for: "t_prompt")?.multiArrayValue?[0].int32Value else {
            throw VoiceAgentError.ttsFailed("prompt phase returned no t_prompt")
        }

        // Allocated once and mutated in place; rebuilding these per frame costs 3.1x.
        let decoderState = decoderModel.makeState()
        let previousLatent = try multiArray([1, 1, Self.latentDimension], .float32)
        let noise = try multiArray([1, Self.latentDimension], .float32)
        let calmOffset = try multiArray([1], .int32)
        let latent = try multiArray([1, 1, Self.latentDimension], .float32)
        let decoderOffset = try multiArray([1], .int32)

        // NaN, not zeros. Zeros are out of distribution and assert end-of-speech immediately.
        previousLatent.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for index in 0..<Self.latentDimension { buffer[index] = .nan }
        }

        let calmInputs = try MLDictionaryFeatureProvider(dictionary: [
            "prev_latent": previousLatent, "noise": noise, "offset": calmOffset
        ])
        let decoderInputs = try MLDictionaryFeatureProvider(dictionary: [
            "latent": latent, "offset": decoderOffset
        ])

        let maxFrames = Self.generationCap(tokenCount: tokens.count)
        var generator = SystemRandomNumberGenerator()
        var endOfSpeechFrame: Int?
        var frame = 0

        while frame < maxFrames {
            try Task.checkCancellation()

            noise.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                for index in 0..<Self.latentDimension {
                    buffer[index] = Self.standardNormal(using: &generator) * Self.temperature
                }
            }
            calmOffset[0] = NSNumber(value: promptEnd + Int32(frame))

            let step = try calmModel.prediction(from: calmInputs, using: kvState)
            guard let nextLatent = step.featureValue(for: "next_latent")?.multiArrayValue else {
                throw VoiceAgentError.ttsFailed("generator returned no latent")
            }

            // Kyutai's rule: take the model's own boolean, ignore it for the first few frames,
            // then run on for a few more so the final word is not clipped.
            let isEndOfSpeech = (step.featureValue(for: "is_eos")?.multiArrayValue?[0].floatValue ?? 0) > 0.5
            if isEndOfSpeech, endOfSpeechFrame == nil, frame >= Self.minFramesBeforeEOS {
                endOfSpeechFrame = frame
            }
            if let endOfSpeechFrame, frame >= endOfSpeechFrame + framesAfterEOS { break }

            copy(nextLatent, into: latent)
            decoderOffset[0] = NSNumber(value: Int32(frame) * Self.decoderOffsetPerFrame)
            let decoded = try decoderModel.prediction(from: decoderInputs, using: decoderState)
            guard let pcm = decoded.featureValue(for: "pcm")?.multiArrayValue else {
                throw VoiceAgentError.ttsFailed("decoder returned no audio")
            }
            if let buffer = Self.buffer(from: pcm, sampleRate: 24_000) { emit(buffer) }

            copy(nextLatent, into: previousLatent)
            frame += 1
        }

        if endOfSpeechFrame == nil {
            // Not fatal, but it means the cap cut the utterance rather than the model ending it.
            VoiceAgentLog.ttsWarning(
                "[PocketTTS] hit the \(maxFrames)-frame cap without end-of-speech"
            )
        }
    }

    // MARK: - Voice cache

    private func voiceState(for voiceID: String) async throws -> PocketTTSVoiceState {
        if let cached = voiceStates[voiceID] { return cached }
        let url = try await store.voiceFile(for: voiceID)
        let state: PocketTTSVoiceState
        do {
            state = try PocketTTSVoiceState(contentsOf: url)
        } catch {
            throw VoiceAgentError.ttsFailed("\(error)")
        }
        voiceStates[voiceID] = state
        return state
    }

    /// Write a voice's caches into the model's state buffers, zeroing the unused tail.
    ///
    /// The buffers are `[1, 512, heads, dHead]` Float16 while the voice file is Float32 over
    /// ~125 positions, so this narrows and pads in one pass.
    private func seed(_ state: MLState, from voice: PocketTTSVoiceState) throws {
        let valuesPerPosition = voice.heads * voice.dHead
        let used = voice.positions * valuesPerPosition

        for layer in 0..<Self.layerCount {
            for (name, source) in [
                ("kv_k_\(layer)", voice.keys[layer]),
                ("kv_v_\(layer)", voice.values[layer])
            ] {
                state.withMultiArray(for: name) { (array: MLMultiArray) in
                    array.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in
                        let capacity = buffer.count
                        let copyCount = min(used, capacity)
                        for index in 0..<copyCount { buffer[index] = Float16(source[index]) }
                        if copyCount < capacity {
                            for index in copyCount..<capacity { buffer[index] = 0 }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Frames to allow before giving up, scaled to the text.
    ///
    /// Kyutai's `_estimate_max_gen_len`. Without it a voice that never asserts end-of-speech
    /// babbles on well past the sentence.
    private static func generationCap(tokenCount: Int) -> Int {
        let seconds = Double(tokenCount) / tokensPerSecondEstimate + generationPaddingSeconds
        return Int((seconds * frameRate).rounded(.up))
    }

    private func multiArray(_ shape: [Int], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
    }

    private func copy(_ source: MLMultiArray, into destination: MLMultiArray) {
        source.withUnsafeBufferPointer(ofType: Float.self) { input in
            destination.withUnsafeMutableBufferPointer(ofType: Float.self) { output, _ in
                let count = min(input.count, output.count)
                for index in 0..<count { output[index] = input[index] }
            }
        }
    }

    private static func buffer(from pcm: MLMultiArray, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else { return nil }
        let frames = pcm.count
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBufferPointer(ofType: Float.self) { input in
            for index in 0..<frames { output[index] = input[index] }
        }
        return buffer
    }

    /// Box-Muller normal draw. The model takes noise as an input, so sampling happens here.
    private static func standardNormal(using generator: inout SystemRandomNumberGenerator) -> Float {
        let uniform = Float.random(in: Float.leastNormalMagnitude...1, using: &generator)
        let angle = Float.random(in: 0...1, using: &generator)
        return (-2 * log(uniform)).squareRoot() * cos(2 * .pi * angle)
    }
}
