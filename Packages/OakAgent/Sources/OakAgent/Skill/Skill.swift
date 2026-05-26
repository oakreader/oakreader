import Foundation

// MARK: - Context Mode

public enum ContextMode: String, Codable, Sendable {
    case currentPage
    case fullDocument
    case selectedText
    case none
}

// MARK: - Skill

/// A **user-toggled chat mode preset** — the manual counterpart to ``AgentSkill``.
///
/// The user turns one of these on or off in chat. While active, its full
/// ``systemPrompt`` (the entire `SKILL.md` body, loaded eagerly) is injected and its
/// ``contextMode`` controls what document context is attached. Loaded by
/// ``BuiltInSkillLoader`` into `SkillManager.shared`.
///
/// Contrast with ``AgentSkill``, which the *agent* loads dynamically on demand via the
/// `read` tool (progressive disclosure) rather than the user toggling it. Both are read
/// from the same `SKILL.md` files but serve these two different entry points.
public struct Skill: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let systemPrompt: String
    public let icon: String
    public let contextMode: ContextMode
    public let version: String?
    public let isEnabled: Bool

    public init(
        id: String,
        name: String,
        description: String,
        systemPrompt: String,
        icon: String,
        contextMode: ContextMode,
        version: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.icon = icon
        self.contextMode = contextMode
        self.version = version
        self.isEnabled = isEnabled
    }
}
