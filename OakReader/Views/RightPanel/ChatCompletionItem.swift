import Foundation
import OakAgent

/// Unified data model for `/` slash commands and `@` context mentions
/// shown in the chat completion panel.
struct ChatCompletionItem: Identifiable, Equatable {

    enum Kind {
        case builtInSkill(Skill)
        case agentSkill(AgentSkill)
        case contextMention(ContextMention)
    }

    enum ContextMention: String, Equatable, CaseIterable {
        case document
        case page
        case selection
        case notes
    }

    let id: String
    let icon: String
    let label: String
    let description: String
    let kind: Kind

    /// The trigger character that produced this item (`/` or `@`).
    let trigger: String

    // MARK: - Equatable

    static func == (lhs: ChatCompletionItem, rhs: ChatCompletionItem) -> Bool {
        lhs.id == rhs.id && lhs.trigger == rhs.trigger
    }

    // MARK: - Factory — Slash Items

    static func slashItems(builtIn: [Skill], agent: [AgentSkill]) -> [ChatCompletionItem] {
        var items: [ChatCompletionItem] = builtIn.map { skill in
            ChatCompletionItem(
                id: "skill:\(skill.id)",
                icon: skill.icon,
                label: skill.name,
                description: skill.description,
                kind: .builtInSkill(skill),
                trigger: "/"
            )
        }
        items += agent.map { skill in
            let iconName: String
            if case .symbol(let name) = skill.icon {
                iconName = name
            } else {
                iconName = "hammer"
            }
            return ChatCompletionItem(
                id: "agent:\(skill.id)",
                icon: iconName,
                label: skill.name,
                description: skill.description,
                kind: .agentSkill(skill),
                trigger: "/"
            )
        }
        return items
    }

    // MARK: - Factory — Mention Items

    static func mentionItems(hasDocument: Bool) -> [ChatCompletionItem] {
        var items: [ChatCompletionItem] = []
        if hasDocument {
            items.append(ChatCompletionItem(
                id: "ctx:document",
                icon: "doc.text",
                label: "Document",
                description: "Full document context",
                kind: .contextMention(.document),
                trigger: "@"
            ))
            items.append(ChatCompletionItem(
                id: "ctx:page",
                icon: "doc",
                label: "Current Page",
                description: "Current page only",
                kind: .contextMention(.page),
                trigger: "@"
            ))
            items.append(ChatCompletionItem(
                id: "ctx:selection",
                icon: "text.cursor",
                label: "Selection",
                description: "Selected text",
                kind: .contextMention(.selection),
                trigger: "@"
            ))
            items.append(ChatCompletionItem(
                id: "ctx:notes",
                icon: "note.text",
                label: "Notes",
                description: "Document notes",
                kind: .contextMention(.notes),
                trigger: "@"
            ))
        }
        return items
    }

    // MARK: - Helpers

    /// Returns the `ContextMode` implied by this item, if it's a context mention.
    var contextMode: ContextMode? {
        guard case .contextMention(let mention) = kind else { return nil }
        switch mention {
        case .document: return .fullDocument
        case .page:     return .currentPage
        case .selection: return .selectedText
        case .notes:    return .fullDocument
        }
    }

    /// Returns the display string shown in the text field (e.g. `/Summarize` or `@Document`).
    var displayText: String {
        "\(trigger)\(label)"
    }

    /// Matches a filter query against label and description (case-insensitive).
    func matches(query: String) -> Bool {
        let q = query.lowercased()
        return label.lowercased().contains(q) || description.lowercased().contains(q)
    }
}
