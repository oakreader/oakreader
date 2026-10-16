import SwiftUI
import AppKit
import OakMarkdownUI

struct ChatBubbleView: View, Equatable {
    let turn: Turn
    /// Resolves an `oak:N` citation link to the passage it names. Supplied by the host
    /// because the source table belongs to the conversation, not to the bubble.
    var resolveCitation: ((URL) -> (itemId: String, anchor: CitationAnchor)?)?
    var onOpenCitation: ((String, CitationAnchor) -> Void)?
    /// Optional markdown theme override (e.g. `.dia` for the agent canvas).
    /// When nil, falls back to the user-configured `.oak` theme.
    var markdownTheme: MarkdownTheme? = nil
    /// What a model-written widget in this turn asked for. nil shows widgets as code.
    var onWidgetAction: ((GenUIAction) -> Void)?
    /// Names the document an item id refers to, for the sources pill.
    var sourceTitle: ((String) -> String?)?

    // Memoization for `.equatable()`: only the parent-supplied inputs that change
    // the rendered output drive a re-render. Closures are stable per host, and
    // `markdownTheme` is fixed for the view's lifetime (panel vs canvas never
    // toggles for an existing bubble), so both are excluded. Internal @State and
    // @AppStorage still invalidate the view directly — EquatableView only
    // short-circuits re-renders propagated from the parent's body.
    static func == (lhs: ChatBubbleView, rhs: ChatBubbleView) -> Bool {
        lhs.turn == rhs.turn
    }

    @State private var isHovered = false
    @State private var isCopyHovered = false
    @State private var showCopied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if turn.role != .system {
            HStack(alignment: .top) {
                if turn.role == .user { Spacer(minLength: 40) }

                VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 4) {
                    // Inline attachments for user messages
                    if turn.role == .user && !turn.attachments.isEmpty {
                        FannedAttachmentStack(attachments: turn.attachments)
                    }

                    // Thinking and tool calls render in `AgentStepsView`, which
                    // merges a whole agent run into one group; see `ChatDisplayItem`.

                    // Message content
                    if shouldShowMessageBubble {
                        messageBubble
                    }

                    if let sources = citedSources {
                        ChatSourcesPill(sources: sources) { itemId, anchor in
                            onOpenCitation?(itemId, anchor)
                        }
                        .padding(.top, 2)
                    }

                    // While text streams, the breathing dot sits after its last
                    // word (`showsTypingDot`), as ChatGPT draws it — not on a row
                    // of its own under the answer.

                    // Error indicator
                    if let error = turn.error {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    if shouldShowActions {
                        HStack(spacing: 2) {
                            actionButton(
                                systemImage: showCopied ? "checkmark" : "square.on.square",
                                foregroundStyle: showCopied ? .green : .secondary,
                                isHovered: isCopyHovered,
                                tooltip: showCopied ? "Copied!" : "Copy"
                            ) {
                                copyContent()
                                showCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    showCopied = false
                                }
                            }
                            .onHover { isCopyHovered = $0 }
                            .animation(OakStyle.Motion.fast, value: showCopied)
                            .animation(OakStyle.Motion.fast, value: isCopyHovered)
                        }
                    }
                }

                if turn.role == .assistant { Spacer(minLength: 4) }
            }
            .clipped()
            .onHover { isHovered = $0 }
            .animation(OakStyle.Motion.fast, value: isHovered)
        }
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private var messageBubble: some View {
        plainMessageBubble
    }

    /// `OpenURLAction` that intercepts `oak:N` citation links and delegates to
    /// `onOpenCitation`. Everything else falls through to the system handler.
    private var citationOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            guard let (itemId, anchor) = resolveCitation?(url) else { return .systemAction }
            onOpenCitation?(itemId, anchor)
            return .handled
        }
    }

    /// True while this turn's text is still streaming in. (The per-glyph fade-in
    /// finishes on its own ~0.2s after the last delta; we don't gate UI on it.)
    private var isRevealing: Bool {
        turn.isStreaming
    }

    /// The passages this answer cites, once it has finished. nil when it cites none.
    private var citedSources: ChatCitedSources? {
        guard turn.role == .assistant, !turn.isStreaming, turn.content.contains("oak:"),
              let resolveCitation else { return nil }
        let sources = ChatCitedSources(markdown: turn.content, resolve: resolveCitation,
                                       title: { sourceTitle?($0) })
        return sources.passageCount > 0 ? sources : nil
    }

    // MARK: - Citation hover card

    /// Whether a citation hover card shows anything beyond the link's own visible text.
    /// A page/heading/timestamp is always extra location info worth a card; a `?text=`
    /// quote is only worth showing when it differs from the label the reader already sees.
    static func citationCardAddsInfo(_ anchor: CitationAnchor, label: String) -> Bool {
        if anchor.page != nil || anchor.time != nil { return true }
        if let heading = anchor.heading, !heading.isEmpty,
           !normalizedEqual(heading, label) { return true }
        if let text = anchor.text, !text.isEmpty,
           !normalizedEqual(text, label) { return true }
        return false
    }

    /// Loose equality for citation text vs. its visible label: case-insensitive, with
    /// surrounding quotes/whitespace and internal whitespace runs normalized away, so
    /// `"93% last month"` (label) and `93% last month` (quote) count as the same.
    private static func normalizedEqual(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            let stripped = s.trimmingCharacters(
                in: CharacterSet(charactersIn: " \t\n\"“”'‘’"))
            return stripped.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return norm(a) == norm(b)
    }

    // MARK: - Bare citation linkification

    /// A compact, human-readable label for a citation chip, derived from its anchor —
    /// used when the model emitted a *bare* `oak://` URL with no visible link text.
    /// We deliberately keep it short (a page/heading/timecode marker) rather than
    /// inlining the `?text=` quote, since the claim sentence already precedes the link.
    static func citationLabel(for anchor: CitationAnchor) -> String {
        let raw: String
        if let page = anchor.page {
            raw = "p. \(page + 1)"                 // anchor.page is 0-based
        } else if let h = anchor.heading, !h.isEmpty {
            raw = "§ " + (h.count > 24 ? h.prefix(24) + "…" : Substring(h))
        } else if let time = anchor.time {
            let s = Int(time.rounded())
            raw = String(format: "%d:%02d", s / 60, s % 60)
        } else {
            raw = "source"
        }
        // Brackets would break the `[label](url)` we wrap this in.
        return raw.replacingOccurrences(of: "[", with: "")
                  .replacingOccurrences(of: "]", with: "")
    }

    /// cmark only turns `[label](url)` into a link — a *bare* `oak:14` (which the model
    /// sometimes emits when it forgets the markdown wrapper) would render as the literal
    /// text "oak:14" with no chip, hover card, or click-to-jump. This wraps any such bare
    /// citation in `[label](oak:14)`. Numbers already inside `[](…)` are left untouched.
    static func linkifyBareCitations(
        _ markdown: String,
        isStreaming: Bool,
        resolve: ((URL) -> (itemId: String, anchor: CitationAnchor)?)?
    ) -> String {
        guard let resolve, markdown.contains("oak:") else { return markdown }
        let ns = markdown as NSString
        // `oak:` + digits, not already opened by `(` (a link destination).
        guard let re = try? NSRegularExpression(pattern: "(?<!\\()oak:[0-9]+\\b") else {
            return markdown
        }
        let matches = re.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return markdown }

        let out = NSMutableString(string: markdown)
        // Replace back-to-front so earlier (still-original) ranges stay valid.
        for m in matches.reversed() {
            // While streaming, a number touching the end is likely still growing —
            // leave it bare until a delimiter follows so we don't wrap a partial id.
            if isStreaming && m.range.location + m.range.length == ns.length { continue }
            let raw = ns.substring(with: m.range)
            guard let url = URL(string: raw), let (_, anchor) = resolve(url) else { continue }
            out.replaceCharacters(in: m.range, with: "[\(Self.citationLabel(for: anchor))](\(raw))")
        }
        return out as String
    }

    /// Renders chat markdown via the native `StreamingMarkdownView` (OakMarkdownUI).
    ///
    /// It splits the (growing) markdown into fence-aware blocks and re-renders only the
    /// trailing block while streaming. Incomplete math/markup needs no sealing — a
    /// half-written `$…` or `**…` just stays literal until its closing delimiter arrives.
    /// Text selection is disabled while `streaming` (a settled, selectable block is only
    /// produced once the turn stops growing).
    @ViewBuilder
    private func chatMarkdown(_ markdown: String, streaming: Bool = false, fadesAppendedText: Bool = false) -> some View {
        // Native renderer (OakMarkdownUI): swift-markdown + Highlightr + SwiftMath,
        // block-stack with settled-block memoization + incremental tail editing —
        // the same native stack Dia uses. This is the app's sole markdown renderer.
        StreamingMarkdownView(
            markdown: markdown,
            theme: citationAware(markdownTheme ?? .oak()),
            isStreaming: streaming,
            fadesAppendedText: fadesAppendedText,
            showsTypingDot: streaming,
            onOpenURL: { url in
                // Intercept oak:// citation links; let everything else open in the browser.
                guard let (itemId, anchor) = resolveCitation?(url) else { return false }
                onOpenCitation?(itemId, anchor)
                return true
            },
            linkPreview: { url, label in
                // Hovering a citation shows the cited source instead of the raw oak:// URL.
                guard let (_, anchor) = resolveCitation?(url) else { return nil }
                // Skip the card when it would only echo the link's own visible text.
                // Web citations often inline the quote itself as the label, so a card
                // repeating that quote adds nothing; a page/heading/timestamp still does.
                guard Self.citationCardAddsInfo(anchor, label: label) else { return nil }
                return AnyView(CitationHoverCard(anchor: anchor))
            },
            widget: onWidgetAction.map { onAction in
                { source, isComplete, index in
                    // A closed fence that is not a widget shows as code, the way
                    // ChatGPT falls back to markdown for a payload it cannot use.
                    if isComplete, GenUIWidgetView.payload(from: source) == nil { return nil }
                    return AnyView(GenUIWidgetView(source: source, isComplete: isComplete,
                                                   stateKey: "\(turn.id)-\(index)",
                                                   onAction: onAction))
                }
            }
        )
    }

    /// Teach a theme how to name a citation.
    ///
    /// The model writes a placeholder where the label goes, and this turns the
    /// handle behind it into the passage's location — "Page 15", a heading, a
    /// timestamp. That is the one thing about a citation the reader wants and
    /// the model cannot know, and it is the same string the hover card leads
    /// with, so the inline text and the card agree.
    private func citationAware(_ theme: MarkdownTheme) -> MarkdownTheme {
        guard let resolveCitation else { return theme }
        var theme = theme
        theme.citationLabel = { destination in
            // A number the table does not hold was invented by the model, or its
            // table was lost. It points nowhere, so it shows nothing: the raw
            // `${OAK-SOURCE}` placeholder in the answer reads as a broken app.
            guard let url = URL(string: destination),
                  let (_, anchor) = resolveCitation(url) else { return "" }
            return CitationHoverCard.locationLabel(for: anchor)
        }
        return theme
    }

    @ViewBuilder
    private var plainMessageBubble: some View {
        if turn.role == .assistant {
            chatMarkdown(renderedContent, streaming: isRevealing,
                         fadesAppendedText: turn.isStreaming && !reduceMotion)
                .environment(\.openURL, citationOpenURLAction)
                .assistantBubbleStyle()
        } else {
            HStack(alignment: .top, spacing: 6) {
                ForEach(skillBadges, id: \.self) { skill in
                    skillBadge(skill)
                }
                ForEach(Array(referenceBadges.enumerated()), id: \.offset) { _, ref in
                    referenceBadge(ref.title, icon: ref.icon)
                }
                if !renderedContent.isEmpty {
                    // User messages render via SwiftUI Text, not the NSTextView-backed
                    // StreamingMarkdownView: a static (non-streaming) turn inserted into
                    // the live list during the spring transition can have its NSTextView
                    // initial draw botched and — never updating again — stay blank. Text
                    // has no such insertion-draw race, and user messages are short.
                    userMessageText
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 4,
                    topTrailingRadius: 16
                )
                .fill(bubbleColor)
            )
            .foregroundStyle(Color(nsColor: .labelColor))
        }
    }

    private var bubbleColor: Color {
        switch turn.role {
        case .user:
            return Color.primary.opacity(0.06)
        case .assistant, .system:
            return Color.clear
        }
    }

    /// User-message body rendered with a native SwiftUI `Text` (markdown-aware).
    private var userMessageText: some View {
        let size = markdownTheme?.bodyFont.pointSize ?? MarkdownTheme.oak().bodyFont.pointSize
        return Text(userAttributedContent)
            .font(.system(size: size))
            .textSelection(.enabled)
            .tint(.accentColor)
            .environment(\.openURL, citationOpenURLAction)
            // Hug the text: the bubble is as wide as its message, up to the row
            // width (the leading Spacer keeps it right-aligned), and wraps after.
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Parse the user message's inline markdown, preserving line breaks. Falls
    /// back to plain text if parsing fails.
    private var userAttributedContent: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: renderedContent, options: options) {
            return attributed
        }
        return AttributedString(renderedContent)
    }

    private var renderedContent: String {
        if turn.role == .user {
            let parsed = Self.extractLeadingSkillTags(from: turn.content)
            if !parsed.skillIds.isEmpty && parsed.content == "/" { return "" }
            let (_, stripped) = Self.extractReferencedDocuments(from: parsed.content)
            return stripped
        }
        // Hand the renderer the full content as it streams. The reveal animation is
        // now a glyph fade-in inside the text view (Dia's model), not a typewriter
        // prefix — so there's no truncation here. No sealing/backslash protection
        // needed: StreamingMarkdownView renders partial markdown as-is (unclosed
        // markers stay literal) and handles math via its own block splitter.
        // Defensive: linkify any bare `oak://` citation the model forgot to wrap in
        // `[label](…)`, so it renders as a clean chip instead of a raw URL blob.
        return Self.linkifyBareCitations(turn.content, isStreaming: turn.isStreaming,
                                         resolve: resolveCitation)
    }

    private var skillBadges: [String] {
        guard turn.role == .user else { return [] }
        let parsed = Self.extractLeadingSkillTags(from: turn.content)
        if !parsed.skillIds.isEmpty { return parsed.skillIds }
        if let skill = turn.metadata["skill"] { return [skill] }
        return []
    }

    private var referenceBadges: [(title: String, icon: String)] {
        guard turn.role == .user else { return [] }
        let parsed = Self.extractLeadingSkillTags(from: turn.content)
        let (refs, _) = Self.extractReferencedDocuments(from: parsed.content)
        return refs
    }

    private static func extractReferencedDocuments(
        from content: String
    ) -> (refs: [(title: String, icon: String)], cleaned: String) {
        // Use NSString/NSRange throughout to avoid String.Index validation
        // crashes with certain Unicode content (e.g. emoji, CJK characters).
        let ns = content as NSString
        let startNS = ns.range(of: "<referenced-documents>")
        let endNS = ns.range(of: "</referenced-documents>")

        guard startNS.location != NSNotFound,
              endNS.location != NSNotFound,
              startNS.location + startNS.length <= endNS.location else {
            return ([], content)
        }

        let blockEnd = endNS.location + endNS.length
        let xmlBlock = ns.substring(with: NSRange(location: startNS.location,
                                                  length: blockEnd - startNS.location))
        let before = ns.substring(to: startNS.location)
        let after = ns.substring(from: blockEnd)
        let cleaned = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract doc and note elements
        var refs: [(title: String, icon: String)] = []
        let xmlNS = xmlBlock as NSString
        let fullRange = NSRange(location: 0, length: xmlNS.length)

        for match in refDocPattern.matches(in: xmlBlock, range: fullRange) {
            let title = xmlUnescape(xmlNS.substring(with: match.range(at: 1)))
            refs.append((title: title, icon: "doc.text"))
        }

        return (refs, cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func extractLeadingSkillTags(from content: String) -> (skillIds: [String], content: String) {
        var remaining = content
        var skillIds: [String] = []

        while true {
            let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("[[skill:") else { break }
            guard let closeRange = trimmed.range(of: "]]") else { break }

            let valueStart = trimmed.index(trimmed.startIndex, offsetBy: "[[skill:".count)
            let rawSkill = String(trimmed[valueStart..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawSkill.isEmpty {
                skillIds.append(rawSkill)
            }
            remaining = String(trimmed[closeRange.upperBound...])
        }

        return (skillIds, remaining.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var shouldShowActions: Bool {
        turn.role == .assistant && !turn.isStreaming && !renderedContent.isEmpty
    }

    private var shouldShowMessageBubble: Bool {
        if turn.role == .assistant {
            // Skip the empty bubble for tool-only agentic turns (no text content).
            // While tools are executing the turn streams with empty content but
            // carries tool-use records — don't render a blank bubble for it.
            if !renderedContent.isEmpty { return true }
            return turn.isStreaming && turn.toolUses.isEmpty
        }
        return !renderedContent.isEmpty || !skillBadges.isEmpty || !referenceBadges.isEmpty
    }

    private func skillBadge(_ skillId: String) -> some View {
        let skill = SkillStore.shared.skill(matching: skillId)
        // Grey, the same colour as the composer chip (ChatTokenAttachment,
        // `OakStyle.Colors.skillChip`). An accent-coloured label was the loudest
        // thing in the thread.
        return HStack(spacing: 3) {
            Image(systemName: skill?.symbolName ?? "sparkles")
                .font(OakStyle.ChatFont.modelLabel)
            Text(skill?.title ?? skillId)
                .font(OakStyle.ChatFont.modelLabel)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        .fixedSize()
    }

    private func referenceBadge(_ title: String, icon: String) -> some View {
        // A neutral light-grey chip (not the old hard-orange, and not the accent used
        // for skill commands): a reference is passive context, so it reads as a quiet
        // chip in the app's grey palette — muted secondary text on a faint fill.
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(OakStyle.ChatFont.badge)
            Text(title)
                .font(OakStyle.ChatFont.badge)
                .lineLimit(1)
        }
        .foregroundStyle(OakStyle.Colors.chipForeground)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(OakStyle.Colors.chipFill)
        )
        .fixedSize()
    }

    private func actionButton(
        systemImage: String,
        foregroundStyle: Color,
        isHovered: Bool,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: OakStyle.ChatFont.actionIconSize))
                .foregroundStyle(foregroundStyle)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private func copyContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.content, forType: .string)
    }

    // MARK: - Helpers

    private static func xmlUnescape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    // Regex: extract title from <doc> elements in <referenced-documents>
    // swiftlint:disable:next force_try
    private static let refDocPattern = try! NSRegularExpression(
        pattern: #"<doc\s[^>]*?title="([^"]*)"[^>]*/>"#
    )

}

// MARK: - Assistant Bubble Style

private struct AssistantBubbleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .foregroundStyle(Color(nsColor: .labelColor))
    }
}

private extension View {
    func assistantBubbleStyle() -> some View {
        modifier(AssistantBubbleStyle())
    }
}

// MARK: - Streaming Cursor (pulsing dot)
//
// ChatGPT's working indicator is one dot that breathes (`TypingDotView`,
// `isDotBallLoadingIndicatorEnabled`), not a row of bouncing dots. The same
// dot sits at the end of the text while an answer streams (see
// `StreamingMarkdownView.showsTypingDot`), so the wait before the first word and
// the writing after it read as one thing. Driven by Core Animation, so it stays
// smooth while the main thread lays out markdown. Static under Reduce Motion.
struct StreamingCursor: NSViewRepresentable {
    fileprivate static let size: CGFloat = 10

    func makeNSView(context: Context) -> DotView { DotView() }
    func updateNSView(_ nsView: DotView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotView, context: Context) -> CGSize? {
        CGSize(width: Self.size, height: Self.size)
    }

    final class DotView: NSView {
        private let dot = CALayer()

        override var intrinsicContentSize: NSSize {
            NSSize(width: StreamingCursor.size, height: StreamingCursor.size)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            dot.cornerRadius = StreamingCursor.size / 2
            layer?.addSublayer(dot)
            applyColor()
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(reduceMotionChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

        @objc private func reduceMotionChanged() {
            if window != nil { TypingDot.animate(dot) }
        }

        override func layout() {
            super.layout()
            let s = StreamingCursor.size
            dot.frame = CGRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
        }

        // CA strips animations when a layer leaves the window; re-add on (re)attach.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { TypingDot.animate(dot) }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColor()
        }

        private func applyColor() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                dot.backgroundColor = NSColor.labelColor.cgColor
            }
        }
    }
}

