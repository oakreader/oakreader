import Foundation

// MARK: - Voice Provider Type

/// Which cloud provider backs a voice pipeline component (TTS or STT).
///
/// On-device (MLX) voice was removed; OakReader now relies exclusively on
/// cloud providers. Additional providers (Fish Audio, Gemini, OpenAI) are
/// added here as they are wired in.
public enum VoiceProviderType: String, Sendable, Codable, CaseIterable {
    case elevenLabs = "elevenlabs"

    public var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        }
    }
}
