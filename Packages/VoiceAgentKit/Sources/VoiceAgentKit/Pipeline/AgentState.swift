import Foundation

/// State machine for the voice agent pipeline.
///
/// Valid transitions:
/// ```
/// idle → listening → userSpeaking → thinking → speaking → listening (loop)
///                                                       ↘ interrupted → thinking
/// ```
public enum AgentState: String, Sendable {
    case idle
    case listening
    case userSpeaking
    case thinking
    case speaking
    case interrupted

    /// Returns whether a transition from the current state to the given state is valid.
    public func canTransition(to newState: AgentState) -> Bool {
        switch (self, newState) {
        case (.idle, .listening):
            return true
        case (.listening, .userSpeaking):
            return true
        case (.listening, .idle):
            return true
        case (.userSpeaking, .thinking):
            return true
        case (.thinking, .speaking):
            return true
        case (.speaking, .listening):
            return true
        case (.speaking, .interrupted):
            return true
        case (.interrupted, .thinking):
            return true
        // Allow stopping from any state
        case (_, .idle):
            return true
        default:
            return false
        }
    }
}
