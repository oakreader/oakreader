import Foundation

/// How much of the open document a skill wants attached.
///
/// Declared by a skill's `context-mode` frontmatter and applied here, because
/// the document is the shell's — the core knows a skill asked for the whole
/// thing, but only this side can produce it.
enum ContextMode: String, Codable, Sendable {
    case currentPage
    case fullDocument
    case selectedText
    case none
}
