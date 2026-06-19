import Foundation
import OakAgent

/// Unified data model for `/` slash commands shown in the chat completion panel.
struct ChatCompletionItem: Identifiable, Equatable {

    enum Kind {
        case installedSkill(Skill)
        case libraryReference(LibraryRefPayload)
        /// A generic item that carries its own section title — used by the note
        /// composer to reuse this panel for `/` block commands, `#` tags and `@`
        /// note references (the action is encoded in `id`, handled by the caller).
        case command(section: String)
    }

    struct LibraryRefPayload: Equatable {
        let storageKey: String
        let title: String
        let author: String
        let citeKey: String?
        let contentType: String
        let pageCount: Int
    }

    let id: String
    let icon: String
    let label: String
    let description: String
    let kind: Kind

    /// The trigger character that produced this item (`/`) or empty for drag-dropped items.
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

    // MARK: - Factory - Library Reference (for drag-and-drop)

    /// Builds a library-reference item. `trigger` is `""` for drag-and-drop and
    /// `"@"` when surfaced through the `@`-mention completion panel.
    static func libraryReference(from item: LibraryItem, trigger: String = "") -> ChatCompletionItem {
        let label = item.title
        // Secondary text is the author only — the title is already the label, so
        // repeating it (the old `author — title`) just overflowed the row.
        let desc = item.author
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
                contentType: item.contentType.rawValue,
                pageCount: item.pageCount
            )),
            trigger: trigger
        )
    }

    // MARK: - Helpers

    /// Returns the display string shown in the text field (e.g. `/Summarize` or label for refs).
    var displayText: String {
        trigger.isEmpty ? label : "\(trigger)\(displayLabel)"
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
        case .libraryReference:
            return "Library"
        case .command(let section):
            return section
        }
    }

    /// Build a generic note-composer item (block command / tag / reference). The
    /// action is encoded in `id` (`block:` / `tag:` / `ref:` prefix).
    static func note(id: String, icon: String, label: String, description: String = "",
                     section: String, trigger: String) -> ChatCompletionItem {
        ChatCompletionItem(id: id, icon: icon, label: label, description: description,
                           kind: .command(section: section), trigger: trigger)
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
