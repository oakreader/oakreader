import AVFoundation
import Foundation
import OakVoice

@Observable
class VoiceViewModel {
    /// Whether standalone TTS playback is active.
    var isSpeaking: Bool = false

    // MARK: - Standalone TTS state
    private var standaloneTTSProvider: (any TTSService)?
    private var standaloneTTSKey: String? // cache key to avoid re-creating
    private var speakerOutput: SpeakerOutput?
    private var ttsPlaybackTask: Task<Void, Never>?

    // MARK: - Standalone TTS Playback

    @MainActor
    func speakText(_ text: String) {
        stopSpeaking()
        isSpeaking = true

        let prefs = Preferences.shared
        let voice = prefs.voiceTTSVoice.isEmpty ? nil : prefs.voiceTTSVoice
        let refAudioURL = prefs.voiceReferenceAudioURL
        let refText = prefs.voiceReferenceText.isEmpty ? nil : prefs.voiceReferenceText
        let outputUID = prefs.voiceOutputDeviceUID.isEmpty ? nil : prefs.voiceOutputDeviceUID

        // TTS is cloud-only (ElevenLabs). Bail out if it isn't configured.
        guard !prefs.elevenLabsAPIKey.isEmpty, !prefs.elevenLabsVoiceId.isEmpty else {
            isSpeaking = false
            return
        }

        // Build a cache key that includes all voice config that affects audio output
        let cacheKey = "elevenlabs:\(prefs.elevenLabsVoiceId):\(prefs.elevenLabsTTSModelId)"

        // Reuse TTS provider if same config, otherwise create new one
        if standaloneTTSProvider == nil || standaloneTTSKey != cacheKey {
            let ttsConfig = ElevenLabsTTSConfig(
                apiKey: prefs.elevenLabsAPIKey,
                voiceId: prefs.elevenLabsVoiceId,
                modelId: prefs.elevenLabsTTSModelId
            )
            standaloneTTSProvider = ElevenLabsTTSProvider(config: ttsConfig)
            standaloneTTSKey = cacheKey
        }

        let provider = standaloneTTSProvider!
        let speaker = SpeakerOutput(deviceUID: outputUID)
        speakerOutput = speaker

        ttsPlaybackTask = Task { [weak self] in
            do {
                // Check audio cache first
                if let cachedStream = await TTSAudioCache.shared.loadStream(text: text, configKey: cacheKey) {
                    Log.debug(Log.voice, "TTS cache hit: \(text.prefix(50))")
                    try await speaker.play(buffers: cachedStream)
                } else {
                    // Cache miss: synthesize while collecting buffers for caching
                    let sourceStream = provider.synthesizeStream(
                        text: text,
                        voice: voice,
                        referenceAudioURL: refAudioURL,
                        referenceText: refText
                    )
                    let collector = TTSBufferCollector()
                    let cachingStream = AsyncThrowingStream<AVAudioPCMBuffer, Error> { continuation in
                        Task {
                            do {
                                for try await buffer in sourceStream {
                                    await collector.append(buffer)
                                    continuation.yield(buffer)
                                }
                                continuation.finish()
                            } catch {
                                continuation.finish(throwing: error)
                            }
                        }
                    }
                    try await speaker.play(buffers: cachingStream)
                    // Persist to cache after successful playback
                    let buffers = await collector.buffers
                    if !buffers.isEmpty {
                        await TTSAudioCache.shared.store(buffers: buffers, text: text, configKey: cacheKey)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    Log.error(Log.voice, "TTS playback failed: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self?.isSpeaking = false
                self?.speakerOutput = nil
            }
        }

        // Periodically clean expired cache entries
        Task { await TTSAudioCache.shared.cleanExpired() }
    }

    @MainActor
    func stopSpeaking() {
        ttsPlaybackTask?.cancel()
        ttsPlaybackTask = nil
        speakerOutput?.stop()
        speakerOutput = nil
        isSpeaking = false
    }
}
