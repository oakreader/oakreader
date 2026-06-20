import AppKit

// MARK: - Styling constants

enum NoteEditorStyle {
    static let baseFont = NSFont.systemFont(ofSize: 14)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static var accent: NSColor { .controlAccentColor }
    /// Inline `` `code` `` run background (matches the card's `inlineCodeBackground`).
    static var codeBackground: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.12) }
    /// Fenced code-block surface — fill + hairline border, mirroring the note card's
    /// `CodeBlockView` (`MarkdownTheme.codeBlockBackground` / `.codeBlockBorder`) so the
    /// editor preview reads like the saved block instead of a tight grey strip.
    static var codeBlockBackground: NSColor { NSColor.textColor.withAlphaComponent(0.05) }
    static var codeBlockBorder: NSColor { .separatorColor }
    // Match the card's `NoteTagChip`: neutral grey, NOT accent — secondary text on
    // a light grey fill (a chip-like token, kept consistent editor ↔ review).
    static var tagForeground: NSColor { .secondaryLabelColor }
    static var tagBackground: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.12) }
    /// A faint rounded fill behind a blockquote paragraph. Matches the note card's
    /// `MarkdownTheme.blockquoteBackground` so the editor preview and the saved card
    /// read identically (fill-only, no left bar — see `NoteTagLayoutManager`).
    static var quoteBackground: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.06) }

    static func headingFont(_ block: NoteBlock) -> NSFont {
        switch block {
        case .h1: return .systemFont(ofSize: 20, weight: .semibold)
        case .h2: return .systemFont(ofSize: 17, weight: .semibold)
        default:  return .systemFont(ofSize: 15, weight: .semibold)
        }
    }

    static func paragraphStyle(_ block: NoteBlock) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.3
        p.paragraphSpacing = 6
        switch block {
        case .bullet, .ordered:
            // Hanging indent so wrapped lines align past the marker text we render.
            p.headIndent = 22; p.firstLineHeadIndent = 0
        case .quote:
            // 12pt matches the note card's blockquote indent (MarkdownAttributedBuilder
            // `bodyParagraphStyle(headIndent: 12)`) so editor and rendered card align.
            p.headIndent = 12; p.firstLineHeadIndent = 12
        case .code:
            p.headIndent = 8; p.firstLineHeadIndent = 8
        default:
            break
        }
        return p
    }

    /// A list-item marker run (`•  ` / `1.  `) — real text, but tagged so it's
    /// skipped on serialization and re-derived from the block kind.
    static func listMarker(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: baseFont, .foregroundColor: NSColor.secondaryLabelColor, .oakListMarker: true,
        ])
    }

    /// Apply a block's paragraph attributes over `range` of a mutable string.
    static func applyBlock(_ block: NoteBlock, to ts: NSMutableAttributedString, range: NSRange) {
        guard range.length >= 0 else { return }
        ts.addAttribute(.oakBlock, value: block.rawValue, range: range)
        ts.addAttribute(.paragraphStyle, value: paragraphStyle(block), range: range)
        switch block {
        case .h1, .h2, .h3:
            ts.addAttribute(.font, value: headingFont(block), range: range)
        case .code:
            ts.addAttribute(.font, value: monoFont, range: range)
            // Background is drawn continuously by NoteTagLayoutManager (a per-glyph
            // .backgroundColor renders as striped, gappy per-line rects).
        case .quote:
            ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        default:
            break
        }
    }
}
