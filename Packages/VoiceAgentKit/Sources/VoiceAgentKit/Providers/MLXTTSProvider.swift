import AVFoundation
import AudioCommon
import CosyVoiceTTS
import Qwen3TTS
import KokoroTTS

/// Which TTS engine a given model repo maps to.
public enum TTSEngine: Sendable {
    case cosyVoice
    case qwen3
    case kokoro

    /// Detect engine from the model repo ID.
    public static func detect(from repo: String) -> TTSEngine {
        let lower = repo.lowercased()
        if lower.contains("cosyvoice") { return .cosyVoice }
        if lower.contains("kokoro") { return .kokoro }
        return .qwen3
    }
}

/// TTSService implementation using speech-swift's TTS models.
/// Supports CosyVoice3, Qwen3-TTS, and Kokoro via engine detection.
public actor MLXTTSProvider: TTSService {
    private let repoId: String
    private let manager: ModelManager?
    private let language: String?
    private let engine: TTSEngine

    // Lazily loaded model (only one will be set)
    private var cosyModel: CosyVoiceTTSModel?
    private var qwen3Model: Qwen3TTSModel?
    private var kokoroModel: KokoroTTSModel?

    /// Cached reference audio samples for voice cloning (raw audio for Qwen3).
    private var cachedRefSamples: [Float]?
    private var cachedRefURL: URL?

    /// Cached 192-dim speaker embedding for CosyVoice voice cloning.
    private var cachedCosyEmbedding: [Float]?
    private var cachedCosyEmbeddingURL: URL?

    /// CAM++ speaker encoder for extracting CosyVoice embeddings.
    private var speakerEncoder: CamPlusPlusSpeaker?

    public nonisolated var sampleRate: Double { 24000 }

    public init(
        repoId: String = KnownModels.tts[0].repo,
        language: String? = nil,
        manager: ModelManager? = nil
    ) {
        self.repoId = repoId
        self.language = language
        self.manager = manager
        self.engine = TTSEngine.detect(from: repoId)
    }

    // MARK: - TTSService conformance

    public func synthesize(text: String, voice: String?, referenceAudioURL: URL?, referenceText: String?) async throws -> AVAudioPCMBuffer {
        let samples = try await generateSamples(text: text, voice: voice, referenceAudioURL: referenceAudioURL)
        return try samplesToBuffer(samples, sampleRate: 24000)
    }

    public nonisolated func synthesizeStream(
        text: String,
        voice: String?,
        referenceAudioURL: URL?,
        referenceText: String?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let stream = try await self.generateStream(text: text, voice: voice, referenceAudioURL: referenceAudioURL)
                    for try await chunk in stream {
                        if !chunk.samples.isEmpty {
                            let buffer = try samplesToBuffer(chunk.samples, sampleRate: 24000)
                            continuation.yield(buffer)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: VoiceAgentError.ttsFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Engine-specific generation

    private func generateSamples(text: String, voice: String?, referenceAudioURL: URL?) async throws -> [Float] {
        let lang = language ?? "english"

        switch engine {
        case .cosyVoice:
            let model = try await ensureCosyModel()
            if let embedding = try await loadCosyVoiceEmbedding(url: referenceAudioURL) {
                return model.synthesize(text: text, language: lang, speakerEmbedding: embedding)
            }
            return model.synthesize(text: text, language: lang)

        case .qwen3:
            let model = try await ensureQwen3Model()
            if let refSamples = try loadReferenceAudio(url: referenceAudioURL) {
                return model.synthesizeWithVoiceClone(
                    text: text,
                    referenceAudio: refSamples,
                    referenceSampleRate: 24000,
                    language: lang
                )
            }
            return model.synthesize(text: text, language: lang, speaker: voice)

        case .kokoro:
            let model = try await ensureKokoroModel()
            let v = voice ?? KokoroTTSModel.defaultVoice
            let langCode = language ?? "en"
            return try model.synthesize(text: text, voice: v, language: langCode)
        }
    }

    private func generateStream(text: String, voice: String?, referenceAudioURL: URL?) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let lang = language ?? "english"

        switch engine {
        case .cosyVoice:
            let model = try await ensureCosyModel()
            if let embedding = try await loadCosyVoiceEmbedding(url: referenceAudioURL) {
                // Voice cloning: single-shot synthesis with CAM++ speaker embedding
                let samples = model.synthesize(text: text, language: lang, speakerEmbedding: embedding)
                return singleChunkStream(samples)
            }
            return model.synthesizeStream(text: text, language: lang)

        case .qwen3:
            let model = try await ensureQwen3Model()
            if let refSamples = try loadReferenceAudio(url: referenceAudioURL) {
                // Qwen3 streaming doesn't support voice cloning — single-shot fallback
                let samples = model.synthesizeWithVoiceClone(
                    text: text,
                    referenceAudio: refSamples,
                    referenceSampleRate: 24000,
                    language: lang
                )
                return singleChunkStream(samples)
            }
            return model.synthesizeStream(text: text, language: lang, speaker: voice)

        case .kokoro:
            // Kokoro doesn't support streaming — synthesize in one shot and yield as a single chunk
            let model = try await ensureKokoroModel()
            let v = voice ?? KokoroTTSModel.defaultVoice
            let langCode = language ?? "en"
            let samples = try model.synthesize(text: text, voice: v, language: langCode)
            return singleChunkStream(samples)
        }
    }

    /// Wrap synthesized samples as a single-chunk AsyncThrowingStream.
    private nonisolated func singleChunkStream(_ samples: [Float]) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(AudioChunk(samples: samples, sampleRate: 24000, frameIndex: 0, isFinal: true, elapsedTime: nil, textTokens: []))
            continuation.finish()
        }
    }

    // MARK: - Reference Audio & Speaker Embedding

    /// Extract a 192-dim CosyVoice speaker embedding from reference audio.
    /// Uses CAM++ speaker encoder (CoreML, runs on Neural Engine).
    /// Result is cached per URL to avoid re-extraction on every sentence.
    private func loadCosyVoiceEmbedding(url: URL?) async throws -> [Float]? {
        guard let url else { return nil }

        // Return cached if same URL
        if let cachedURL = cachedCosyEmbeddingURL, cachedURL == url, let cached = cachedCosyEmbedding {
            return cached
        }

        // Load audio file directly to get both samples and native sample rate
        let audioFile = try AVAudioFile(forReading: url)
        let fileSampleRate = Int(audioFile.fileFormat.sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(fileSampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        try audioFile.read(into: buffer)
        guard let floatData = buffer.floatChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength)))

        // Load speaker encoder on first use
        if speakerEncoder == nil {
            speakerEncoder = try await CamPlusPlusSpeaker.fromPretrained()
        }

        // Extract 192-dim embedding with correct sample rate
        let embedding = try speakerEncoder!.embed(audio: samples, sampleRate: fileSampleRate)

        cachedCosyEmbedding = embedding
        cachedCosyEmbeddingURL = url
        return embedding
    }

    private func loadReferenceAudio(url: URL?) throws -> [Float]? {
        guard let url else { return nil }

        // Return cached if same URL
        if let cachedURL = cachedRefURL, cachedURL == url, let cached = cachedRefSamples {
            return cached
        }

        // Load WAV file into float samples
        let audioFile = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audioFile.fileFormat.sampleRate, channels: 1, interleaved: false) else {
            return nil
        }
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        try audioFile.read(into: buffer)

        guard let floatData = buffer.floatChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength)))

        cachedRefSamples = samples
        cachedRefURL = url
        return samples
    }

    // MARK: - Model Loading

    private func ensureCosyModel() async throws -> CosyVoiceTTSModel {
        if let cosyModel { return cosyModel }

        await manager?.setLoading(repoId)
        do {
            let loaded = try await CosyVoiceTTSModel.fromPretrained(modelId: repoId)
            self.cosyModel = loaded
            await manager?.setReady(repoId)
            return loaded
        } catch {
            await manager?.setFailed(repoId, error: error)
            throw VoiceAgentError.modelNotLoaded("CosyVoice TTS model failed to load: \(error.localizedDescription)")
        }
    }

    private func ensureQwen3Model() async throws -> Qwen3TTSModel {
        if let qwen3Model { return qwen3Model }

        await manager?.setLoading(repoId)
        do {
            let loaded = try await Qwen3TTSModel.fromPretrained(modelId: repoId)
            self.qwen3Model = loaded
            await manager?.setReady(repoId)
            return loaded
        } catch {
            await manager?.setFailed(repoId, error: error)
            throw VoiceAgentError.modelNotLoaded("Qwen3 TTS model failed to load: \(error.localizedDescription)")
        }
    }

    private func ensureKokoroModel() async throws -> KokoroTTSModel {
        if let kokoroModel { return kokoroModel }

        await manager?.setLoading(repoId)
        do {
            let loaded = try await KokoroTTSModel.fromPretrained(modelId: repoId)
            self.kokoroModel = loaded
            await manager?.setReady(repoId)
            return loaded
        } catch {
            await manager?.setFailed(repoId, error: error)
            throw VoiceAgentError.modelNotLoaded("Kokoro TTS model failed to load: \(error.localizedDescription)")
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
