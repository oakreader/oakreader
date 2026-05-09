import AVFoundation
import MLX
import MLXAudioTTS
import MLXAudioCore

/// TTSService implementation using MLX Audio TTS (Kokoro, Chatterbox, etc.).
public actor MLXTTSProvider: TTSService {
    private var model: (any SpeechGenerationModel)?
    private let repoId: String
    private let manager: ModelManager?
    private let defaultSampleRate: Double
    private let language: String?

    /// Cached reference audio MLXArray, loaded once from a URL.
    private var cachedRefAudio: MLXArray?
    private var cachedRefAudioURL: URL?

    /// Cached Qwen3-TTS voice conditioning (computed once, reused for every sentence).
    private var cachedConditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning?
    private var cachedConditioningKey: String?

    public nonisolated var sampleRate: Double {
        // Return the default; actual rate is used internally after model loads
        defaultSampleRate
    }

    public init(
        repoId: String = KnownModels.tts[0].repo,
        defaultSampleRate: Double = 24000,
        language: String? = nil,
        manager: ModelManager? = nil
    ) {
        self.repoId = repoId
        self.defaultSampleRate = defaultSampleRate
        self.language = language
        self.manager = manager
    }

    /// Sanitize voice parameter: empty/whitespace-only strings become nil
    /// to prevent models from crashing on invalid voice name lookups.
    private static func sanitizeVoice(_ voice: String?) -> String? {
        guard let v = voice, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return v
    }

    /// Sanitize reference text: empty/whitespace-only strings become nil.
    private static func sanitizeRefText(_ text: String?) -> String? {
        guard let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return t
    }

    public func synthesize(text: String, voice: String?, referenceAudioURL: URL?, referenceText: String?) async throws -> AVAudioPCMBuffer {
        let model = try await ensureModel()
        let safeVoice = Self.sanitizeVoice(voice)
        let safeRefText = Self.sanitizeRefText(referenceText)

        // Try Qwen3-specific conditioning path for consistent voice
        if let qwen3Model = model as? Qwen3TTSModel,
           let conditioning = try getOrCreateConditioning(
               model: qwen3Model, refURL: referenceAudioURL, refText: safeRefText
           ) {
            let audio = try await qwen3Model.generate(
                text: text,
                conditioning: conditioning,
                generationParameters: model.defaultGenerationParameters
            )
            let samples = audio.asArray(Float.self)
            return try samplesToBuffer(samples, sampleRate: Double(model.sampleRate))
        }

        // Fallback: generic protocol path
        let refAudio = try loadReferenceAudio(url: referenceAudioURL)
        let audio = try await model.generate(
            text: text,
            voice: safeVoice,
            refAudio: refAudio,
            refText: safeRefText,
            language: language,
            generationParameters: model.defaultGenerationParameters
        )
        let samples = audio.asArray(Float.self)
        return try samplesToBuffer(samples, sampleRate: Double(model.sampleRate))
    }

    public nonisolated func synthesizeStream(
        text: String,
        voice: String?,
        referenceAudioURL: URL?,
        referenceText: String?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let safeVoice = Self.sanitizeVoice(voice)
        let safeRefText = Self.sanitizeRefText(referenceText)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let model = try await self.ensureModel()
                    let sr = Double(model.sampleRate)

                    // Try Qwen3-specific conditioning path for consistent voice
                    let stream: AsyncThrowingStream<AudioGeneration, Error>
                    if let qwen3Model = model as? Qwen3TTSModel,
                       let conditioning = try await self.getOrCreateConditioning(
                           model: qwen3Model, refURL: referenceAudioURL, refText: safeRefText
                       ) {
                        stream = qwen3Model.generateStream(
                            text: text,
                            conditioning: conditioning,
                            generationParameters: model.defaultGenerationParameters
                        )
                    } else {
                        // Fallback: generic protocol path
                        let refAudio = try await self.loadReferenceAudio(url: referenceAudioURL)
                        stream = model.generateStream(
                            text: text,
                            voice: safeVoice,
                            refAudio: refAudio,
                            refText: safeRefText,
                            language: self.language,
                            generationParameters: model.defaultGenerationParameters
                        )
                    }

                    for try await event in stream {
                        switch event {
                        case .audio(let chunk):
                            let samples = chunk.asArray(Float.self)
                            if !samples.isEmpty {
                                let buffer = try samplesToBuffer(samples, sampleRate: sr)
                                continuation.yield(buffer)
                            }
                        case .token, .info:
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: VoiceAgentError.ttsFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Qwen3 Voice Conditioning

    /// Get or create cached Qwen3-TTS reference conditioning.
    /// Returns nil if the model isn't Qwen3, or refURL/refText are missing.
    private func getOrCreateConditioning(
        model: Qwen3TTSModel,
        refURL: URL?,
        refText: String?
    ) throws -> Qwen3TTSModel.Qwen3TTSReferenceConditioning? {
        guard let refURL, let refText else { return nil }

        // Cache key: URL + text
        let key = "\(refURL.absoluteString)|\(refText)"
        if let cached = cachedConditioning, cachedConditioningKey == key {
            return cached
        }

        let refAudio = try loadReferenceAudio(url: refURL)
        guard let refAudio else { return nil }

        let conditioning = try model.prepareReferenceConditioning(
            refAudio: refAudio,
            refText: refText,
            language: language
        )
        cachedConditioning = conditioning
        cachedConditioningKey = key
        return conditioning
    }

    // MARK: - Reference Audio

    /// Load and cache reference audio from a URL. Returns nil if url is nil.
    private func loadReferenceAudio(url: URL?) throws -> MLXArray? {
        guard let url else { return nil }

        // Return cached if same URL
        if let cachedURL = cachedRefAudioURL, cachedURL == url, let cached = cachedRefAudio {
            return cached
        }

        let (_, audio) = try loadAudioArray(from: url)
        cachedRefAudio = audio
        cachedRefAudioURL = url
        return audio
    }

    // MARK: - Model Loading

    private func ensureModel() async throws -> any SpeechGenerationModel {
        if let model { return model }

        await manager?.setLoading(repoId)
        do {
            let loaded = try await TTS.loadModel(modelRepo: repoId)
            self.model = loaded
            await manager?.setReady(repoId)
            return loaded
        } catch {
            await manager?.setFailed(repoId, error: error)
            throw VoiceAgentError.modelNotLoaded("TTS model failed to load: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helpers

/// Convert Float samples to an AVAudioPCMBuffer.
private func samplesToBuffer(_ samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else {
        throw VoiceAgentError.ttsFailed("Failed to create audio format")
    }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
        throw VoiceAgentError.ttsFailed("Failed to create audio buffer")
    }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
        buffer.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
    }

    return buffer
}
