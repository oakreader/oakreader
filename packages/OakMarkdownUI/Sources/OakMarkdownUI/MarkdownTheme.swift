import AppKit

/// Visual tokens for native markdown rendering. Pure value type — no chat concepts.
/// `.dia` mirrors metrics measured live from Dia 1.32.0 (see design-token-extraction skill).
public struct MarkdownTheme {
    public var bodyFont: NSFont
    public var codeFont: NSFont
    /// Heading point sizes h1…h6 (absolute, not multipliers).
    public var headingSizes: [CGFloat]
    /// Fixed body line height in points (applied as NSParagraphStyle.minimumLineHeight).
    public var bodyLineHeight: CGFloat
    /// Extra space below a paragraph block (pt).
    public var paragraphSpacing: CGFloat
    public var codeLineHeightMultiple: CGFloat

    // Dia's `SupertabTypography.DynamicProperties` keeps a complete set of metrics per
    // text role — plain text, each heading level, tables — rather than one paragraph
    // style with a size ladder over it. These are the parts of that worth carrying:
    // the three numbers that decide whether a message reads as typeset or as a log.
    // See docs/references/dia-chat-implementation.md §2.

    /// Space between items of the same list. Dia names this `listItemSpacing`;
    /// it was a fraction of `paragraphSpacing` here, which tied list rhythm to
    /// paragraph rhythm for no reason.
    public var listItemSpacing: CGFloat = 3

    /// Space ABOVE a heading, by level (h1…h6). A heading belongs to what follows
    /// it, so the space above it must beat the space below — Dia gives every level
    /// its own `paragraphSpacingBefore` for exactly this.
    public var headingSpacingBefore: [CGFloat] = [20, 16, 13, 11, 10, 10]

    /// Space BELOW a heading, by level. Smaller than the space above, which is what
    /// binds the heading to its paragraph.
    public var headingSpacingAfter: [CGFloat] = [7, 6, 5, 4, 4, 4]

    /// Hairline under an inline-code pill. Dia's `InlineCodeProperties` carries a
    /// `strokeColor` next to its fill: on a tinted background the fill alone is
    /// invisible, and the stroke is what keeps the pill readable.
    public var inlineCodeStroke: NSColor = .clear

    /// Corner radius of that pill.
    public var inlineCodeCornerRadius: CGFloat = 4

    /// Underline colour of a link while the pointer is on it. Dia keeps hover
    /// underline colour and style separate from the resting pair
    /// (`SupertabTextView.LinkAttributes`). nil leaves the underline alone.
    public var linkHoverUnderline: NSColor? = nil

    /// Nested quotes dim one step per level, never below this. Dia's
    /// `quoteLevelMinOpacity` — the floor is what keeps a level-4 quote readable.
    public var quoteLevelMinOpacity: CGFloat = 0.55

    /// Underline drawn under a resting link. ChatGPT uses a dotted line in the
    /// secondary text colour, so a link is marked without being blue.
    public var linkUnderlineStyle: NSUnderlineStyle = .single
    /// nil underlines in the link's own colour.
    public var linkUnderlineColor: NSColor? = nil

    /// Left inset of a block quote's text.
    public var blockquoteIndent: CGFloat = 12
    /// Width of the bar at a quote's leading edge. 0 draws no bar: the fill alone
    /// marks the quote.
    public var blockquoteBarWidth: CGFloat = 0

    /// Corner radius of a fenced code block.
    public var codeBlockCornerRadius: CGFloat = 8
    /// Inset of the code inside its block, horizontal and vertical.
    public var codeBlockPadding: CGSize = CGSize(width: 12, height: 8)

    public var textColor: NSColor
    public var secondaryTextColor: NSColor
    public var linkColor: NSColor
    /// Text color of an internal-reference chip (`oak:14`). Citations are styled as
    /// the accent colour and a little heavier — no underline, because the reader
    /// is not leaving the app, and no capsule, because a paragraph with six
    /// citations became a row of buttons rather than a sentence.
    public var citationForeground: NSColor

    /// Resolves an internal reference (`oak:14`) to the words shown in its place.
    ///
    /// The model never writes a citation's label: it writes a fixed placeholder,
    /// because a label it chose is either the handle — a number that means
    /// nothing to a reader with no list to look it up in — or a rephrasing of
    /// the sentence the citation already sits in. The host resolves the handle
    /// to where the passage actually is, which is the one thing the reader
    /// wants and the model cannot know. Dia does the same with `${DIA-SOURCE}`,
    /// resolving its handle to a site name and favicon.
    ///
    /// `nil`, or a `nil` return, leaves the written label alone.
    public var citationLabel: (@Sendable (String) -> String?)?
    public var inlineCodeBackground: NSColor
    public var codeBlockBackground: NSColor
    public var codeBlockBorder: NSColor
    public var blockquoteBar: NSColor
    /// Subtle fill drawn behind a block quote (rounded rect, painted by the layout manager).
    public var blockquoteBackground: NSColor

    /// Highlightr theme names for light / dark appearance.
    public var codeThemeLight: String
    public var codeThemeDark: String

    public init(
        bodyFont: NSFont,
        codeFont: NSFont,
        headingSizes: [CGFloat],
        bodyLineHeight: CGFloat,
        paragraphSpacing: CGFloat,
        codeLineHeightMultiple: CGFloat,
        textColor: NSColor,
        secondaryTextColor: NSColor,
        linkColor: NSColor,
        citationForeground: NSColor = .controlAccentColor,
        citationLabel: (@Sendable (String) -> String?)? = nil,
        inlineCodeBackground: NSColor,
        codeBlockBackground: NSColor,
        codeBlockBorder: NSColor,
        blockquoteBar: NSColor,
        blockquoteBackground: NSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.06),
        codeThemeLight: String,
        codeThemeDark: String
    ) {
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.headingSizes = headingSizes
        self.bodyLineHeight = bodyLineHeight
        self.paragraphSpacing = paragraphSpacing
        self.codeLineHeightMultiple = codeLineHeightMultiple
        self.textColor = textColor
        self.secondaryTextColor = secondaryTextColor
        self.linkColor = linkColor
        self.citationForeground = citationForeground
        self.citationLabel = citationLabel
        self.inlineCodeBackground = inlineCodeBackground
        self.codeBlockBackground = codeBlockBackground
        self.codeBlockBorder = codeBlockBorder
        self.blockquoteBar = blockquoteBar
        self.blockquoteBackground = blockquoteBackground
        self.codeThemeLight = codeThemeLight
        self.codeThemeDark = codeThemeDark
    }

    /// OakReader default — system fonts scaled from `fontSize`. Code, heading, and
    /// line-height metrics are all derived from it so the whole block scales together.
    public static func oak(fontSize: CGFloat = 14, lineHeightScale: CGFloat = 1.4) -> MarkdownTheme {
        let headingScales: [CGFloat] = [1.6, 1.33, 1.13, 1.0, 0.93, 0.87]
        var theme = MarkdownTheme(
            bodyFont: .systemFont(ofSize: fontSize, weight: .regular),
            codeFont: .monospacedSystemFont(ofSize: max(fontSize - 2, 9), weight: .regular),
            headingSizes: headingScales.map { ($0 * fontSize).rounded() },
            bodyLineHeight: (fontSize * lineHeightScale).rounded(),
            paragraphSpacing: 10,
            codeLineHeightMultiple: 1.4,
            textColor: .labelColor,
            secondaryTextColor: .secondaryLabelColor,
            linkColor: .linkColor,
            inlineCodeBackground: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
            codeBlockBackground: NSColor.textColor.withAlphaComponent(0.05),
            codeBlockBorder: NSColor.separatorColor,
            blockquoteBar: NSColor.separatorColor,
            codeThemeLight: "github",
            codeThemeDark: "github-dark"
        )
        theme.linkHoverUnderline = NSColor.linkColor
        return theme
    }

    /// Mirrors metrics measured from Dia 1.32.0: body ~15pt, line-height ~1.67, ¶ +12.5pt;
    /// code ~13pt mono ~1.4; hairline border #0F182C@8% / #787D86@32%.
    public static var dia: MarkdownTheme {
        var t = MarkdownTheme.oak(fontSize: 15, lineHeightScale: 1.67)
        t.paragraphSpacing = 12
        t.headingSpacingBefore = [22, 18, 14, 12, 11, 11]
        t.headingSpacingAfter = [8, 7, 5, 5, 4, 4]
        t.inlineCodeStroke = NSColor.separatorColor.withAlphaComponent(0.6)
        t.codeBlockBorder = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(srgbRed: 0.471, green: 0.490, blue: 0.525, alpha: 0.32)
                : NSColor(srgbRed: 0.059, green: 0.094, blue: 0.173, alpha: 0.08)
        }
        return t
    }

    /// Mirrors the chat preset of ChatGPT's native Mac app (`OAIMarkdown.MarkdownOptions`,
    /// 1.2026.183, built from the iOS codebase), read from the shipped binary and its
    /// asset catalog.
    ///
    /// Observed: body = system 14 pt with line-height multiple 1.35; code and
    /// tables 13 pt; list items 4 apart; quote = 4 pt bar, no fill, 15 pt indent;
    /// code block radius 16, insets 16; links in the text colour with a dotted
    /// underline in the secondary colour; inline code without a pill; colours from
    /// `OneOff/TextMessageBot`, `ChatGPT/text/*`, `OneOff/CodeBlockBackground`.
    ///
    /// Not observed, chosen here: heading point sizes (the binary maps H1–H3 to the
    /// `title` styles and H4+ to `headline` but stores no sizes; macOS's `headline`
    /// is smaller than this body, so H4+ use the body size), and the 16 pt gap
    /// between paragraphs (the binary's 16 pt block gap; its 24 pt paragraph spacing
    /// is measured under a layout this view does not have).
    public static var chatGPT: MarkdownTheme {
        let bodySize: CGFloat = 14
        let body = NSFont.systemFont(ofSize: bodySize, weight: .regular)
        let natural = body.ascender - body.descender + body.leading
        var t = MarkdownTheme(
            bodyFont: body,
            codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
            headingSizes: [22, 17, 15, bodySize, bodySize, bodySize],
            bodyLineHeight: (natural * 1.35).rounded(),
            paragraphSpacing: 16,
            codeLineHeightMultiple: 1.35,
            textColor: .dynamic(light: 0x111111, dark: 0xFFFFFF),
            secondaryTextColor: .dynamic(light: 0x5D5D5D, dark: 0xCDCDCD),
            linkColor: .dynamic(light: 0x0D0D0D, dark: 0xFFFFFF),
            inlineCodeBackground: .clear,
            codeBlockBackground: .dynamic(light: 0xF8F8F8, dark: 0x212121),
            codeBlockBorder: .dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: 0.05),
            blockquoteBar: .dynamic(light: 0xE8E8E8, dark: 0x303030),
            blockquoteBackground: .clear,
            codeThemeLight: "xcode",
            codeThemeDark: "atom-one-dark"
        )
        t.listItemSpacing = 4
        t.linkUnderlineStyle = [.single, .patternDot]
        t.linkUnderlineColor = .dynamic(light: 0x5D5D5D, dark: 0xCDCDCD)
        t.linkHoverUnderline = t.linkColor
        t.blockquoteIndent = 15
        t.blockquoteBarWidth = 4
        t.codeBlockCornerRadius = 16
        t.codeBlockPadding = CGSize(width: 16, height: 16)
        return t
    }
}

extension NSColor {
    /// An appearance-aware colour from two sRGB hex values.
    static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: alpha)
        }
        return NSColor(name: nil) { $0.isDark ? rgb(dark) : rgb(light) }
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
