import SwiftUI
import AppKit
import OakAgent
import OakMarkdownUI

struct ChatBubbleView: View, Equatable {
    let turn: Turn
    var onPlayAudio: ((Turn) -> Void)?
    var isPlayingAudio: Bool = false
    var onStopAudio: (() -> Void)?
    var onOpenCitation: ((String, CitationAnchor) -> Void)?
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

                    // Tool call cards for assistant messages — rendered via the
                    // generic collapsible tool-call summary.
                    if turn.role == .assistant && !turn.toolUses.isEmpty {
                        ToolCallGroupView(records: turn.toolUses)
                    }

                    // Message content
                    if shouldShowMessageBubble {
                        messageBubble
                    }

                    // Streaming cursor — only while text is streaming, not while a
                    // tool-only turn is executing (the tool-call shimmer covers that).
                    if turn.isStreaming && shouldShowMessageBubble {
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
        }
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private var messageBubble: some View {
        plainMessageBubble
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

    /// True while this turn's text is still streaming in. (The per-glyph fade-in
    /// finishes on its own ~0.2s after the last delta; we don't gate UI on it.)
    private var isRevealing: Bool {
        turn.isStreaming
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
            theme: markdownTheme ?? .oak(fontSize: CGFloat(chatFontSize), lineHeightScale: CGFloat(chatLineHeightScale)),
            isStreaming: streaming,
            fadesAppendedText: fadesAppendedText,
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
        // Hand the renderer the full content as it streams. The reveal animation is
        // now a glyph fade-in inside the text view (Dia's model), not a typewriter
        // prefix — so there's no truncation here. No sealing/backslash protection
        // needed: StreamingMarkdownView renders partial markdown as-is (unclosed
        // markers stay literal) and handles math via its own block splitter.
        return turn.content
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

