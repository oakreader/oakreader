import Foundation

// MARK: - Voice Provider Type

/// Which provider backs a voice pipeline component (TTS or STT).
///
/// Most cases are cloud services needing an API key. ``pocketTTS`` is the exception: it runs
/// Kyutai's Pocket TTS on this Mac, needs no key, and does text-to-speech only. Check
/// ``supportsTextToSpeech`` and ``supportsSpeechToText`` before offering a case in a picker
/// rather than iterating `allCases` directly.
public enum VoiceProviderType: String, Sendable, Codable, CaseIterable {
    case elevenLabs = "elevenlabs"
    case openAI = "openai"
    case gemini = "gemini"
    case fishAudio = "fishaudio"
    /// On-device Kyutai Pocket TTS. The only provider that needs no API key.
    case pocketTTS = "pockettts"

    public var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .fishAudio: return "Fish Audio"
        case .pocketTTS: return "On-device (Pocket TTS)"
        }
    }

    public var supportsTextToSpeech: Bool { true }

    /// Pocket TTS synthesizes only; transcription stays with the cloud providers.
    public var supportsSpeechToText: Bool { self != .pocketTTS }

    /// Whether the provider needs an API key before it can run.
    ///
    /// Drives the configuration gate: a provider that needs no key is ready as soon as its
    /// models are installed, so the key check must not be applied to it.
    public var requiresAPIKey: Bool { self != .pocketTTS }

    /// Whether synthesis happens on this Mac, with no audio leaving the device.
    public var isOnDevice: Bool { self == .pocketTTS }

    /// Cases offerable as a text-to-speech provider.
    public static var textToSpeechProviders: [VoiceProviderType] {
        allCases.filter(\.supportsTextToSpeech)
    }

    /// Cases offerable as a speech-to-text provider.
    public static var speechToTextProviders: [VoiceProviderType] {
        allCases.filter(\.supportsSpeechToText)
    }
}
