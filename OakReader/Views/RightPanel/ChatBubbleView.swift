import SwiftUI
import AppKit
import OakAgent
import Textual
import OakMarkdownUI

struct ChatBubbleView: View, Equatable {
    let turn: Turn
    var onPlayAudio: ((Turn) -> Void)?
    var isPlayingAudio: Bool = false
    var onStopAudio: (() -> Void)?
    var onOpenCitation: ((String, CitationAnchor) -> Void)?
    var onSaveQuizCard: ((QuizContent) -> Bool)?
    /// Optional markdown theme override (e.g. `.dia` for the agent canvas).
    /// When nil, falls back to the user-configured `.oak` theme.
    var markdownTheme: MarkdownTheme? = nil

    // Memoization for `.equatable()`: only the parent-supplied inputs that change
    // the rendered output drive a re-render. Closures are stable per host, and
    // `markdownTheme` is fixed for the view's lifetime (panel vs canvas never
    // toggles for an existing bubble), so both are excluded. Internal @State and
    // @AppStorage still invalidate the view directly — EquatableView only
    // short-circuits re-renders propagated from the parent's body.
    static func == (lhs: ChatBubbleView, rhs: ChatBubbleView) -> Bool {
        lhs.turn == rhs.turn && lhs.isPlayingAudio == rhs.isPlayingAudio
    }

    @AppStorage("chatFontSize") private var chatFontSize: Double = 14
    @AppStorage("chatLineHeightScale") private var chatLineHeightScale: Double = 1.35

    @State private var isHovered = false
    @State private var isCopyHovered = false
    @State private var isPlayHovered = false
    @State private var showCopied = false
    @State private var reveal = StreamRevealController()

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

                    // Extended thinking disclosure
                    if turn.role == .assistant, let thinking = turn.thinking, !thinking.isEmpty {
                        ThinkingDisclosureView(
                            thinking: thinking,
                            isStreaming: turn.isStreaming && turn.content.isEmpty
                        )
                    }

                    // Tool call cards for assistant messages. `quiz_cards` tool
                    // calls are drawn as inline flashcard carousels; everything
                    // else uses the generic collapsible tool-call summary.
                    if turn.role == .assistant && !turn.toolUses.isEmpty {
                        if !otherToolRecords.isEmpty {
                            ToolCallGroupView(records: otherToolRecords)
                        }
                        ForEach(renderCardRecords) { record in
                            if let deck = Self.decodeCardDeck(from: record) {
                                InlineDeckView(deck: deck, onSaveCard: onSaveQuizCard)
                                    .environment(\.openURL, citationOpenURLAction)
                            }
                        }
                    }

                    // Message content
                    if shouldShowMessageBubble {
                        messageBubble
                    }

                    // Streaming cursor — only while text is streaming, not while a
                    // tool-only turn is executing (the tool-call shimmer covers that).
                    if (turn.isStreaming || reveal.isAnimating) && shouldShowMessageBubble {
                        StreamingCursor()
                            .padding(.leading, 4)
                    }

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
                                systemImage: showCopied ? "checkmark" : "doc.on.doc",
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
                            .animation(.spring(duration: 0.25, bounce: 0.3), value: showCopied)
                            .animation(.spring(duration: 0.2, bounce: 0.2), value: isCopyHovered)

                            if onPlayAudio != nil {
                                actionButton(
                                    systemImage: isPlayingAudio ? "stop.fill" : "play.fill",
                                    foregroundStyle: isPlayingAudio ? .accentColor : .secondary,
                                    isHovered: isPlayHovered,
                                    tooltip: isPlayingAudio ? "Stop" : "Play Audio"
                                ) {
                                    if isPlayingAudio {
                                        onStopAudio?()
                                    } else {
                                        onPlayAudio?(turn)
                                    }
                                }
                                .onHover { isPlayHovered = $0 }
                                .animation(.spring(duration: 0.2, bounce: 0.2), value: isPlayingAudio)
                                .animation(.spring(duration: 0.2, bounce: 0.2), value: isPlayHovered)
                            }
                        }
                    }
                }

                if turn.role == .assistant { Spacer(minLength: 4) }
            }
            .clipped()
            .onHover { isHovered = $0 }
            .animation(.spring(duration: 0.2, bounce: 0.15), value: isHovered)
            .onChange(of: turn.content) { _, newContent in
                if turn.isStreaming && turn.role == .assistant {
                    reveal.push(newContent)
                } else {
                    reveal.flush(newContent)
                }
            }
            .onChange(of: turn.isStreaming) { _, streaming in
                if !streaming {
                    reveal.endStreaming(turn.content)
                }
            }
            .onAppear {
                if turn.isStreaming && turn.role == .assistant {
                    reveal.push(turn.content)
                } else {
                    reveal.flush(turn.content)
                }
            }
            .onDisappear {
                reveal.stop()
            }
        }
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private var messageBubble: some View {
        // When assistant message is done streaming and contains quiz blocks, render segments
        if turn.role == .assistant && !turn.isStreaming && !reveal.isAnimating && hasQuizContent {
            quizSegmentedBubble
        } else {
            plainMessageBubble
        }
    }

    /// Whether the fully revealed content contains quiz XML blocks.
    private var hasQuizContent: Bool {
        turn.role == .assistant && QuizXMLParser.containsQuiz(turn.content)
    }

    /// `quiz_cards` tool calls — rendered as inline flashcard carousels.
    private var renderCardRecords: [ToolUseRecord] {
        turn.toolUses.filter { $0.name == "quiz_cards" }
    }

    /// All other tool calls — rendered via the generic tool-call summary.
    private var otherToolRecords: [ToolUseRecord] {
        turn.toolUses.filter { $0.name != "quiz_cards" }
    }

    /// Decode the flashcards carried in a `quiz_cards` tool call into a
    /// `QuizDeck` for carousel display. Cards arrive as a structured `cards`
    /// array once the tool call completes, or as a still-streaming raw
    /// tool-input buffer under `_partial` while the model is generating them.
    /// In the streaming case only fully-written card objects are rendered, so
    /// the carousel grows card-by-card.
    private static func decodeCardDeck(from record: ToolUseRecord) -> QuizDeck? {
        let cards: [QuizContent]
        if let cardValues = record.input.array("cards") {
            cards = cardValues.compactMap { QuizCardsTool.decodeCard($0) }
        } else if let partial = record.input["_partial"] {
            cards = cardsFromPartialJSON(partial)
        } else {
            return nil
        }

        guard !cards.isEmpty else { return nil }
        return QuizDeck(
            title: record.input["title"] ?? "",
            cards: cards
        )
    }

    /// Extract complete card objects from a still-streaming raw tool-input JSON
    /// buffer (e.g. `{"title":"…","cards":[{…},{…},{…`). Finds the `cards`
    /// array and pulls each balanced `{…}` object via brace counting (ignoring
    /// braces inside strings), skipping a trailing half-written one — so the
    /// carousel grows card-by-card.
    private static func cardsFromPartialJSON(_ raw: String) -> [QuizContent] {
        guard let keyRange = raw.range(of: "\"cards\"") else { return [] }
        let after = raw[keyRange.upperBound...]
        guard let openBracket = after.firstIndex(of: "[") else { return [] }

        let decoder = JSONDecoder()
        var cards: [QuizContent] = []
        var depth = 0
        var inString = false
        var escaped = false
        var buf = ""

        var i = after.index(after: openBracket)
        while i < after.endIndex {
            let c = after[i]
            defer { i = after.index(after: i) }

            if depth > 0 { buf.append(c) }

            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" {
                    if depth == 0 { buf = "{" }
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        if let data = buf.data(using: .utf8),
                           let card = try? decoder.decode(QuizContent.self, from: data) {
                            cards.append(card)
                        }
                        buf = ""
                    }
                } else if c == "]", depth == 0 {
                    break
                }
            }
        }
        return cards
    }

    /// `OpenURLAction` that intercepts `oak://` citation links and delegates
    /// to `onOpenCitation`. Non-oak URLs fall through to the system handler.
    private var citationOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            print("[Citation] openURL fired: \(url)")
            guard let (citeKey, anchor) = CitationAnchor.parse(from: url) else {
                print("[Citation] not an oak:// URL, falling through to system")
                return .systemAction
            }
            print("[Citation] parsed citeKey=\(citeKey) anchor=\(anchor)")
            onOpenCitation?(citeKey, anchor)
            return .handled
        }
    }

    /// True while this turn's text is still being revealed (network streaming
    /// or the local reveal animation).
    private var isRevealing: Bool {
        turn.isStreaming || reveal.isAnimating
    }

    /// Builds a `StructuredText` view with the shared chat styling applied.
    ///
    /// Math renders live (the `.math` extension stays on while streaming) so a
    /// formula appears the instant its closing `$`/`$$` arrives. We never *seal*
    /// incomplete math (see `sealIncompleteMarkdown`): Textual ignores an
    /// unclosed `$`, so a half-written formula stays literal text until it
    /// closes and Textual never lays out a malformed equation.
    ///
    /// Text *selection* is deferred until streaming settles. Textual's
    /// `AttachmentView` reads `@Environment(TextSelectionModel.self)` per
    /// attachment; with selection enabled the attachment overlay (a
    /// `GeometryReader` inside `overlayPreferenceValue(Text.LayoutKey)`) can
    /// enter a non-converging layout transaction that spins the main thread
    /// (frozen "white screen"), and the 60fps reveal makes it far worse.
    /// Selecting mid-stream text is pointless anyway.
    @ViewBuilder
    private func chatMarkdown(_ markdown: String, streaming: Bool = false) -> some View {
        // Native renderer (OakMarkdownUI): swift-markdown + Highlightr + SwiftMath,
        // block-stack with settled-block memoization + incremental tail editing —
        // the same native stack Dia uses. Replaces the Textual path.
        StreamingMarkdownView(
            markdown: markdown,
            theme: markdownTheme ?? .oak(fontSize: CGFloat(chatFontSize), lineHeightScale: CGFloat(chatLineHeightScale)),
            isStreaming: streaming,
            onOpenURL: { url in
                // Intercept oak:// citation links; let everything else open in the browser.
                guard let (citeKey, anchor) = CitationAnchor.parse(from: url) else { return false }
                onOpenCitation?(citeKey, anchor)
                return true
            },
            linkPreview: { url in
                // Hovering a citation shows the cited source instead of the raw oak:// URL.
                guard let (citeKey, anchor) = CitationAnchor.parse(from: url) else { return nil }
                return AnyView(CitationHoverCard(citeKey: citeKey, anchor: anchor))
            }
        )
    }

    /// Renders interleaved text segments, inline quiz views, and deck carousels.
    @ViewBuilder
    private var quizSegmentedBubble: some View {
        let segments = QuizXMLParser.parse(turn.content)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let markdown):
                    chatMarkdown(markdown)
                case .quiz(let content):
                    InlineQuizView(content: content, onSaveToDeck: onSaveQuizCard)
                case .deck(let deck):
                    InlineDeckView(deck: deck, onSaveCard: onSaveQuizCard)
                }
            }
        }
        .environment(\.openURL, citationOpenURLAction)
        .assistantBubbleStyle()
    }

    @ViewBuilder
    private var plainMessageBubble: some View {
        if turn.role == .assistant {
            chatMarkdown(renderedContent, streaming: isRevealing)
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
        let size = markdownTheme?.bodyFont.pointSize ?? CGFloat(chatFontSize)
        return Text(userAttributedContent)
            .font(.system(size: size))
            .textSelection(.enabled)
            .tint(.accentColor)
            .environment(\.openURL, citationOpenURLAction)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        // Sealing of incomplete markdown (`**bold` → `**bold**`) and math
        // backslash protection now happen per-block inside `ChatMarkdownBlockView`
        // — only the still-growing tail block is sealed, so we never re-scan the
        // whole message on every streaming commit.
        return reveal.displayedContent
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
        turn.role == .assistant && !turn.isStreaming && !reveal.isAnimating && !renderedContent.isEmpty
    }

    private var shouldShowMessageBubble: Bool {
        if turn.role == .assistant {
            // Skip the empty bubble for tool-only agentic turns (no text content).
            // While tools are executing the turn streams with empty content but
            // carries tool-use records — don't render a blank bubble for it.
            if !renderedContent.isEmpty { return true }
            return (turn.isStreaming || reveal.isAnimating) && turn.toolUses.isEmpty
        }
        return !renderedContent.isEmpty || !skillBadges.isEmpty || !referenceBadges.isEmpty
    }

    private func skillBadge(_ skillId: String) -> some View {
        let skill = SkillManager.shared.installedSkills.first {
            $0.id.caseInsensitiveCompare(skillId) == .orderedSame
                || $0.name.caseInsensitiveCompare(skillId) == .orderedSame
        }
        // Mirror the input composer's token chip (ChatTokenAttachment): a soft
        // accent fill + muted accent text, no border.
        let softAccent = Color(nsColor: NSColor.controlAccentColor
            .blended(withFraction: 0.5, of: .tertiaryLabelColor) ?? .controlAccentColor)
        return HStack(spacing: 3) {
            Image(systemName: skill?.icon ?? "sparkles")
                .font(OakStyle.ChatFont.modelLabel)
            Text(skillId)
                .font(OakStyle.ChatFont.modelLabel)
        }
        .foregroundStyle(softAccent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(softAccent.opacity(0.13))
        )
        .fixedSize()
    }

    private func referenceBadge(_ title: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(OakStyle.ChatFont.badge)
                .opacity(0.8)
            Text(title)
                .font(OakStyle.ChatFont.badge)
                .lineLimit(1)
        }
        .foregroundStyle(Color.orange)
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

// MARK: - Thinking Disclosure View

/// Collapsible section showing extended thinking content from reasoning models.
/// Collapsed by default. Shows elapsed time and a chevron toggle.
/// While streaming, displays a cursive "oak" handwriting stroke animation
/// alongside a "Thinking..." label.
private struct ThinkingDisclosureView: View {
    let thinking: String
    /// True while the model is still in the thinking phase (no text content yet).
    let isStreaming: Bool

    @State private var isExpanded = false
    @State private var streamStartTime = Date()
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?
    @State private var oakStrokeProgress: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    if !isStreaming {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    }

                    if isStreaming {
                        HStack(spacing: 6) {
                            OakScriptShape()
                                .trim(from: 0, to: oakStrokeProgress)
                                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 16)
                            Text("Thinking...")
                                .font(OakStyle.ChatFont.messageBody)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Thought for \(elapsedSeconds)s")
                            .font(OakStyle.ChatFont.messageBody)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)

            // Content
            if isExpanded {
                Text(thinking)
                    .font(OakStyle.ChatFont.messageBody)
                    .foregroundStyle(.secondary.opacity(0.75))
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .padding(.vertical, 4)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 2)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            streamStartTime = Date()
            if isStreaming {
                startTimer()
                oakStrokeProgress = 0
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    oakStrokeProgress = 1.0
                }
            } else {
                elapsedSeconds = max(1, thinking.count / 10)
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                stopTimer()
                elapsedSeconds = max(1, Int(Date().timeIntervalSince(streamStartTime)))
            }
        }
        .onDisappear {
            stopTimer()
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsedSeconds = Int(Date().timeIntervalSince(streamStartTime))
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - "oak" Script Shape
//
// A cursive script rendering of the word "oak" as a single continuous
// bezier path, designed for `.trim(from:to:)` stroke animation.

private struct OakScriptShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }

        // ── Letter 'o' ── (counterclockwise oval from near top)
        path.move(to: pt(0.15, 0.30))
        path.addCurve(to: pt(0.04, 0.55),
                      control1: pt(0.06, 0.28),
                      control2: pt(0.03, 0.40))
        path.addCurve(to: pt(0.15, 0.73),
                      control1: pt(0.05, 0.70),
                      control2: pt(0.09, 0.75))
        path.addCurve(to: pt(0.23, 0.45),
                      control1: pt(0.21, 0.71),
                      control2: pt(0.24, 0.60))
        path.addCurve(to: pt(0.27, 0.68),
                      control1: pt(0.22, 0.32),
                      control2: pt(0.25, 0.50))

        // ── Letter 'a' ── (bowl + stem)
        path.addCurve(to: pt(0.42, 0.28),
                      control1: pt(0.29, 0.50),
                      control2: pt(0.36, 0.28))
        path.addCurve(to: pt(0.32, 0.50),
                      control1: pt(0.48, 0.28),
                      control2: pt(0.30, 0.30))
        path.addCurve(to: pt(0.44, 0.72),
                      control1: pt(0.34, 0.68),
                      control2: pt(0.38, 0.74))
        path.addQuadCurve(to: pt(0.50, 0.68),
                          control: pt(0.48, 0.70))

        // ── Letter 'k' ── (ascender, loop back, upper arm, lower arm + flourish)
        path.addCurve(to: pt(0.56, 0.08),
                      control1: pt(0.50, 0.45),
                      control2: pt(0.53, 0.08))
        path.addCurve(to: pt(0.58, 0.45),
                      control1: pt(0.59, 0.12),
                      control2: pt(0.59, 0.32))
        path.addCurve(to: pt(0.78, 0.22),
                      control1: pt(0.58, 0.35),
                      control2: pt(0.70, 0.22))
        path.addCurve(to: pt(0.62, 0.50),
                      control1: pt(0.72, 0.28),
                      control2: pt(0.65, 0.42))
        path.addCurve(to: pt(0.90, 0.72),
                      control1: pt(0.66, 0.58),
                      control2: pt(0.82, 0.72))
        path.addCurve(to: pt(0.97, 0.62),
                      control1: pt(0.94, 0.72),
                      control2: pt(0.97, 0.68))

        return path
    }
}

// MARK: - Streaming Cursor (Spinning Grid with Glow)
//
// 3×3 dot grid where dots light up sequentially around the perimeter
// in a clockwise loop, each with a soft glow halo when active.
// Sequence: 0→1→2→5→8→7→6→3 (outer ring), center dot pulses gently.

/// A 9-dot "agent is working" indicator: a comet chases the outer ring while the
/// center dot pulses. Driven entirely by **Core Animation** (infinite
/// `CAKeyframeAnimation`/`CABasicAnimation` with staggered `beginTime`), so it runs on
/// the render server and stays smooth even while the main thread is saturated streaming
/// and re-laying-out markdown. The previous main-thread `Timer` driver stuttered under
/// that load. (Technique mirrors Dia's CADisplayLink/CAAnimation-driven loaders —
/// reimplemented from a read-only study of the shipped app, not copied.)
struct StreamingCursor: NSViewRepresentable {
    fileprivate static let dotSize: CGFloat = 2.5
    fileprivate static let spacing: CGFloat = 2.5
    fileprivate static let cycle: CFTimeInterval = 1.0
    // Perimeter traversal order (clockwise from top-left), as grid indices.
    fileprivate static let sequence: [Int] = [0, 1, 2, 5, 8, 7, 6, 3]
    fileprivate static var gridSize: CGFloat { dotSize * 3 + spacing * 2 }

    func makeNSView(context: Context) -> DotGridView { DotGridView() }
    func updateNSView(_ nsView: DotGridView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotGridView, context: Context) -> CGSize? {
        CGSize(width: Self.gridSize, height: Self.gridSize)
    }

    final class DotGridView: NSView {
        private var dots: [CALayer] = []

        override var intrinsicContentSize: NSSize {
            NSSize(width: StreamingCursor.gridSize, height: StreamingCursor.gridSize)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.isGeometryFlipped = true   // row 0 at the top, so the ring runs clockwise
            buildDots()
            layoutDots()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        override func layout() {
            super.layout()
            layoutDots()
        }

        // CA strips animations when a layer leaves the window; re-add on (re)attach.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { animate() }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColor()
        }

        private func buildDots() {
            dots = (0..<9).map { _ in
                let l = CALayer()
                l.cornerRadius = StreamingCursor.dotSize / 2
                l.opacity = 0.12
                layer?.addSublayer(l)
                return l
            }
            applyColor()
        }

        private func applyColor() {
            let cg = NSColor.labelColor.cgColor
            for d in dots { d.backgroundColor = cg }
        }

        private func layoutDots() {
            let d = StreamingCursor.dotSize, s = StreamingCursor.spacing
            for i in 0..<9 {
                let row = CGFloat(i / 3), col = CGFloat(i % 3)
                dots[i].frame = CGRect(x: col * (d + s), y: row * (d + s), width: d, height: d)
            }
        }

        private func animate() {
            guard let host = layer else { return }
            let cycle = StreamingCursor.cycle
            let seq = StreamingCursor.sequence
            let slot = cycle / Double(seq.count)
            let now = host.convertTime(CACurrentMediaTime(), from: nil)

            // Comet: a sharp head fading over two trailing dots, looping every `cycle`.
            // One shared opacity/scale curve per dot, phase-shifted via `beginTime`.
            let opKeyTimes: [NSNumber] = [0.0, 0.125, 0.25, 0.375, 0.875, 1.0]
            let opValues: [CGFloat] = [0.62, 0.40, 0.24, 0.12, 0.12, 0.62]
            let scValues: [CGFloat] = [1.0, 0.88, 0.78, 0.70, 0.70, 1.0]

            for (pos, gridIndex) in seq.enumerated() {
                let dot = dots[gridIndex]
                let begin = now + Double(pos) * slot - cycle   // staggered, already running

                let op = CAKeyframeAnimation(keyPath: "opacity")
                op.keyTimes = opKeyTimes
                op.values = opValues
                op.duration = cycle
                op.repeatCount = .infinity
                op.beginTime = begin
                op.isRemovedOnCompletion = false
                dot.add(op, forKey: "comet.opacity")

                let sc = CAKeyframeAnimation(keyPath: "transform.scale")
                sc.keyTimes = opKeyTimes
                sc.values = scValues
                sc.duration = cycle
                sc.repeatCount = .infinity
                sc.beginTime = begin
                sc.isRemovedOnCompletion = false
                dot.add(sc, forKey: "comet.scale")
            }

            // Center dot: a slow breathing pulse.
            let center = dots[4]
            let ease = CAMediaTimingFunction(name: .easeInEaseOut)
            let pulseOp = CABasicAnimation(keyPath: "opacity")
            pulseOp.fromValue = 0.15; pulseOp.toValue = 0.40
            pulseOp.duration = 0.8; pulseOp.autoreverses = true
            pulseOp.repeatCount = .infinity; pulseOp.timingFunction = ease
            pulseOp.isRemovedOnCompletion = false
            center.add(pulseOp, forKey: "pulse.opacity")

            let pulseSc = CABasicAnimation(keyPath: "transform.scale")
            pulseSc.fromValue = 0.9; pulseSc.toValue = 1.1
            pulseSc.duration = 0.8; pulseSc.autoreverses = true
            pulseSc.repeatCount = .infinity; pulseSc.timingFunction = ease
            pulseSc.isRemovedOnCompletion = false
            center.add(pulseSc, forKey: "pulse.scale")
        }
    }
}

// MARK: - Adaptive-CPS Stream Reveal Controller
//
// Inspired by Alma's useSmoothStreamContent. Instead of a fixed-rate timer
// that reveals one line per tick, this controller:
//   1. Tracks API token arrival rate via EMA (exponential moving average).
//   2. Renders at a rate ≤ arrival rate so the buffer never empties mid-stream.
//   3. Buffers an initial batch (~50 chars) before the first render to absorb
//      early arrival jitter.
//   4. When streaming ends, enters a "flush" phase that smoothly drains the
//      remaining buffer at 1.25× the observed arrival rate (max 4 seconds).
//
// The result is zero render stalls: the display never catches up to the API
// and then has to wait, producing the jarring "freeze → burst" pattern.

@Observable
private final class StreamRevealController {
    var displayedContent = ""
    var isAnimating = false

    // MARK: - Constants

    private static let minCPS: Double = 15
    private static let maxCPS: Double = 300
    private static let defaultCPS: Double = 50
    private static let emaAlpha: Double = 0.15
    private static let largeAppend = 500
    private static let flushMaxSeconds: Double = 4.0
    private static let flushSpeedup: Double = 1.25
    private static let minFlushCPS: Double = 18
    private static let maxFlushCPS: Double = 90
    private static let safetyBase: Double = 1.5
    private static let safetyIncrement: Double = 0.2

    // MARK: - State

    private var targetContent = ""
    private var displayedCount = 0
    private var targetCount = 0
    private var timer: Timer?
    private var lastFrameTime: TimeInterval = 0
    private var charAccum: Double = 0
    private var currentCPS: Double = 0

    // Arrival tracking
    private var emaCPS: Double = defaultCPS
    private var lastInputTime: TimeInterval = 0
    private var lastInputCount: Int = 0
    private var streamStartTime: TimeInterval = 0
    private var streamStartCount: Int = 0
    private var arrivalLog: [(time: TimeInterval, chars: Int)] = []
    private var maxGapMs: Double = 0
    private var stallCount: Int = 0

    // Phase
    private enum Phase { case idle, waiting, rendering, flushing }
    private var phase: Phase = .idle
    private var streaming = false
    private var wasRendering = false
    private var bufferEmptySince: TimeInterval = 0

    // MARK: - Public API

    /// Feed new target content from streaming deltas.
    func push(_ content: String) {
        let prev = targetContent
        if content == prev { return }

        // Content replaced (not appended) — sync immediately
        if !content.hasPrefix(prev) {
            syncImmediate(content)
            return
        }

        let appendedLength = content.count - prev.count

        // Very large append — skip animation
        if appendedLength > Self.largeAppend {
            syncImmediate(content)
            return
        }

        streaming = true
        targetContent = content
        targetCount = content.count

        let now = ProcessInfo.processInfo.systemUptime

        // Stall detection
        if lastInputTime > 0 {
            let gapMs = (now - lastInputTime) * 1000
            if gapMs > maxGapMs { maxGapMs = gapMs }
            if gapMs > 300 { stallCount += 1 }
        }

        // Arrival log (sliding 3-second window)
        arrivalLog.append((time: now, chars: appendedLength))
        let cutoff = now - 3.0
        while let first = arrivalLog.first, first.time < cutoff {
            arrivalLog.removeFirst()
        }

        // Stream start tracking
        if streamStartTime == 0 {
            streamStartTime = now
            streamStartCount = targetCount - appendedLength
        }

        // EMA arrival CPS
        let deltaChars = targetCount - lastInputCount
        let deltaTime = max(0.001, now - lastInputTime)
        if deltaChars > 0 && lastInputTime > 0 {
            let instantCPS = Double(deltaChars) / deltaTime
            let clamped = Self.clamp(instantCPS, Self.minCPS, Self.maxCPS * 2)
            emaCPS = emaCPS * (1 - Self.emaAlpha) + clamped * Self.emaAlpha
        }

        lastInputTime = now
        lastInputCount = targetCount
        startLoop()
    }

    /// Streaming ended — flush remaining buffer smoothly.
    func endStreaming(_ content: String) {
        streaming = false
        targetContent = content
        targetCount = content.count

        if displayedCount < targetCount {
            // Enter flushing phase to drain the backlog at accelerated rate
            charAccum = 0
            startLoop()
        } else {
            // Already caught up
            syncImmediate(content)
        }
    }

    /// Show all content immediately (non-streaming message / view appeared).
    func flush(_ content: String) {
        syncImmediate(content)
    }

    func stop() {
        stopTimer()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Loop

    private func startLoop() {
        if timer != nil { return }
        if targetCount > displayedCount {
            isAnimating = true
        }
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        lastFrameTime = 0
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Self.clamp(now - lastFrameTime, 0.001, 0.05)
        lastFrameTime = now

        let backlog = targetCount - displayedCount

        // Stream ended and no backlog — done
        if !streaming && backlog <= 0 {
            phase = .idle
            currentCPS = 0
            wasRendering = false
            bufferEmptySince = 0
            isAnimating = false
            stopTimer()
            return
        }

        // Buffer empty but still streaming — wait
        if backlog <= 0 {
            if wasRendering && bufferEmptySince == 0 {
                bufferEmptySince = now
            }
            wasRendering = false
            phase = .waiting
            currentCPS = 0
            return
        }

        bufferEmptySince = 0

        // --- Flushing phase (streaming ended, catch up smoothly) ---
        if !streaming {
            phase = .flushing

            var recentArrivalCPS = Self.defaultCPS
            if arrivalLog.count >= 2 {
                let windowTime = now - arrivalLog[0].time
                let windowChars = arrivalLog.reduce(0) { $0 + $1.chars }
                if windowTime > 0.05 {
                    recentArrivalCPS = Double(windowChars) / windowTime
                }
            }

            let naturalCPS = max(Self.minFlushCPS, recentArrivalCPS * Self.flushSpeedup)
            let catchUpCPS = Double(backlog) / Self.flushMaxSeconds
            let cps = Self.clamp(max(naturalCPS, catchUpCPS), Self.minFlushCPS, Self.maxFlushCPS)

            currentCPS = cps
            charAccum += cps * dt
            let chars = min(Int(charAccum), backlog)
            guard chars >= 1 else { return }
            charAccum -= Double(chars)

            advanceDisplay(by: chars)

            if displayedCount >= targetCount {
                phase = .idle
                currentCPS = 0
                isAnimating = false
                stopTimer()
            }
            return
        }

        // --- Initial buffering — absorb early jitter ---
        let elapsedSinceStart = streamStartTime > 0 ? now - streamStartTime : 0
        let neverRenderedYet = displayedCount <= streamStartCount
        let minInitialBuffer = max(50, Int(Self.minCPS * 2 * max(1, maxGapMs * 2 / 1000)))

        if streaming && neverRenderedYet && elapsedSinceStart < 5 && backlog < minInitialBuffer {
            phase = .waiting
            currentCPS = 0
            return
        }

        // --- Normal rendering — adaptive CPS ---
        var arrivalCPS: Double
        if arrivalLog.count >= 2 {
            let windowTime = now - arrivalLog[0].time
            let windowChars = arrivalLog.reduce(0) { $0 + $1.chars }
            arrivalCPS = windowTime > 0.05 ? Double(windowChars) / windowTime : Self.minCPS
        } else {
            arrivalCPS = Self.minCPS
        }

        let streamElapsed = streamStartTime > 0 ? now - streamStartTime : 0
        let charsReceived = targetCount - streamStartCount
        let effectiveCPS = streamElapsed > 1 && charsReceived > 10
            ? Double(charsReceived) / streamElapsed : arrivalCPS

        let maxGapS = max(0.5, maxGapMs / 1000)
        let safety = Self.safetyBase + Double(stallCount) * Self.safetyIncrement
        let safeCPS = Double(backlog) / (maxGapS * safety)
        let arrivalCap = min(arrivalCPS, effectiveCPS)
        let cps = Self.clamp(min(safeCPS, arrivalCap), Self.minCPS, Self.maxCPS)

        phase = .rendering
        currentCPS = cps
        wasRendering = true

        charAccum += cps * dt
        let chars = min(Int(charAccum), backlog)
        guard chars >= 1 else { return }
        charAccum -= Double(chars)

        advanceDisplay(by: chars)
    }

    // MARK: - Helpers

    /// Commit cadence throttle. `displayedContent` assignment triggers a full
    /// SwiftUI text re-layout (`TextLayoutManager.computeMetrics`), whose cost
    /// grows with text length. Committing at 60fps on a long message saturates
    /// the main thread → visible stutter/"white flash". So the character count
    /// still advances every 60fps tick (pacing unaffected), but the expensive
    /// published write backs off as the text grows. The final char always
    /// commits immediately so nothing is left un-rendered.
    private var lastCommitTime: TimeInterval = 0

    private static func commitInterval(forLength n: Int) -> TimeInterval {
        switch n {
        case ..<2_000: return 1.0 / 60.0   // short: smooth 60fps
        case ..<6_000: return 1.0 / 30.0   // medium: 30fps
        default:       return 1.0 / 15.0   // long: 15fps (layout is heavy)
        }
    }

    private func advanceDisplay(by chars: Int) {
        let newCount = min(displayedCount + chars, targetCount)
        displayedCount = newCount

        // Throttle the expensive commit; always commit the final character.
        let now = ProcessInfo.processInfo.systemUptime
        let reachedEnd = newCount >= targetCount
        guard reachedEnd || now - lastCommitTime >= Self.commitInterval(forLength: targetCount) else {
            return
        }
        lastCommitTime = now

        let target = targetContent
        let endIdx = target.index(target.startIndex, offsetBy: newCount)
        displayedContent = String(target[..<endIdx])
    }

    private func syncImmediate(_ content: String) {
        stopTimer()
        targetContent = content
        targetCount = content.count
        displayedCount = content.count
        displayedContent = content
        phase = .idle
        streaming = false
        isAnimating = false
        emaCPS = Self.defaultCPS
        currentCPS = 0
        lastInputTime = 0
        lastInputCount = content.count
        streamStartTime = 0
        streamStartCount = content.count
        arrivalLog = []
        stallCount = 0
        maxGapMs = 0
        wasRendering = false
        bufferEmptySince = 0
        charAccum = 0
        lastCommitTime = 0
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, value))
    }
}

// MARK: - Compact heading style for chat bubbles

struct ChatHeadingStyle: StructuredText.HeadingStyle {
    private static let fontScales: [CGFloat] = [1.3, 1.15, 1.05, 1.0, 0.9, 0.85]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(configuration.headingLevel, 6)
        let scale = Self.fontScales[level - 1]

        configuration.label
            .textual.fontScale(scale)
            .textual.lineSpacing(.fontScaled(0.1))
            .textual.blockSpacing(.fontScaled(top: 0.6, bottom: 0.3))
            .fontWeight(.semibold)
    }
}
