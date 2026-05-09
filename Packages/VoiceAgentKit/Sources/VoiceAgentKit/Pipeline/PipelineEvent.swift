import Foundation

/// Latency breakdown for a single voice turn (speech-end → first audio out).
public struct TurnLatencyMetrics: Sendable {
    /// Time from speech-end to STT transcript ready (seconds).
    public let sttLatency: Double
    /// Time from STT complete to first LLM token (seconds).
    public let llmLatency: Double
    /// Time from first LLM token to first TTS audio buffer (seconds).
    public let ttsLatency: Double
    /// Total time from speech-end to first TTS audio buffer (seconds).
    public let totalLatency: Double
}

/// Events emitted by the voice pipeline for UI observation.
public enum PipelineEvent: Sendable {
    case stateChanged(AgentState)
    case userSpeechStarted
    case userSpeechEnded
    case userTranscript(text: String, isFinal: Bool)
    case agentThinking
    case agentResponseText(delta: String)
    case agentResponseComplete(fullText: String)
    case agentSpeechStarted
    case agentSpeechEnded
    case agentInterrupted
    case turnCompleted(VoiceTurn)
    case audioLevel(Float)
    case latencyMetrics(TurnLatencyMetrics)
    case error(VoiceAgentError)
}

/// Errors specific to the voice agent pipeline.
public enum VoiceAgentError: Error, Sendable, LocalizedError {
    case invalidStateTransition(from: AgentState, to: AgentState)
    case sttFailed(String)
    case ttsFailed(String)
    case llmFailed(String)
    case vadFailed(String)
    case audioCaptureError(String)
    case audioPlaybackError(String)
    case pipelineNotRunning
    case modelNotLoaded(String)

    public var errorDescription: String? {
        switch self {
        case .invalidStateTransition(let from, let to):
            return "Invalid state transition from \(from) to \(to)"
        case .sttFailed(let msg): return "Speech-to-text failed: \(msg)"
        case .ttsFailed(let msg): return "Text-to-speech failed: \(msg)"
        case .llmFailed(let msg): return "LLM failed: \(msg)"
        case .vadFailed(let msg): return "Voice activity detection failed: \(msg)"
        case .audioCaptureError(let msg): return "Audio capture error: \(msg)"
        case .audioPlaybackError(let msg): return "Audio playback error: \(msg)"
        case .pipelineNotRunning: return "Voice pipeline is not running"
        case .modelNotLoaded(let msg): return "Model not loaded: \(msg)"
        }
    }
}
