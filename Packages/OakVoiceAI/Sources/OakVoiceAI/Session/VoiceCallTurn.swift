import Foundation

/// Codable persistence model for a single voice call turn, written as JSONL.
/// Maps closely to `VoiceTurn` but adds persistence-specific fields
/// (turn index, audio availability flags, interruption status).
public struct VoiceCallTurn: Codable, Identifiable, Sendable {
    public let id: UUID
    public let turnIndex: Int
    public let userText: String
    public let assistantText: String
    public let startedAt: Date
    public let completedAt: Date
    public let hasUserAudio: Bool
    public let hasAgentAudio: Bool
    public let wasInterrupted: Bool

    public init(
        id: UUID = UUID(),
        turnIndex: Int,
        userText: String,
        assistantText: String,
        startedAt: Date,
        completedAt: Date,
        hasUserAudio: Bool = false,
        hasAgentAudio: Bool = false,
        wasInterrupted: Bool = false
    ) {
        self.id = id
        self.turnIndex = turnIndex
        self.userText = userText
        self.assistantText = assistantText
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.hasUserAudio = hasUserAudio
        self.hasAgentAudio = hasAgentAudio
        self.wasInterrupted = wasInterrupted
    }

    /// Create from an in-memory `VoiceTurn` with additional persistence metadata.
    public init(
        turn: VoiceTurn,
        turnIndex: Int,
        hasUserAudio: Bool = false,
        hasAgentAudio: Bool = false,
        wasInterrupted: Bool = false
    ) {
        self.id = turn.id
        self.turnIndex = turnIndex
        self.userText = turn.userText
        self.assistantText = turn.assistantText
        self.startedAt = turn.startedAt
        self.completedAt = turn.completedAt
        self.hasUserAudio = hasUserAudio
        self.hasAgentAudio = hasAgentAudio
        self.wasInterrupted = wasInterrupted
    }
}
