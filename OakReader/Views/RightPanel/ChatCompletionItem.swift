import Foundation
import OakAgent

/// Unified data model for `/` slash commands and `@` context mentions
/// shown in the chat completion panel.
struct ChatCompletionItem: Identifiable, Equatable {

    enum Kind {
        case installedSkill(Skill)
        case contextMention(ContextMention)
        case libraryReference(LibraryRefPayload)
        case noteReference(NoteRefPayload)
    }

    struct LibraryRefPayload: Equatable {
        let storageKey: String
        let title: String
        let author: String
        let citeKey: String?
        let itemType: String
        let pageCount: Int
    }

    struct NoteRefPayload: Equatable {
        let noteId: UUID
        let title: String
        let path: String
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

    // MARK: - Factory - Slash Items

    static func slashItems(installed: [Skill]) -> [ChatCompletionItem] {
        installed.map { skill in
            ChatCompletionItem(
                id: "skill:\(skill.id)",
                icon: skill.icon,
                label: skill.name,
                description: skill.description,
                kind: .installedSkill(skill),
                trigger: "/"
            )
        }
    }

    // MARK: - Factory - Mention Items

    static func mentionItems(
        hasDocument: Bool
    ) -> [ChatCompletionItem] {
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

    // MARK: - Factory - Library Items

    static func libraryItems(from items: [LibraryItem]) -> [ChatCompletionItem] {
        items.map { item in
            let label = item.citeKey ?? item.title
            let desc = item.author.isEmpty ? item.title : "\(item.author) — \(item.title)"
            return ChatCompletionItem(
                id: "lib:\(item.storageKey)",
                icon: item.displayIcon,
                label: label,
                description: desc,
                kind: .libraryReference(LibraryRefPayload(
                    storageKey: item.storageKey,
                    title: item.title,
                    author: item.author,
                    citeKey: item.citeKey,
                    itemType: item.itemType.rawValue,
                    pageCount: item.pageCount
                )),
                trigger: "@"
            )
        }
    }

    // MARK: - Factory - Note Items

    static func noteItems(from notes: [Note], database: CatalogDatabase) -> [ChatCompletionItem] {
        notes.map { note in
            let path = CatalogDatabase.noteFileURL(noteId: note.id).path
            return ChatCompletionItem(
                id: "note:\(note.id.uuidString)",
                icon: "note.text",
                label: note.displayTitle,
                description: "Note",
                kind: .noteReference(NoteRefPayload(
                    noteId: note.id,
                    title: note.displayTitle,
                    path: path
                )),
                trigger: "@"
            )
        }
    }

    // MARK: - Helpers

    /// Whether this item should only appear when the user has typed a non-empty query.
    /// Library and note items are hidden on empty `@` to avoid flooding the panel.
    var requiresQuery: Bool {
        switch kind {
        case .libraryReference, .noteReference: return true
        default: return false
        }
    }

    /// Returns the `ContextMode` implied by this item, if it's a context mention.
    var contextMode: ContextMode? {
        switch kind {
        case .contextMention(let mention):
            switch mention {
            case .document: return .fullDocument
            case .page:     return .currentPage
            case .selection: return .selectedText
            case .notes:    return .fullDocument
            }
        case .libraryReference, .noteReference:
            return nil
        case .installedSkill:
            return nil
        }
    }

    /// Returns the display string shown in the text field (e.g. `/Summarize` or `@Document`).
    var displayText: String {
        "\(trigger)\(displayLabel)"
    }

    /// Returns the label shown inside the popup row without the trigger glyph.
    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(trigger) else { return trimmed }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Section label used by the completion popup.
    var sectionTitle: String {
        switch kind {
        case .installedSkill:
            return "Skills"
        case .contextMention:
            return "Context"
        case .libraryReference:
            return "Library"
        case .noteReference:
            return "Notes"
        }
    }

    /// Matches a filter query against label and description (case-insensitive).
    func matches(query: String) -> Bool {
        let q = query.lowercased()
        return displayText.lowercased().contains(q)
            || displayLabel.lowercased().contains(q)
            || label.lowercased().contains(q)
            || description.lowercased().contains(q)
    }
}

