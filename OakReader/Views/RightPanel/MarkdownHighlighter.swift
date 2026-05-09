import AppKit
import Highlightr

/// Regex-based markdown syntax highlighter for NSTextView.
/// Colors and typography inspired by MiaoYan.
/// Uses Highlightr for language-aware code block highlighting.
final class MarkdownHighlighter: NSObject, NSTextStorageDelegate {
    var baseFont: NSFont
    var lineHeight: CGFloat
    var lineSpacing: CGFloat
    var letterSpacing: CGFloat

    private var codeFont: NSFont { resolveCodeFont() }

    /// Cached Highlightr instance (MiaoYan pattern: lazy + theme-cached).
    private static var highlightr: Highlightr?
    private static var cachedTheme: String?

    // swiftlint:disable force_try
    private static let headingRegex = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)$"#, options: .anchorsMatchLines)
    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let italicRegex = try! NSRegularExpression(
        pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#
    )
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+?)`"#)
    private static let unorderedListRegex = try! NSRegularExpression(pattern: #"^(\s*[-*+])\s"#, options: .anchorsMatchLines)
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"^(\s*\d+\.)\s"#, options: .anchorsMatchLines)
    private static let blockquoteRegex = try! NSRegularExpression(pattern: #"^>.*$"#, options: .anchorsMatchLines)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[.+?\]\(.+?\)"#)
    private static let fenceRegex = try! NSRegularExpression(pattern: #"^(`{3,}|~{3,})(\w*)\s*$"#, options: .anchorsMatchLines)
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"(?<=\s|^)#[a-zA-Z\u4e00-\u9fff][a-zA-Z0-9\u4e00-\u9fff_/-]*"#,
        options: .anchorsMatchLines
    )
    private static let referenceRegex = try! NSRegularExpression(pattern: #"\[\[.+?\]\]"#)
    private static let hrRegex = try! NSRegularExpression(pattern: #"^([-*_]){3,}\s*$"#, options: .anchorsMatchLines)
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[.*?\]\(.+?\)"#)
    private static let strikethroughRegex = try! NSRegularExpression(pattern: #"~~(.+?)~~"#)
    private static let taskListRegex = try! NSRegularExpression(pattern: #"^(\s*-\s\[[ x]\])\s"#, options: .anchorsMatchLines)
    private static let autolinkRegex = try! NSRegularExpression(pattern: #"(?:https?://|www\.)\S+"#)
    private static let htmlTagRegex = try! NSRegularExpression(pattern: #"<(\S+)[^>]*>.*?</\1>|<(img|br|hr|input)[^>]*/?\s*>"#)
    // swiftlint:enable force_try

    // Headings: color-only, no font size change (MiaoYan keeps the same font)

    /// Single configurable accent color for all markdown syntax elements.
    var accentColor: NSColor = NSColor(hex: Preferences.shared.noteEditorAccentColor)
        ?? NSColor(srgbRed: 0.02, green: 0.65, blue: 0.60, alpha: 1.0)
    private static let codeTextColor = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.80, green: 0.80, blue: 0.80, alpha: 1.0)
            : NSColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0)
    }
    private static let inlineCodeBg = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.16, green: 0.18, blue: 0.20, alpha: 1.0)
            : NSColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1.0)
    }

    /// When set, `applyAttributes` skips any range that overlaps with this range
    /// to prevent destroying diff styling applied by the text view.
    var activeDiffRange: NSRange?

    private var isHighlighting = false

    init(baseFont: NSFont, lineHeight: CGFloat = 1.3, lineSpacing: CGFloat = 3.0, letterSpacing: CGFloat = 0.5) {
        self.baseFont = baseFont
        self.lineHeight = lineHeight
        self.lineSpacing = lineSpacing
        self.letterSpacing = letterSpacing
        super.init()
    }

    // MARK: - Highlightr (MiaoYan pattern: lazy cached)

    private func getHighlighter() -> Highlightr? {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        let theme = isDark ? "tomorrow-night-blue" : "atom-one-light"

        if let hl = Self.highlightr, Self.cachedTheme == theme {
            return hl
        }
        if let hl = Self.highlightr {
            hl.setTheme(to: theme)
            Self.cachedTheme = theme
            return hl
        }
        guard let hl = Highlightr() else { return nil }
        hl.setTheme(to: theme)
        hl.ignoreIllegals = true
        Self.highlightr = hl
        Self.cachedTheme = theme
        return hl
    }

    // MARK: - NSTextStorageDelegate

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isHighlighting else { return }
        let ns = textStorage.string as NSString
        guard ns.length > 0 else { return }

        isHighlighting = true
        applyAttributes(ns.lineRange(for: editedRange), in: textStorage)
        isHighlighting = false
    }

    func highlightAll(in textStorage: NSTextStorage) {
        let len = (textStorage.string as NSString).length
        guard len > 0 else { return }
        isHighlighting = true
        textStorage.beginEditing()
        applyAttributes(NSRange(location: 0, length: len), in: textStorage)
        textStorage.endEditing()
        isHighlighting = false
    }

    // MARK: - Core

    private func applyAttributes(_ range: NSRange, in ts: NSTextStorage) {
        let total = (ts.string as NSString).length
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: total))
        guard safe.length > 0 else { return }

        // Skip ranges that overlap with the active diff to preserve diff styling
        if let diffRange = activeDiffRange {
            let overlap = NSIntersectionRange(safe, diffRange)
            if overlap.length > 0 {
                // Apply only to non-overlapping portions
                let beforeEnd = diffRange.location
                let afterStart = NSMaxRange(diffRange)
                if safe.location < beforeEnd {
                    let beforeRange = NSRange(location: safe.location, length: beforeEnd - safe.location)
                    applyAttributesUnchecked(beforeRange, in: ts)
                }
                if NSMaxRange(safe) > afterStart {
                    let afterRange = NSRange(location: afterStart, length: NSMaxRange(safe) - afterStart)
                    applyAttributesUnchecked(afterRange, in: ts)
                }
                return
            }
        }

        applyAttributesUnchecked(safe, in: ts)
    }

    private func applyAttributesUnchecked(_ safe: NSRange, in ts: NSTextStorage) {
        guard safe.length > 0 else { return }

        let ps = MarkdownTextView.paragraphStyle(font: baseFont, lineHeight: lineHeight, lineSpacing: lineSpacing)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: ps,
            .kern: letterSpacing,
            .backgroundColor: NSColor.clear,
            .strikethroughStyle: 0,
        ]
        ts.setAttributes(baseAttrs, range: safe)

        // Fenced code blocks (scan full doc, apply within range)
        scanFencedCodeBlocks(in: ts)
        applyFencedCodeBlocks(in: ts, range: safe)

        // Inline markdown
        applyHeadings(in: ts, range: safe)
        applyBold(in: ts, range: safe)
        applyItalic(in: ts, range: safe)
        applyStrikethrough(in: ts, range: safe)
        applyInlineCode(in: ts, range: safe)
        applyLists(in: ts, range: safe)
        applyBlockquotes(in: ts, range: safe)
        applyLinks(in: ts, range: safe)
        applyImages(in: ts, range: safe)
        applyHorizontalRules(in: ts, range: safe)
        applyTags(in: ts, range: safe)
        applyReferences(in: ts, range: safe)
        applyTaskLists(in: ts, range: safe)
        applyAutolinks(in: ts, range: safe)
        applyHTMLTags(in: ts, range: safe)
    }

    // MARK: - Headings

    private func applyHeadings(in ts: NSTextStorage, range: NSRange) {
        Self.headingRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match else { return }
            let hashRange = match.range(at: 1)
            ts.addAttribute(.foregroundColor, value: self.accentColor, range: match.range)
            ts.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: hashRange)
        }
    }

    // MARK: - Bold

    private func applyBold(in ts: NSTextStorage, range: NSRange) {
        Self.boldRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match, !isInsideFence(match.range) else { return }
            let cur = ts.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont ?? baseFont
            ts.addAttribute(.font, value: NSFontManager.shared.convert(cur, toHaveTrait: .boldFontMask), range: match.range)
            let openRange = NSRange(location: match.range.location, length: 2)
            let closeRange = NSRange(location: NSMaxRange(match.range) - 2, length: 2)
            ts.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: openRange)
            ts.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: closeRange)
            // Shift * down — the glyph sits near cap-height, not baseline
            let offset = -cur.pointSize * 0.18
            ts.addAttribute(.baselineOffset, value: offset, range: openRange)
            ts.addAttribute(.baselineOffset, value: offset, range: closeRange)
        }
    }

    // MARK: - Italic

    private func applyItalic(in ts: NSTextStorage, range: NSRange) {
        Self.italicRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match, !isInsideFence(match.range) else { return }
            let cur = ts.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont ?? baseFont
            ts.addAttribute(.font, value: NSFontManager.shared.convert(cur, toHaveTrait: .italicFontMask), range: match.range)
            ts.addAttribute(.foregroundColor, value: self.accentColor, range: match.range)
            let openRange = NSRange(location: match.range.location, length: 1)
            let closeRange = NSRange(location: NSMaxRange(match.range) - 1, length: 1)
            ts.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: openRange)
            ts.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: closeRange)
            let offset = -cur.pointSize * 0.18
            ts.addAttribute(.baselineOffset, value: offset, range: openRange)
            ts.addAttribute(.baselineOffset, value: offset, range: closeRange)
        }
    }

    // MARK: - Strikethrough

    private func applyStrikethrough(in ts: NSTextStorage, range: NSRange) {
        Self.strikethroughRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match, !isInsideFence(match.range) else { return }
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }
    }

    // MARK: - Inline Code (pill style)

    private func applyInlineCode(in ts: NSTextStorage, range: NSRange) {
        Self.inlineCodeRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match, !isInsideFence(match.range) else { return }
            ts.addAttribute(.font, value: codeFont, range: match.range)
            ts.addAttribute(.foregroundColor, value: Self.codeTextColor, range: match.range)
            ts.addAttribute(.backgroundColor, value: Self.inlineCodeBg, range: match.range)
        }
    }

    // MARK: - Lists

    private func applyLists(in ts: NSTextStorage, range: NSRange) {
        let apply: (NSTextCheckingResult?, NSRegularExpression.MatchingFlags, UnsafeMutablePointer<ObjCBool>) -> Void = { match, _, _ in
            guard let match else { return }
            ts.addAttribute(.foregroundColor, value: self.accentColor, range: match.range(at: 1))
        }
        Self.unorderedListRegex.enumerateMatches(in: ts.string, range: range, using: apply)
        Self.orderedListRegex.enumerateMatches(in: ts.string, range: range, using: apply)
    }

    // MARK: - Blockquotes

    private func applyBlockquotes(in ts: NSTextStorage, range: NSRange) {
        Self.blockquoteRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match else { return }
            ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }
    }

    // MARK: - Links

    private func applyLinks(in ts: NSTextStorage, range: NSRange) {
        Self.linkRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match, !isInsideFence(match.range) else { return }
            ts.addAttribute(.foregroundColor, value: self.accentColor, range: match.range)
        }
    }

    // MARK: - Images

    private func applyImages(in ts: NSTextStorage, range: NSRange) {
        Self.imageRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match, !isInsideFence(match.range) else { return }
            ts.addAttribute(.foregroundColor, value: self.accentColor, range: match.range)
        }
    }

    // MARK: - Horizontal Rules

    private func applyHorizontalRules(in ts: NSTextStorage, range: NSRange) {
        Self.hrRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match else { return }
            ts.addAttribute(.foregroundColor, value: NSColor.separatorColor, range: match.range)
        }
    }

    // MARK: - #Tags

    private func applyTags(in ts: NSTextStorage, range: NSRange) {
        Self.tagRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match, !isInsideFence(match.range) else { return }
            ts.addAttribute(.foregroundColor, value: self.accentColor, range: match.range)
        }
    }

    // MARK: - [[References]]

    private func applyReferences(in ts: NSTextStorage, range: NSRange) {
        Self.referenceRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match, !isInsideFence(match.range) else { return }
            ts.addAttribute(.foregroundColor, value: self.accentColor, range: match.range)
            ts.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                            range: NSRange(location: match.range.location, length: 2))
            ts.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                            range: NSRange(location: NSMaxRange(match.range) - 2, length: 2))
        }
    }

    // MARK: - Task Lists

    private func applyTaskLists(in ts: NSTextStorage, range: NSRange) {
        Self.taskListRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match, !isInsideFence(match.range) else { return }
            ts.addAttribute(.foregroundColor, value: self.accentColor, range: match.range(at: 1))
        }
    }

    // MARK: - Auto-links (bare URLs)

    private func applyAutolinks(in ts: NSTextStorage, range: NSRange) {
        Self.autolinkRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match, !isInsideFence(match.range) else { return }
            ts.addAttribute(.foregroundColor, value: self.accentColor, range: match.range)
        }
    }

    // MARK: - HTML Tags

    private func applyHTMLTags(in ts: NSTextStorage, range: NSRange) {
        Self.htmlTagRegex.enumerateMatches(in: ts.string, range: range) { match, _, _ in
            guard let match, !isInsideFence(match.range) else { return }
            ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }
    }

    // MARK: - Fenced Code Blocks + Highlightr

    private struct FencedBlock {
        let fullRange: NSRange    // includes ``` lines
        let contentRange: NSRange // code content only (between fences)
        let language: String
    }

    private struct FenceOpen {
        let marker: String
        let lang: String
        let location: Int
        let contentStart: Int
    }

    private var fencedBlocks: [FencedBlock] = []

    private func scanFencedCodeBlocks(in ts: NSTextStorage) {
        let ns = ts.string as NSString
        fencedBlocks = []
        var openInfo: FenceOpen?

        Self.fenceRegex.enumerateMatches(in: ts.string, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let marker = ns.substring(with: match.range(at: 1))
            let lang = match.range(at: 2).length > 0 ? ns.substring(with: match.range(at: 2)) : ""

            if let open = openInfo, open.marker.first == marker.first {
                let contentEnd = match.range.location
                let contentRange = NSRange(location: open.contentStart,
                                           length: max(0, contentEnd - open.contentStart))
                let fullRange = NSRange(location: open.location,
                                        length: NSMaxRange(match.range) - open.location)
                fencedBlocks.append(FencedBlock(fullRange: fullRange,
                                                contentRange: contentRange,
                                                language: open.lang))
                openInfo = nil
            } else if openInfo == nil {
                let contentStart = NSMaxRange(match.range)
                let adjusted = contentStart < ns.length && ns.character(at: contentStart) == 0x0A
                    ? contentStart + 1 : contentStart
                openInfo = FenceOpen(marker: marker, lang: lang,
                                     location: match.range.location, contentStart: adjusted)
            }
        }
    }

    /// Apply Highlightr syntax highlighting to code blocks, or fallback to code font.
    private func applyFencedCodeBlocks(in ts: NSTextStorage, range: NSRange) {
        let hl = getHighlighter()

        for block in fencedBlocks {
            // Apply code font to the full block (including fence lines)
            let fullOverlap = NSIntersectionRange(block.fullRange, range)
            guard fullOverlap.length > 0 else { continue }

            // Fence lines: dim markers
            ts.addAttribute(.font, value: codeFont, range: fullOverlap)
            ts.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: fullOverlap)

            // Content: syntax highlight via Highlightr
            let contentOverlap = NSIntersectionRange(block.contentRange, range)
            guard contentOverlap.length > 0 else { continue }

            let codeString = (ts.string as NSString).substring(with: block.contentRange)
            let lang = block.language.isEmpty ? nil : block.language

            if let hl, !codeString.isEmpty,
               let highlighted = hl.highlight(codeString, as: lang) {
                // Transfer Highlightr's color attributes to our text storage
                highlighted.enumerateAttributes(
                    in: NSRange(location: 0, length: highlighted.length),
                    options: []
                ) { attrs, locRange, _ in
                    let targetLoc = block.contentRange.location + locRange.location
                    let targetLen = min(locRange.length,
                                        (ts.string as NSString).length - targetLoc)
                    guard targetLen > 0 else { return }
                    let targetRange = NSRange(location: targetLoc, length: targetLen)

                    // Only transfer foreground color from Highlightr
                    if let color = attrs[.foregroundColor] {
                        ts.addAttribute(.foregroundColor, value: color, range: targetRange)
                    }
                }
                // Ensure code font on content
                ts.addAttribute(.font, value: codeFont, range: contentOverlap)
            } else {
                // Fallback: just code font + code color
                ts.addAttribute(.foregroundColor, value: Self.codeTextColor, range: contentOverlap)
            }
        }
    }

    private func isInsideFence(_ range: NSRange) -> Bool {
        fencedBlocks.contains { NSIntersectionRange($0.fullRange, range).length > 0 }
    }

    // MARK: - Helpers

    private func resolveCodeFont() -> NSFont {
        let name = Preferences.shared.noteEditorCodeFontFamily
        let size = max(baseFont.pointSize - 1, 12)
        return NSFont(name: name, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
