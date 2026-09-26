import Foundation

// MARK: - Voice Provider Type

/// Which cloud provider backs a voice pipeline component (TTS or STT).
///
/// On-device (MLX) voice was removed; OakReader relies exclusively on cloud
/// providers. Every case supports both text-to-speech and speech-to-text.
public enum VoiceProviderType: String, Sendable, Codable, CaseIterable {
    case elevenLabs = "elevenlabs"
    case openAI = "openai"
    case gemini = "gemini"
    case fishAudio = "fishaudio"

    public var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .fishAudio: return "Fish Audio"
        }
    }
}
