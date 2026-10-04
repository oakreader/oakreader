import AVFoundation
import Foundation

/// On-device text-to-speech using Kyutai's Pocket TTS.
///
/// The only TTS provider here that needs no API key and no network at synthesis time, so
/// read-aloud works before the user has configured anything and no audio leaves the Mac.
///
/// This is the service layer. It owns orchestration and nothing else:
///
/// ```
/// PocketTTSEngine        this type — chunking, silence trimming, AVFoundation buffers
///   ↓
/// PocketTTSSynthesizer   the autoregressive loop, raw Float frames
///   ↓
/// PocketTTSModelBundle   loaded Core ML models, no knowledge of downloads
///   ↓
/// PocketTTSAssetStore    the only type that touches the network
/// ```
public actor PocketTTSEngine: TTSService {
    public nonisolated var sampleRate: Double { 24_000 }

    /// Below this RMS a frame counts as silence when trimming chunk boundaries.
    private static let silenceFloor: Float = 0.003

    /// Pause inserted between chunks, in 80 ms frames.
    ///
    /// Chunk-boundary silence is trimmed and then replaced with this, so sentence pacing is a
    /// decision here rather than whatever run-up and tail the model happened to generate.
    private static let interChunkPauseFrames = 2

    private let assets: PocketTTSAssetStore
    private var bundle: PocketTTSModelBundle?
    /// Parsed voice caches. One is ~6 MB, so re-reading per utterance would be waste.
    private var voices: [String: PocketTTSVoiceState] = [:]

    public init(assets: PocketTTSAssetStore = .shared) {
        self.assets = assets
    }

    // MARK: - Lifecycle

    /// Download anything missing, then load the models.
    ///
    /// Separate from `init` so callers can show download progress, and idempotent so it is
    /// free to call before every utterance.
    public func prepare(
        onDownloadProgress: (@Sendable (PocketTTSAssetStore.Progress) -> Void)? = nil
    ) async throws {
        guard bundle == nil else { return }
        let paths = try await assets.ensureInstalled(onProgress: onDownloadProgress)
        let started = Date()
        bundle = try PocketTTSModelBundle(paths: paths)
        VoiceAgentLog.ttsInfo(
            "[PocketTTS] loaded models in \(String(format: "%.2f", -started.timeIntervalSinceNow))s"
        )
    }

    /// Release the models, for when the user switches to a cloud provider.
    public func unload() {
        bundle = nil
        voices.removeAll()
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
            text: text, voice: voice,
            referenceAudioURL: referenceAudioURL, referenceText: referenceText
        ) {
            buffers.append(buffer)
        }
        guard let merged = AudioPCM.merge(buffers) else {
            throw VoiceAgentError.ttsFailed("synthesis produced no audio")
        }
        return merged
    }

    /// Stream one buffer per 80 ms frame, so playback starts long before synthesis finishes.
    ///
    /// `referenceAudioURL` and `referenceText` are ignored. Cloning a voice from arbitrary
    /// audio needs the `voice_prompt_phase` model, which this engine does not install; voices
    /// come from ``PocketTTSVoiceCatalog`` instead.
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
                    try await self.generate(text: text, voiceID: voiceID) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Orchestration

    private func generate(
        text: String,
        voiceID: String,
        emit: @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws {
        try await prepare()
        guard let bundle else { throw VoiceAgentError.modelNotLoaded("Pocket TTS") }

        let voice = try await voiceState(for: voiceID)
        let chunks = PocketTTSTextPreparation.splitIntoChunks(text, tokenizer: bundle.tokenizer)
        guard !chunks.isEmpty else { return }

        let synthesizer = PocketTTSSynthesizer(bundle: bundle)

        // Each chunk re-seeds the voice cache, so chunks stay independent and autoregressive
        // drift cannot accumulate across a long passage. The cost is that every chunk carries
        // its own run-up and tail silence, and stitching them raw leaves a dead gap at every
        // sentence boundary — measured at 1.5-1.8 s, which reads as a stall rather than a
        // pause. So each chunk is trimmed at both ends and the pause is reinserted at a fixed
        // length below.
        var isFirstChunk = true
        for chunk in chunks {
            try Task.checkCancellation()
            let prepared = PocketTTSTextPreparation.prepare(chunk)

            // Silence is withheld rather than dropped: a silent frame is only emitted once a
            // later audible frame proves it was an interior pause and not the tail. This keeps
            // streaming intact, so the first word still arrives in tens of milliseconds.
            var sawSpeech = false
            var withheld: [[Float]] = []

            if !isFirstChunk {
                for _ in 0..<Self.interChunkPauseFrames {
                    if let buffer = Self.silentBuffer(sampleRate: 24_000) { emit(buffer) }
                }
            }

            try synthesizer.synthesize(
                text: prepared.text,
                voice: voice,
                framesAfterEndOfSpeech: prepared.framesAfterEOSGuess + 2
            ) { frame in
                guard Self.isAudible(frame.samples) else {
                    // Leading silence is discarded outright; interior silence is held.
                    if sawSpeech { withheld.append(frame.samples) }
                    return
                }
                sawSpeech = true
                for held in withheld {
                    if let buffer = Self.buffer(from: held, sampleRate: 24_000) { emit(buffer) }
                }
                withheld.removeAll(keepingCapacity: true)
                if let buffer = Self.buffer(from: frame.samples, sampleRate: 24_000) {
                    emit(buffer)
                }
            }
            // Anything still withheld is trailing silence. Dropped.
            isFirstChunk = false
        }
    }

    private func voiceState(for voiceID: String) async throws -> PocketTTSVoiceState {
        if let cached = voices[voiceID] { return cached }
        let url = try await assets.voiceFile(for: voiceID)
        do {
            let state = try PocketTTSVoiceState(contentsOf: url)
            voices[voiceID] = state
            return state
        } catch {
            throw VoiceAgentError.ttsFailed("\(error)")
        }
    }

    // MARK: - Audio

    private static func isAudible(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var energy: Float = 0
        for sample in samples { energy += sample * sample }
        return (energy / Float(samples.count)).squareRoot() >= silenceFloor
    }

    /// One frame of digital silence, for the deliberate pause between chunks.
    private static func silentBuffer(sampleRate: Double) -> AVAudioPCMBuffer? {
        buffer(from: [Float](repeating: 0, count: 1920), sampleRate: sampleRate)
    }

    private static func buffer(from samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                  channels: 1, interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let output = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input in
            output.update(from: input.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
