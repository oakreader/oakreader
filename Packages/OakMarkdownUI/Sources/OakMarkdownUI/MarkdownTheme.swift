import AppKit

/// Visual tokens for native markdown rendering. Pure value type — no chat concepts.
/// `.dia` mirrors metrics measured live from Dia 1.32.0 (see design-token-extraction skill).
public struct MarkdownTheme {
    public var bodyFont: NSFont
    public var codeFont: NSFont
    /// Heading point sizes h1…h6 (absolute, not multipliers).
    public var headingSizes: [CGFloat]
    /// NSParagraphStyle.lineHeightMultiple for body text.
    public var bodyLineHeightMultiple: CGFloat
    /// Extra space below a paragraph block (pt).
    public var paragraphSpacing: CGFloat
    public var codeLineHeightMultiple: CGFloat

    public var textColor: NSColor
    public var secondaryTextColor: NSColor
    public var linkColor: NSColor
    public var inlineCodeBackground: NSColor
    public var codeBlockBackground: NSColor
    public var codeBlockBorder: NSColor
    public var blockquoteBar: NSColor

    /// Highlightr theme names for light / dark appearance.
    public var codeThemeLight: String
    public var codeThemeDark: String

    public init(
        bodyFont: NSFont,
        codeFont: NSFont,
        headingSizes: [CGFloat],
        bodyLineHeightMultiple: CGFloat,
        paragraphSpacing: CGFloat,
        codeLineHeightMultiple: CGFloat,
        textColor: NSColor,
        secondaryTextColor: NSColor,
        linkColor: NSColor,
        inlineCodeBackground: NSColor,
        codeBlockBackground: NSColor,
        codeBlockBorder: NSColor,
        blockquoteBar: NSColor,
        codeThemeLight: String,
        codeThemeDark: String
    ) {
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.headingSizes = headingSizes
        self.bodyLineHeightMultiple = bodyLineHeightMultiple
        self.paragraphSpacing = paragraphSpacing
        self.codeLineHeightMultiple = codeLineHeightMultiple
        self.textColor = textColor
        self.secondaryTextColor = secondaryTextColor
        self.linkColor = linkColor
        self.inlineCodeBackground = inlineCodeBackground
        self.codeBlockBackground = codeBlockBackground
        self.codeBlockBorder = codeBlockBorder
        self.blockquoteBar = blockquoteBar
        self.codeThemeLight = codeThemeLight
        self.codeThemeDark = codeThemeDark
    }

    /// OakReader default — system fonts, ~15pt body (matches `OakStyle.ChatFont.messageBody`).
    public static var oak: MarkdownTheme {
        MarkdownTheme(
            bodyFont: .systemFont(ofSize: 15, weight: .regular),
            codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
            headingSizes: [24, 20, 17, 15, 14, 13],
            bodyLineHeightMultiple: 1.45,
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
    }

    /// Mirrors metrics measured from Dia 1.32.0: body ~15pt, line-height ~1.67, ¶ +12.5pt;
    /// code ~13pt mono ~1.4; hairline border #0F182C@8% / #787D86@32%.
    public static var dia: MarkdownTheme {
        var t = MarkdownTheme.oak
        t.bodyLineHeightMultiple = 1.67
        t.paragraphSpacing = 12
        t.codeBlockBorder = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(srgbRed: 0.471, green: 0.490, blue: 0.525, alpha: 0.32)
                : NSColor(srgbRed: 0.059, green: 0.094, blue: 0.173, alpha: 0.08)
        }
        return t
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
