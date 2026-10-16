import SwiftUI

/// Native, streaming-friendly markdown renderer. Splits the (possibly growing) markdown
/// into fence-aware blocks and renders each with the right native view: prose →
/// `NSTextView` (swift-markdown attributed), code → Highlightr, display math → SwiftMath.
/// Settled blocks are memoized (Equatable), so while streaming only the trailing block
/// re-renders — feed it via `DeltaCoalescer` for Dia-grade smoothness.
///
/// Reusable: depends only on Highlightr + SwiftMath + swift-markdown. No chat/app concepts.
public struct StreamingMarkdownView: View {
    public var markdown: String
    public var theme: MarkdownTheme
    public var isStreaming: Bool
    /// Intercepts link clicks in prose. Return `true` if handled, `false` to let the
    /// system open the URL. Used by hosts to handle custom schemes (e.g. `oak://`).
    public var onOpenURL: ((URL) -> Bool)?
    /// Supplies a rich hover-preview for a link, given its URL and visible label text.
    /// When it returns a non-nil view, hovering the link shows that view in a popover.
    /// Returning nil shows no popover — the host can use the label to skip a preview
    /// that would merely echo the link's own visible text. (The raw-URL tooltip is
    /// suppressed for custom-scheme links regardless.)
    public var linkPreview: ((URL, String) -> AnyView?)?

    /// When true, the streaming trailing block fades newly-appended text in (Dia's
    /// glyph reveal). The host gates this (e.g. off for Reduce Motion).
    public var fadesAppendedText: Bool

    /// Renders a model-written widget: a fenced block tagged `genui`. Gets the
    /// fence body, whether its closing fence has arrived, and the block's index.
    /// Return nil to show the block as code instead — no renderer, or a body
    /// that is not a widget. The renderer lives in the host because it is a web
    /// view over the host's bundled runtime; this package stays app-agnostic.
    public var widget: ((_ source: String, _ isComplete: Bool, _ index: Int) -> AnyView?)?

    /// ChatGPT's breathing dot after the last word while the answer streams.
    /// Drawn only when the last block is prose.
    public var showsTypingDot: Bool

    public init(markdown: String, theme: MarkdownTheme = .oak(), isStreaming: Bool = false,
                fadesAppendedText: Bool = false,
                showsTypingDot: Bool = false,
                onOpenURL: ((URL) -> Bool)? = nil,
                linkPreview: ((URL, String) -> AnyView?)? = nil,
                widget: ((_ source: String, _ isComplete: Bool, _ index: Int) -> AnyView?)? = nil) {
        self.markdown = markdown
        self.theme = theme
        self.isStreaming = isStreaming
        self.fadesAppendedText = fadesAppendedText
        self.onOpenURL = onOpenURL
        self.linkPreview = linkPreview
        self.widget = widget
        self.showsTypingDot = showsTypingDot
    }

    public var body: some View {
        let blocks = MarkdownBlockSplitter.split(markdown)
        let lastID = blocks.last?.id
        VStack(alignment: .leading, spacing: theme.paragraphSpacing) {
            ForEach(blocks) { block in
                BlockRow(block: block, theme: theme,
                         streaming: isStreaming && !block.isSettled,
                         fadesAppendedText: fadesAppendedText,
                         typingDot: showsTypingDot && isStreaming && block.id == lastID,
                         onOpenURL: onOpenURL, linkPreview: linkPreview, widget: widget)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Equatable so SwiftUI skips `body` for settled blocks whose text/kind didn't change —
/// the parser/typesetter never re-runs for them.
private struct BlockRow: View, Equatable {
    let block: MarkdownBlock
    let theme: MarkdownTheme
    let streaming: Bool
    let fadesAppendedText: Bool
    let typingDot: Bool
    // Excluded from `==`: the handler is stable per host, and a closure isn't
    // Equatable. Only block text/kind and streaming state drive re-rendering.
    var onOpenURL: ((URL) -> Bool)?
    var linkPreview: ((URL, String) -> AnyView?)?
    var widget: ((String, Bool, Int) -> AnyView?)?

    static func == (lhs: BlockRow, rhs: BlockRow) -> Bool {
        lhs.block == rhs.block && lhs.streaming == rhs.streaming
            && lhs.fadesAppendedText == rhs.fadesAppendedText
            && lhs.typingDot == rhs.typingDot
    }

    private var prose: some View {
        ProseBlockView(
            // While streaming, optimistically close a half-arrived trailing link so
            // a citation shows its short label instead of flashing the bare `oak:14`
            // destination until the closing `)` lands. See StreamingMarkdownSanitizer.
            attributed: MarkdownAttributedBuilder.attributedString(
                for: streaming ? StreamingMarkdownSanitizer.completeTrailingLink(block.text) : block.text,
                theme: theme),
            selectable: !streaming,
            animatesAppendedText: streaming && fadesAppendedText,
            showsTypingDot: typingDot,
            onOpenURL: onOpenURL,
            linkPreview: linkPreview,
            linkHoverUnderline: theme.linkHoverUnderline
        )
    }

    @ViewBuilder
    var body: some View {
        switch block.kind {
        case .prose:
            prose
        case .mathDisplayOpen:
            // While the reply streams, draw what has arrived instead of the source.
            // A finished reply with an unclosed `$$` keeps it as typed.
            if streaming {
                StreamingMathBlockView(latex: MathDelimiters.stripOpenDisplay(block.text), theme: theme)
            } else {
                prose
            }
        case .code(let language):
            if language?.lowercased() == CodeFence.widgetLanguage,
               let view = widget?(CodeFence.strip(block.text), CodeFence.isClosed(block.text), block.id) {
                view
            } else {
                CodeBlockView(code: CodeFence.strip(block.text), language: language, theme: theme)
            }
        case .mathDisplay:
            MathBlockView(latex: MathDelimiters.stripDisplay(block.text), theme: theme)
        case .table:
            TableBlockView(source: block.text, theme: theme)
        case .image(let url, let alt):
            ImageBlockView(url: url, alt: alt, theme: theme)
        }
    }
}

enum CodeFence {
    /// Fence tag of a model-written widget.
    static let widgetLanguage = "genui"

    /// True once the block's closing fence has arrived.
    static func isClosed(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, let last = lines.last else { return false }
        return last.hasPrefix("```") || last.hasPrefix("~~~")
    }

    /// Drop the opening ```/~~~ (with language) and the closing fence line.
    static func strip(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func isFence(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("```") || t.hasPrefix("~~~")
        }
        if let first = lines.first, isFence(first) { lines.removeFirst() }
        if let last = lines.last, isFence(last) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

enum MathDelimiters {
    /// Strip the surrounding `$$` from a display-math block.
    static func stripDisplay(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("$$") { t.removeFirst(2) }
        if t.hasSuffix("$$") { t.removeLast(2) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The body of a display span still streaming: the opening `$$` and the first
    /// `$` of a half-arrived close removed.
    static func stripOpenDisplay(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("$$") { t.removeFirst(2) }
        if t.hasSuffix("$"), !t.hasSuffix("\\$") { t.removeLast() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
