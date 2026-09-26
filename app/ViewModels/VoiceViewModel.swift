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
        let refAudioURL = prefs.voiceReferenceAudioURL
        let refText = prefs.voiceReferenceText.isEmpty ? nil : prefs.voiceReferenceText
        let outputUID = prefs.voiceOutputDeviceUID.isEmpty ? nil : prefs.voiceOutputDeviceUID

        // Build the configured cloud TTS provider. Bail out if not configured.
        guard let built = VoiceProviderFactory.makeTTSProvider() else {
            isSpeaking = false
            return
        }
        let cacheKey = built.cacheKey

        // Reuse the TTS provider if its config is unchanged, otherwise rebuild.
        if standaloneTTSProvider == nil || standaloneTTSKey != cacheKey {
            standaloneTTSProvider = built.provider
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
                        voice: nil,
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
