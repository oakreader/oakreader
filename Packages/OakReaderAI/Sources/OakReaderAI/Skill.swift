import Foundation

// MARK: - Context Mode

public enum ContextMode: String, Codable, Sendable {
    case currentPage
    case fullDocument
    case selectedText
    case none
}

// MARK: - Skill

public struct Skill: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let systemPrompt: String
    public let icon: String
    public let contextMode: ContextMode

    public init(
        id: String,
        name: String,
        description: String,
        systemPrompt: String,
        icon: String,
        contextMode: ContextMode
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.icon = icon
        self.contextMode = contextMode
    }
}
