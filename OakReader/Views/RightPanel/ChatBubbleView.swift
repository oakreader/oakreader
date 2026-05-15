import SwiftUI
import OakAgent
import Textual

struct ChatBubbleView: View {
    let turn: Turn
    var onSaveToNote: ((Turn) -> Bool)?
    var onApproveToolCall: (() -> Void)?
    var onDenyToolCall: (() -> Void)?
    var onOpenCitation: ((String, CitationAnchor) -> Void)?

    @State private var isHovered = false
    @State private var isCopyHovered = false
    @State private var isSaveHovered = false
    @State private var showCopied = false
    @State private var showSaved = false
    @State private var showSaveFailed = false
    @State private var reveal = StreamRevealController()

    var body: some View {
        if turn.role == .system { return AnyView(EmptyView()) }

        return AnyView(
            HStack(alignment: .top) {
                if turn.role == .user { Spacer(minLength: 40) }

                VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 4) {
                    // Inline attachments for user messages
                    if turn.role == .user && !turn.attachments.isEmpty {
                        FannedAttachmentStack(attachments: turn.attachments)
                    }

                    // Tool call cards for assistant messages
                    if turn.role == .assistant && !turn.toolUses.isEmpty {
                        ForEach(turn.toolUses) { record in
                            ToolCallCardView(
                                record: record,
                                onApprove: record.status == .pending ? onApproveToolCall : nil,
                                onDeny: record.status == .pending ? onDenyToolCall : nil
                            )
                        }
                    }

                    // Message content
                    if shouldShowMessageBubble {
                        messageBubble
                    }

                    // Streaming cursor
                    if turn.isStreaming || reveal.isAnimating {
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

                    // Actions — visible after response and flush are done
                    if !turn.isStreaming && !reveal.isAnimating && turn.role == .assistant {
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

                            if onSaveToNote != nil {
                                actionButton(
                                    systemImage: saveIcon,
                                    foregroundStyle: saveColor,
                                    isHovered: isSaveHovered,
                                    tooltip: saveTooltip
                                ) {
                                    saveToNote()
                                }
                                .onHover { isSaveHovered = $0 }
                                .animation(.spring(duration: 0.25, bounce: 0.3), value: showSaved)
                                .animation(.spring(duration: 0.25, bounce: 0.3), value: showSaveFailed)
                                .animation(.spring(duration: 0.2, bounce: 0.2), value: isSaveHovered)
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
        )
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private var messageBubble: some View {
        let base = StructuredText(markdown: renderedContent, syntaxExtensions: [.math])
            .textual.headingStyle(ChatHeadingStyle())
            .textual.textSelection(.enabled)
            .font(OakStyle.ChatFont.messageBody)

        if turn.role == .assistant {
            base
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "oak" else { return .systemAction }

                    // Backward compat: oak://page/N → treat as current-doc page citation
                    if url.host == "page",
                       let pageStr = url.pathComponents.dropFirst().first,
                       let page = Int(pageStr) {
                        onOpenCitation?("", CitationAnchor(page: page - 1))
                        return .handled
                    }

                    if url.host == "cite",
                       let citeKey = url.pathComponents.dropFirst().first {
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        let queryItems = components?.queryItems ?? []

                        var anchor = CitationAnchor()
                        for item in queryItems {
                            switch item.name {
                            case "page":
                                if let v = item.value, let p = Int(v) { anchor.page = p - 1 }
                            case "heading":
                                anchor.heading = item.value?.removingPercentEncoding ?? item.value
                            case "time":
                                if let v = item.value, let t = Double(v) { anchor.time = t }
                            case "text":
                                anchor.text = item.value?.removingPercentEncoding ?? item.value
                            default:
                                break
                            }
                        }

                        onOpenCitation?(citeKey, anchor)
                        return .handled
                    }

                    return .systemAction
                })
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(bubbleColor)
                )
                .foregroundStyle(Color(nsColor: .labelColor))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ForEach(skillBadges, id: \.self) { skill in
                    skillBadge(skill)
                }
                ForEach(Array(referenceBadges.enumerated()), id: \.offset) { _, ref in
                    referenceBadge(ref.title, icon: ref.icon)
                }
                if !renderedContent.isEmpty {
                    base
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(bubbleColor)
            )
            .foregroundStyle(Color(nsColor: .labelColor))
        }
    }

    private var bubbleColor: Color {
        switch turn.role {
        case .user:
            return Color.accentColor.opacity(0.15)
        case .assistant, .system:
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    private var renderedContent: String {
        if turn.role == .user {
            let parsed = Self.extractLeadingSkillTags(from: turn.content)
            if !parsed.skillIds.isEmpty && parsed.content == "/" { return "" }
            let (_, stripped) = Self.extractReferencedDocuments(from: parsed.content)
            return stripped
        }
        let content = reveal.displayedContent
        // Seal incomplete markdown during streaming to prevent jitter.
        // Without this, `**bold` flips between literal and bold rendering
        // as the closing `**` arrives character by character.
        if turn.isStreaming || reveal.isAnimating {
            return protectMathBackslashes(sealIncompleteMarkdown(content))
        }
        return protectMathBackslashes(content)
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
            let title = xmlNS.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
            refs.append((title: title, icon: "doc.text"))
        }
        for match in refNotePattern.matches(in: xmlBlock, range: fullRange) {
            let title = xmlNS.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
            refs.append((title: title, icon: "note.text"))
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

    private var shouldShowMessageBubble: Bool {
        turn.role == .assistant || !renderedContent.isEmpty || !skillBadges.isEmpty || !referenceBadges.isEmpty
    }

    private func skillBadge(_ skillId: String) -> some View {
        let skill = SkillManager.shared.installedSkills.first {
            $0.id.caseInsensitiveCompare(skillId) == .orderedSame
                || $0.name.caseInsensitiveCompare(skillId) == .orderedSame
        }
        return HStack(spacing: 3) {
            Image(systemName: skill?.icon ?? "sparkles")
                .font(OakStyle.ChatFont.modelLabel)
                .opacity(0.8)
            Text(skillId)
                .font(OakStyle.ChatFont.modelLabel)
        }
        .foregroundStyle(Color.accentColor)
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

    private var saveIcon: String {
        if showSaved { return "checkmark" }
        if showSaveFailed { return "exclamationmark.triangle" }
        return "note.text.badge.plus"
    }

    private var saveColor: Color {
        if showSaved { return .green }
        if showSaveFailed { return .red }
        return .secondary
    }

    private var saveTooltip: String {
        if showSaved { return "Saved to Note" }
        if showSaveFailed { return "Could Not Save" }
        return "Save to Note"
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

    private func saveToNote() {
        guard let onSaveToNote else { return }
        if onSaveToNote(turn) {
            showSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showSaved = false
            }
        } else {
            showSaveFailed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showSaveFailed = false
            }
        }
    }

    // MARK: - Protect Math Backslashes

    // Regex: extract title from <doc> and <note> elements in <referenced-documents>
    // swiftlint:disable:next force_try
    private static let refDocPattern = try! NSRegularExpression(
        pattern: #"<doc\s[^>]*?title="([^"]*)"[^>]*/>"#
    )
    // swiftlint:disable:next force_try
    private static let refNotePattern = try! NSRegularExpression(
        pattern: #"<note\s[^>]*?title="([^"]*)"[^>]*/>"#
    )

    // Regex: display math $$...$$ (dotall) or inline math $...$ (no newlines)
    // swiftlint:disable:next force_try
    private static let mathPattern = try! NSRegularExpression(
        pattern: #"\$\$(.+?)\$\$|\$(?!\$)((?:\\\$|[^$\n])+)\$"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Doubles backslashes inside math delimiters (`$$…$$` and `$…$`) so they
    /// survive Foundation's markdown parser. Foundation treats `\\` as a valid
    /// CommonMark escape (producing `\`), destroying LaTeX line breaks and
    /// literal braces before Textual's math regex ever sees them.
    private func protectMathBackslashes(_ text: String) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0

        Self.mathPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let fullRange = match.range

            // Append text before this match
            result += ns.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))

            // Determine which group matched: group 1 = $$, group 2 = $
            let isBlock = match.range(at: 1).location != NSNotFound
            let contentRange = match.range(at: isBlock ? 1 : 2)
            let content = ns.substring(with: contentRange)
            let protected = content.replacingOccurrences(of: "\\", with: "\\\\")

            result += isBlock ? "$$\(protected)$$" : "$\(protected)$"
            cursor = fullRange.location + fullRange.length
        }

        // Append remaining text after last match
        result += ns.substring(from: cursor)
        return result
    }

    // MARK: - Seal Incomplete Markdown (Streamdown)

    /// Closes unmatched markdown markers in streaming content to prevent jitter.
    /// When the model streams `**bold`, the unclosed `**` causes the parser to
    /// alternate between literal and bold rendering. By appending the missing
    /// closing markers, the parser renders consistently on every frame.
    ///
    /// Pipeline order matters — process from most specific to least specific:
    /// code fences → inline code → bold+italic → bold → italic → strikethrough → math
    private func sealIncompleteMarkdown(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var s = text

        // 1. Code fences — if odd count of ```, close the fence.
        //    Everything inside a code fence is literal, so return early.
        if s.countNonOverlapping("```") % 2 == 1 {
            if !s.hasSuffix("\n") { s += "\n" }
            s += "```"
            return s
        }

        // 2. Inline code — count single backticks (not part of ```).
        //    If odd, close it and return (markers inside code spans are literal).
        let withoutFences = s.replacingOccurrences(of: "```", with: "   ")
        if withoutFences.filter({ $0 == "`" }).count % 2 == 1 {
            s += "`"
            return s
        }

        // 3. Bold+italic *** (must check before ** and *)
        let tripleStarCount = s.countNonOverlapping("***")
        if tripleStarCount % 2 == 1 {
            s += "***"
            return s
        }

        // 4. Bold ** (count ** that aren't part of ***)
        let withoutTriple = s.replacingOccurrences(of: "***", with: "   ")
        if withoutTriple.countNonOverlapping("**") % 2 == 1 {
            s += "**"
        }

        // 5. Italic * (single *, not part of ** or ***)
        let withoutDouble = withoutTriple.replacingOccurrences(of: "**", with: "  ")
        if withoutDouble.filter({ $0 == "*" }).count % 2 == 1 {
            s += "*"
        }

        // 6. Strikethrough ~~
        if s.countNonOverlapping("~~") % 2 == 1 {
            s += "~~"
        }

        // 7. Math $$ — display math requires $$ on its own line.
        //    If the unclosed $$ has a newline after it (block math), close
        //    with \n$$ so the parser sees a proper display block.
        if s.countNonOverlapping("$$") % 2 == 1 {
            // Find the last (unclosed) $$
            if let lastDollar = s.range(of: "$$", options: .backwards) {
                let afterDollar = s[lastDollar.upperBound...]
                if afterDollar.contains("\n") {
                    // Block math — close on a new line
                    if !s.hasSuffix("\n") { s += "\n" }
                    s += "$$"
                } else {
                    // Inline-style $$ — close on same line
                    s += "$$"
                }
            }
        }

        return s
    }
}

// MARK: - String extension for non-overlapping pattern counting

private extension String {
    /// Counts non-overlapping occurrences of `pattern` in the string.
    func countNonOverlapping(_ pattern: String) -> Int {
        var count = 0
        var searchRange = startIndex..<endIndex
        while let range = range(of: pattern, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<endIndex
        }
        return count
    }
}

// MARK: - Streaming Cursor (Waveform bars inspired by Bridge)
//
// Five vertical bars with staggered pulse animations, creating a
// rippling "thinking" indicator that feels alive without being distracting.

private struct StreamingCursor: View {
    private static let barCount = 5
    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 2
    private static let minHeight: CGFloat = 3
    private static let maxHeight: CGFloat = OakStyle.ChatFont.streamingBarHeight
    private static let cycleDuration: Double = 1.2

    @State private var animating = false

    var body: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: Self.barWidth, height: barHeight(for: index))
                    .opacity(barOpacity(for: index))
            }
        }
        .frame(height: Self.maxHeight)
        .animation(
            .easeInOut(duration: Self.cycleDuration).repeatForever(autoreverses: true),
            value: animating
        )
        .onAppear { animating = true }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let phase = Double(index) / Double(Self.barCount)
        let base = animating ? 1.0 : phase
        // Stagger: middle bars are tallest when animating
        let center = Double(Self.barCount - 1) / 2.0
        let proximity = 1.0 - abs(Double(index) - center) / center
        let height = animating
            ? Self.minHeight + (Self.maxHeight - Self.minHeight) * proximity
            : Self.minHeight + (Self.maxHeight - Self.minHeight) * (1.0 - proximity) * 0.5
        return max(Self.minHeight, height * (animating ? (0.6 + 0.4 * base) : 0.5))
    }

    private func barOpacity(for index: Int) -> Double {
        animating ? (0.5 + 0.5 * (Double(index) / Double(Self.barCount - 1))) : 0.3
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

    private func advanceDisplay(by chars: Int) {
        let target = targetContent
        let newCount = min(displayedCount + chars, targetCount)
        let endIdx = target.index(target.startIndex, offsetBy: newCount)
        displayedContent = String(target[..<endIdx])
        displayedCount = newCount
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
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, value))
    }
}

// MARK: - Compact heading style for chat bubbles

private struct ChatHeadingStyle: StructuredText.HeadingStyle {
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
