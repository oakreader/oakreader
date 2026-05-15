import Foundation

/// Errors specific to the voice services.
public enum VoiceAgentError: Error, Sendable, LocalizedError {
    case sttFailed(String)
    case ttsFailed(String)
    case audioCaptureError(String)
    case modelNotLoaded(String)

    public var errorDescription: String? {
        switch self {
        case .sttFailed(let msg): return "Speech-to-text failed: \(msg)"
        case .ttsFailed(let msg): return "Text-to-speech failed: \(msg)"
        case .audioCaptureError(let msg): return "Audio capture error: \(msg)"
        case .modelNotLoaded(let msg): return "Model not loaded: \(msg)"
        }
    }
}
