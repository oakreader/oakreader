import Foundation
import OakVoice

/// Builds cloud voice (TTS/STT) providers from user preferences.
///
/// Every key comes from the backend's credential store now. ElevenLabs and
/// Fish Audio used to keep theirs in UserDefaults — a plain plist in the user's
/// home — while OpenAI's and Google's sat in a 0600 auth.json. One secret store
/// or the other; having both meant the weaker one decided how safe the keys
/// were.
enum VoiceProviderFactory {
    /// The credential-store id for a voice provider.
    static func credentialId(for type: VoiceProviderType) -> String {
        switch type {
        case .elevenLabs: return "elevenlabs"
        case .fishAudio:  return "fishaudio"
        case .openAI:     return "openai"
        case .gemini:     return "google"
        case .pocketTTS:  return ""   // runs on this Mac; there is no credential
        }
    }

    /// Resolve the API key for a voice provider, or nil if not configured.
    ///
    /// Always nil for an on-device provider, which is why callers must gate on
    /// `type.requiresAPIKey` first rather than treating a missing key as "not configured".
    static func apiKey(for type: VoiceProviderType) -> String? {
        guard type.requiresAPIKey else { return nil }
        return AIProviderCatalog.shared.sharedVoiceKeys[credentialId(for: type)]
    }

    // MARK: - TTS

    /// The configured TTS provider type.
    static var ttsType: VoiceProviderType {
        VoiceProviderType(rawValue: Preferences.shared.voiceTTSProvider) ?? .elevenLabs
    }

    /// Whether the selected TTS provider has everything it needs to run.
    ///
    /// On-device speech is ready once its models are installed; requiring a key here would
    /// reject the one provider that deliberately has none.
    static var isTTSConfigured: Bool {
        let prefs = Preferences.shared
        let type = ttsType
        guard type.requiresAPIKey else { return PocketTTSAssetStore.shared.hasInstalledModels }
        guard apiKey(for: type) != nil else { return false }
        if type == .elevenLabs { return !prefs.elevenLabsVoiceId.isEmpty }
        return true
    }

    /// Build the configured TTS provider plus a cache key capturing the voice
    /// configuration (so cached audio is invalidated when settings change).
    static func makeTTSProvider() -> (provider: any TTSService, cacheKey: String)? {
        let prefs = Preferences.shared
        let type = ttsType

        // The on-device engine takes no key, and its voice is the whole cache key.
        if type == .pocketTTS {
            let voiceId = prefs.pocketTTSVoiceId.isEmpty
                ? PocketTTSVoiceCatalog.defaultVoiceID
                : prefs.pocketTTSVoiceId
            return (PocketTTSEngine(), "pockettts:\(voiceId)")
        }

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
            return (OpenAITTSProvider(apiKey: key, voice: prefs.openAITTSVoice,
                                      endpoint: openAIEndpoint(path: "/audio/speech")),
                    "openai:\(prefs.openAITTSVoice)")
        case .gemini:
            return (GeminiTTSProvider(apiKey: key, voice: prefs.geminiTTSVoice, baseURL: geminiBase()),
                    "gemini:\(prefs.geminiTTSVoice)")
        case .fishAudio:
            return (FishAudioTTSProvider(apiKey: key, referenceId: prefs.fishAudioReferenceId),
                    "fishaudio:\(prefs.fishAudioReferenceId)")
        case .pocketTTS:
            // Handled above, before the key check.
            return nil
        }
    }

    // MARK: - STT

    /// The configured STT provider type.
    ///
    /// Falls back if the stored value names a provider that cannot transcribe, which the
    /// on-device engine cannot; otherwise selecting it for speech would wedge dictation.
    static var sttType: VoiceProviderType {
        let stored = VoiceProviderType(rawValue: Preferences.shared.voiceSTTProvider)
        guard let stored, stored.supportsSpeechToText else { return .elevenLabs }
        return stored
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
        case .openAI: return OpenAISTTProvider(apiKey: key, endpoint: openAIEndpoint(path: "/audio/transcriptions"))
        case .gemini: return GeminiSTTProvider(apiKey: key, baseURL: geminiBase())
        case .fishAudio: return FishAudioSTTProvider(apiKey: key)
        case .pocketTTS:
            // Unreachable: `sttType` rejects providers that cannot transcribe.
            return nil
        }
    }

    // MARK: - Base URL overrides (proxy / relay)

    /// OpenAI voice endpoint built from the resolved base. Falls back to the chat
    /// provider's Endpoint override since OpenAI voice shares its API key.
    private static func openAIEndpoint(path: String) -> URL {
        let base = resolvedBase(voiceId: "openai", chatId: "openai",
                                default: "https://api.openai.com/v1")
        return URL(string: base + path) ?? URL(string: "https://api.openai.com/v1" + path)!
    }

    /// Gemini API base host (explicit voice override or default — no chat fallback,
    /// since the Gemini chat endpoint uses a different URL shape).
    private static func geminiBase() -> String {
        resolvedBase(voiceId: "gemini", chatId: nil,
                     default: "https://generativelanguage.googleapis.com/v1beta")
    }

    private static func resolvedBase(voiceId: String, chatId: String?, default def: String) -> String {
        let prefs = Preferences.shared
        let explicit = prefs.voiceBaseURL(forProvider: voiceId).trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return normalizeBase(explicit) }
        if let chatId {
            let chat = (AIProviderCatalog.shared.provider(for: chatId)?.baseUrlOverride ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chat.isEmpty { return normalizeBase(chat) }
        }
        return def
    }

    private static func normalizeBase(_ s: String) -> String {
        var v = s
        if v.hasSuffix("#") { v.removeLast() }   // chat "use exactly as typed" marker
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }
}
