import OakAgent
import OakVoice

/// Builds cloud voice (TTS/STT) providers from user preferences, resolving API
/// keys from the shared credential store where the provider doubles as a chat
/// provider (OpenAI, Gemini) and from Preferences otherwise (ElevenLabs, Fish).
enum VoiceProviderFactory {
    /// Resolve the API key for a voice provider, or nil if not configured.
    static func apiKey(for type: VoiceProviderType) -> String? {
        let prefs = Preferences.shared
        switch type {
        case .elevenLabs:
            return prefs.elevenLabsAPIKey.isEmpty ? nil : prefs.elevenLabsAPIKey
        case .fishAudio:
            return prefs.fishAudioAPIKey.isEmpty ? nil : prefs.fishAudioAPIKey
        case .openAI:
            return CredentialResolver.resolve(for: "openai")
        case .gemini:
            return CredentialResolver.resolve(for: "google")
        }
    }

    // MARK: - TTS

    /// The configured TTS provider type.
    static var ttsType: VoiceProviderType {
        VoiceProviderType(rawValue: Preferences.shared.voiceTTSProvider) ?? .elevenLabs
    }

    /// Whether the selected TTS provider has everything it needs to run.
    static var isTTSConfigured: Bool {
        let prefs = Preferences.shared
        guard apiKey(for: ttsType) != nil else { return false }
        if ttsType == .elevenLabs { return !prefs.elevenLabsVoiceId.isEmpty }
        return true
    }

    /// Build the configured TTS provider plus a cache key capturing the voice
    /// configuration (so cached audio is invalidated when settings change).
    static func makeTTSProvider() -> (provider: any TTSService, cacheKey: String)? {
        let prefs = Preferences.shared
        let type = ttsType
        guard let key = apiKey(for: type) else { return nil }

        switch type {
        case .elevenLabs:
            guard !prefs.elevenLabsVoiceId.isEmpty else { return nil }
            let provider = ElevenLabsTTSProvider(config: ElevenLabsTTSConfig(
                apiKey: key,
                voiceId: prefs.elevenLabsVoiceId,
                modelId: prefs.elevenLabsTTSModelId
            ))
            return (provider, "elevenlabs:\(prefs.elevenLabsVoiceId):\(prefs.elevenLabsTTSModelId)")
        case .openAI:
            return (OpenAITTSProvider(apiKey: key, voice: prefs.openAITTSVoice),
                    "openai:\(prefs.openAITTSVoice)")
        case .gemini:
            return (GeminiTTSProvider(apiKey: key, voice: prefs.geminiTTSVoice),
                    "gemini:\(prefs.geminiTTSVoice)")
        case .fishAudio:
            return (FishAudioTTSProvider(apiKey: key, referenceId: prefs.fishAudioReferenceId),
                    "fishaudio:\(prefs.fishAudioReferenceId)")
        }
    }

    // MARK: - STT

    /// The configured STT provider type.
    static var sttType: VoiceProviderType {
        VoiceProviderType(rawValue: Preferences.shared.voiceSTTProvider) ?? .elevenLabs
    }

    /// Whether the selected STT provider has an API key configured.
    static var isSTTConfigured: Bool {
        apiKey(for: sttType) != nil
    }

    /// Build the configured STT provider, or nil if not configured.
    static func makeSTTProvider() -> (any STTService)? {
        let type = sttType
        guard let key = apiKey(for: type) else { return nil }
        switch type {
        case .elevenLabs: return ElevenLabsSTTProvider(apiKey: key)
        case .openAI: return OpenAISTTProvider(apiKey: key)
        case .gemini: return GeminiSTTProvider(apiKey: key)
        case .fishAudio: return FishAudioSTTProvider(apiKey: key)
        }
    }
}
