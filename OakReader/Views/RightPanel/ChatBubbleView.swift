import SwiftUI
import AppKit
import OakAgent
import OakMarkdownUI

/// Display metadata for a cited source, resolved from a citeKey by the host.
struct ChatSourceMeta {
    let title: String
    let icon: String
    /// Only PDFs have pages — used to gate the `p.N` badge so a stray page anchor
    /// on a pageless source (HTML / live web) never renders a misleading page chip.
    let contentType: ContentType
}

struct ChatBubbleView: View, Equatable {
    let turn: Turn
    var onPlayAudio: ((Turn) -> Void)?
    var isPlayingAudio: Bool = false
    var onStopAudio: (() -> Void)?
    var onOpenCitation: ((String, CitationAnchor) -> Void)?
    /// Resolves a citeKey to its display metadata (title + icon) for the per-answer
    /// Sources footer. Supplied by the host (which owns the library store). Returns
    /// nil for unknown keys, in which case the citeKey itself is shown.
    var resolveSource: ((String) -> ChatSourceMeta?)?
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
                                InlineDeckView(deck: deck, onOpenCitation: onOpenCitation)
                            }
                        }
                    }

                    // Message content
                    if shouldShowMessageBubble {
                        messageBubble
                    }

                    // Per-answer Sources footer — the documents this reply cited,
                    // each a chip that jumps to the exact passage. Shown only once
                    // the answer has settled (parsed from its oak://cite links).
                    if turn.role == .assistant && !isRevealing {
                        let sources = citedSources
                        if !sources.isEmpty {
                            sourcesFooter(sources)
                        }
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
                // Reduce Motion: skip the typewriter reveal, show text as it lands.
                if turn.isStreaming && turn.role == .assistant && !reduceMotion {
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
                if turn.isStreaming && turn.role == .assistant && !reduceMotion {
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
            guard let (citeKey, anchor) = CitationAnchor.parse(from: url) else {
                return .systemAction
            }
            onOpenCitation?(citeKey, anchor)
            return .handled
        }
    }

    /// True while this turn's text is still being revealed (network streaming
    /// or the local reveal animation).
    private var isRevealing: Bool {
        turn.isStreaming || reveal.isAnimating
    }

    // MARK: - Sources footer

    /// One source referenced by this answer, aggregated from its `oak://cite` links.
    struct CitedSource: Identifiable {
        let citeKey: String
        let title: String
        let icon: String
        let isPaged: Bool           // PDFs only — gates the `p.N` badge
        let pages: [Int]            // 1-based, for display
        let anchor: CitationAnchor  // representative anchor for the jump
        var id: String { citeKey }
    }

    /// The distinct sources this answer cites, in first-mention order.
    private var citedSources: [CitedSource] {
        Self.parseCitedSources(from: turn.content, resolve: resolveSource)
    }

    /// Low-key "Sources" strip under an answer: a wrapped row of jump chips.
    @ViewBuilder
    private func sourcesFooter(_ sources: [CitedSource]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            Text("Sources")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            FlowLayout(spacing: 6) {
                ForEach(sources) { source in
                    sourceChip(source)
                }
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceChip(_ source: CitedSource) -> some View {
        Button {
            onOpenCitation?(source.citeKey, source.anchor)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: source.icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(source.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if source.isPaged, let page = source.pages.first {
                    Text("p.\(page)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Jump to \(source.title)")
    }

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

    /// Parse `oak://cite/{citeKey}?page=&text=` links out of answer markdown and
    /// aggregate them per source: title/icon (via `resolve`), the set of cited
    /// pages, and a representative anchor (first, preferring one with a page).
    static func parseCitedSources(
        from content: String,
        resolve: ((String) -> ChatSourceMeta?)?
    ) -> [CitedSource] {
        guard content.contains("oak://cite/"),
              let regex = try? NSRegularExpression(
                pattern: "oak://cite/[A-Za-z0-9_.:\\-]+(?:\\?[^)\\s\\]\"'<>]*)?")
        else { return [] }

        let ns = content as NSString
        var order: [String] = []
        var pages: [String: [Int]] = [:]
        var anchors: [String: CitationAnchor] = [:]

        for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let urlString = ns.substring(with: match.range)
            guard let url = URL(string: urlString),
                  let (citeKey, anchor) = CitationAnchor.parse(from: url),
                  !citeKey.isEmpty else { continue }

            if anchors[citeKey] == nil {
                order.append(citeKey)
                anchors[citeKey] = anchor
                pages[citeKey] = []
            }
            // Prefer an anchor that can actually navigate (has a page/heading/text).
            if anchors[citeKey]?.page == nil, anchor.page != nil {
                anchors[citeKey] = anchor
            }
            if let page = anchor.page {
                let display = page + 1  // anchor.page is 0-based
                if !(pages[citeKey]?.contains(display) ?? false) {
                    pages[citeKey]?.append(display)
                }
            }
        }

        return order.map { key in
            let meta = resolve?(key)
            return CitedSource(
                citeKey: key,
                title: meta?.title ?? key,
                icon: meta?.icon ?? "doc",
                isPaged: meta?.contentType == .pdf,
                pages: (pages[key] ?? []).sorted(),
                anchor: anchors[key] ?? CitationAnchor()
            )
        }
    }

    /// Renders chat markdown via the native `StreamingMarkdownView` (OakMarkdownUI).
    ///
    /// It splits the (growing) markdown into fence-aware blocks and re-renders only the
    /// trailing block while streaming. Incomplete math/markup needs no sealing — a
    /// half-written `$…` or `**…` just stays literal until its closing delimiter arrives.
    /// Text selection is disabled while `streaming` (a settled, selectable block is only
    /// produced once the turn stops growing).
    @ViewBuilder
    private func chatMarkdown(_ markdown: String, streaming: Bool = false) -> some View {
        // Native renderer (OakMarkdownUI): swift-markdown + Highlightr + SwiftMath,
        // block-stack with settled-block memoization + incremental tail editing —
        // the same native stack Dia uses. This is the app's sole markdown renderer.
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
            linkPreview: { url, label in
                // Hovering a citation shows the cited source instead of the raw oak:// URL.
                guard let (citeKey, anchor) = CitationAnchor.parse(from: url) else { return nil }
                // Skip the card when it would only echo the link's own visible text.
                // Web citations often inline the quote itself as the label, so a card
                // repeating that quote adds nothing; a page/heading/timestamp still does.
                guard Self.citationCardAddsInfo(anchor, label: label) else { return nil }
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
                    InlineQuizView(content: content, onOpenCitation: onOpenCitation)
                case .deck(let deck):
                    InlineDeckView(deck: deck, onOpenCitation: onOpenCitation)
                }
            }
        }
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
        // No sealing/backslash protection needed: StreamingMarkdownView renders
        // partial markdown as-is (unclosed markers stay literal) and handles math
        // via its own block splitter, so we just hand it the raw revealed content.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                if reduceMotion {
                    // Reduce Motion: show the full stroke, no repeating draw-on.
                    oakStrokeProgress = 1.0
                } else {
                    oakStrokeProgress = 0
                    withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                        oakStrokeProgress = 1.0
                    }
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

// MARK: - Streaming Cursor (Three-Dot Wave)
//
// Three dots in a row, each doing a small staggered vertical bob with a coupled
// opacity lift — Dia's gentle "typing" wobble. Driven entirely by **Core
// Animation** (infinite `CAKeyframeAnimation` with staggered `beginTime`), so it
// runs on the render server and stays smooth even while the main thread is
// saturated streaming + re-laying-out markdown — a main-thread `Timer` driver
// stutters under that load. Honors Reduce Motion (static dots). Reimplemented
// from a read-only study of the shipped app, not copied.
struct StreamingCursor: NSViewRepresentable {
    fileprivate static let dotSize: CGFloat = 5.0
    fileprivate static let gap: CGFloat = 4.5
    fileprivate static let amplitude: CGFloat = 3.0
    fileprivate static let cycle: CFTimeInterval = 1.2
    fileprivate static let count = 3
    fileprivate static var contentWidth: CGFloat { dotSize * CGFloat(count) + gap * CGFloat(count - 1) }
    fileprivate static var contentHeight: CGFloat { dotSize + amplitude * 2 }

    func makeNSView(context: Context) -> DotRowView { DotRowView() }
    func updateNSView(_ nsView: DotRowView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotRowView, context: Context) -> CGSize? {
        CGSize(width: Self.contentWidth, height: Self.contentHeight)
    }

    final class DotRowView: NSView {
        private var dots: [CALayer] = []

        override var intrinsicContentSize: NSSize {
            NSSize(width: StreamingCursor.contentWidth, height: StreamingCursor.contentHeight)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            buildDots()
            layoutDots()
            // Re-evaluate when the user toggles "Reduce Motion" mid-session.
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(reduceMotionChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

        @objc private func reduceMotionChanged() {
            if window != nil { animate() }
        }

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
            dots = (0..<StreamingCursor.count).map { _ in
                let l = CALayer()
                l.cornerRadius = StreamingCursor.dotSize / 2
                l.opacity = 0.35
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
            let d = StreamingCursor.dotSize, g = StreamingCursor.gap
            let y = (bounds.height - d) / 2   // rest at vertical center; bob room above
            for i in 0..<dots.count {
                dots[i].frame = CGRect(x: CGFloat(i) * (d + g), y: y, width: d, height: d)
            }
        }

        private func animate() {
            guard let host = layer else { return }

            // Reduce Motion: no bobbing — quiet, evenly-dimmed dots.
            dots.forEach { $0.removeAllAnimations() }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for d in dots {
                    d.opacity = 0.35
                    d.transform = CATransform3DIdentity
                }
                return
            }

            let cycle = StreamingCursor.cycle
            let amp = StreamingCursor.amplitude
            let now = host.convertTime(CACurrentMediaTime(), from: nil)
            let stagger = cycle / Double(dots.count)   // each dot trails the last by a third
            let ease = CAMediaTimingFunction(name: .easeInEaseOut)
            let keyTimes: [NSNumber] = [0.0, 0.5, 1.0]

            for (i, dot) in dots.enumerated() {
                let begin = now + Double(i) * stagger - cycle   // staggered, already mid-loop

                let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
                bob.values = [0, amp, 0]
                bob.keyTimes = keyTimes
                bob.timingFunctions = [ease, ease]
                bob.duration = cycle
                bob.repeatCount = .infinity
                bob.beginTime = begin
                bob.isRemovedOnCompletion = false
                dot.add(bob, forKey: "wobble.y")

                let op = CAKeyframeAnimation(keyPath: "opacity")
                op.values = [0.35, 0.70, 0.35]
                op.keyTimes = keyTimes
                op.timingFunctions = [ease, ease]
                op.duration = cycle
                op.repeatCount = .infinity
                op.beginTime = begin
                op.isRemovedOnCompletion = false
                dot.add(op, forKey: "wobble.opacity")
            }
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

