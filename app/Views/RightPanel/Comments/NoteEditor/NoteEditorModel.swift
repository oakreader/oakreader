import AppKit

// MARK: - Custom attribute keys

extension NSAttributedString.Key {
    /// Marks an inline-code run (so serialization emits `` `…` `` and styling
    /// applies the mono look). A bool flag.
    static let oakInlineCode = NSAttributedString.Key("oakInlineCode")
    /// Marks a `#tag` run (value: the tag name without `#`).
    static let oakTag = NSAttributedString.Key("oakTag")
    /// Paragraph-level block kind (value: `NoteBlock.rawValue`). Applied across a
    /// whole paragraph so serialization can re-emit the right prefix/fence.
    static let oakBlock = NSAttributedString.Key("oakBlock")
    /// A list-item marker run (`•  ` / `1.  `) drawn as real text but skipped on
    /// serialization — `NSTextList` markers don't render in a plain TextKit-2
    /// NSTextView, so we render the marker ourselves and strip it when saving.
    static let oakListMarker = NSAttributedString.Key("oakListMarker")
    /// A live-rendered inline math run. The raw `$…$` source stays in the buffer
    /// (so it round-trips to Markdown and edits naturally); the value is the LaTeX
    /// with delimiters stripped. When the caret is OUTSIDE the run the source
    /// glyphs are hidden (tiny clear font) and `oakMathImage` draws the formula;
    /// when the caret is INSIDE, the raw source is shown for editing.
    static let oakMath = NSAttributedString.Key("oakMath")
    /// Carried by the FIRST character of a collapsed math run; value is the
    /// `NSImage` the layout manager draws in the reserved (kerned) width.
    static let oakMathImage = NSAttributedString.Key("oakMathImage")
}

// MARK: - Block model

/// Paragraph-level block types the editor round-trips with Markdown.
enum NoteBlock: Int {
    case paragraph = 0, h1, h2, h3, bullet, ordered, quote, code
}

// MARK: - Font trait helpers

/// Bold/italic trait toggling, shared by the Markdown codec (parse/serialize) and
/// the text view (toolbar commands + active-format probing). `internal` so both
/// files can reach it.
extension NSFont {
    func withToggledTrait(_ trait: NSFontDescriptor.SymbolicTraits, on: Bool) -> NSFont {
        var traits = fontDescriptor.symbolicTraits
        if on { traits.insert(trait) } else { traits.remove(trait) }
        let desc = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: pointSize) ?? self
    }
    var hasBold: Bool { fontDescriptor.symbolicTraits.contains(.bold) }
    var hasItalic: Bool { fontDescriptor.symbolicTraits.contains(.italic) }
}
