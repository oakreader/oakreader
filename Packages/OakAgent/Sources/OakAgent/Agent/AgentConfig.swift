import Foundation

/// Model-level configuration passed to the provider.
public struct AgentModelConfig: Sendable {
    public let providerId: String
    public let model: String
    public let maxTokens: Int
    public let systemPrompt: String?

    public init(
        providerId: String,
        model: String,
        maxTokens: Int = 4096,
        systemPrompt: String? = nil
    ) {
        self.providerId = providerId
        self.model = model
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
    }
}

/// Agent-level configuration (loop behavior).
public struct AgentConfiguration: Sendable {
    /// Maximum agentic loop iterations before stopping.
    public let maxIterations: Int

    /// Whether to ask for user confirmation before executing a tool.
    public let requireToolConfirmation: Bool

    /// File-based agent skills to advertise in the system prompt.
    public let skills: [AgentSkill]

    public init(
        maxIterations: Int = 10,
        requireToolConfirmation: Bool = false,
        skills: [AgentSkill] = []
    ) {
        self.maxIterations = maxIterations
        self.requireToolConfirmation = requireToolConfirmation
        self.skills = skills
    }

    public static let `default` = AgentConfiguration()
}
