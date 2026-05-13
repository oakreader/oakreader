import SwiftUI
import OakAgent
import Textual

struct ChatBubbleView: View {
    let turn: Turn
    var onSaveToNote: ((Turn) -> Bool)?
    var onApproveToolCall: (() -> Void)?
    var onDenyToolCall: (() -> Void)?

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
                if turn.role == .user && characterAgentInput == nil { Spacer(minLength: 40) }

                VStack(alignment: turn.role == .user && characterAgentInput == nil ? .trailing : .leading, spacing: 4) {
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

                    // Streaming indicator
                    if turn.isStreaming {
                        GridSpinner()
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

                    // Actions — always visible after response is done
                    if !turn.isStreaming && turn.role == .assistant {
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
                            .animation(.easeInOut(duration: 0.15), value: showCopied)
                            .animation(.easeInOut(duration: 0.15), value: isCopyHovered)

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
                                .animation(.easeInOut(duration: 0.15), value: showSaved)
                                .animation(.easeInOut(duration: 0.15), value: showSaveFailed)
                                .animation(.easeInOut(duration: 0.15), value: isSaveHovered)
                            }
                        }
                    }
                }

                if turn.role == .assistant || characterAgentInput != nil { Spacer(minLength: 4) }
            }
            .clipped()
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onChange(of: turn.content) { _, newContent in
                if turn.isStreaming && turn.role == .assistant {
                    reveal.push(newContent)
                } else {
                    reveal.flush(newContent)
                }
            }
            .onChange(of: turn.isStreaming) { _, streaming in
                if !streaming {
                    reveal.flush(turn.content)
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
            .font(.body)

        if let characterAgentInput {
            characterAgentCard(characterAgentInput)
        } else if turn.role == .assistant {
            base
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

    private var characterAgentInput: CharacterAgentInput? {
        guard turn.role == .user else { return nil }
        return Self.parseCharacterAgentInput(from: turn.content)
    }

    private var renderedContent: String {
        if turn.role == .user {
            if let characterAgentInput { return characterAgentInput.body }
            let parsed = Self.extractLeadingSkillTags(from: turn.content)
            if !parsed.skillIds.isEmpty && parsed.content == "/" { return "" }
            return parsed.content
        }
        return reveal.displayedContent
    }

    private var skillBadges: [String] {
        guard turn.role == .user, characterAgentInput == nil else { return [] }
        let parsed = Self.extractLeadingSkillTags(from: turn.content)
        if !parsed.skillIds.isEmpty { return parsed.skillIds }
        if let skill = turn.metadata["skill"] { return [skill] }
        return []
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
        characterAgentInput != nil || turn.role == .assistant || !renderedContent.isEmpty || !skillBadges.isEmpty
    }

    private func characterAgentCard(_ input: CharacterAgentInput) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: input.icon ?? "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(input.agentName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("CharacterAgent input")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            StructuredText(markdown: input.body, syntaxExtensions: [.math])
                .textual.headingStyle(ChatHeadingStyle())
                .textual.textSelection(.enabled)
                .font(.body)
                .foregroundStyle(Color(nsColor: .labelColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
    }

    private func skillBadge(_ skill: String) -> some View {
        Text(skill)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
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
                .font(.system(size: 12))
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

    private struct CharacterAgentInput {
        let agentId: String?
        let agentName: String
        let icon: String?
        let threadId: String?
        let jsonlPath: String?
        let body: String
    }

    private static func parseCharacterAgentInput(from content: String) -> CharacterAgentInput? {
        let startMarker = "<character-agent-input"
        let endMarker = "</character-agent-input>"
        guard let startRange = content.range(of: startMarker),
              let tagClose = content[startRange.upperBound...].firstIndex(of: ">")
        else { return nil }

        let bodyStart = content.index(after: tagClose)
        guard let endRange = content.range(of: endMarker, range: bodyStart..<content.endIndex) else { return nil }

        let tag = String(content[startRange.lowerBound...tagClose])
        let body = String(content[bodyStart..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        let agentId = xmlAttribute("agent_id", in: tag)
        let agentName = xmlAttribute("agent_name", in: tag) ?? agentId ?? "CharacterAgent"
        return CharacterAgentInput(
            agentId: agentId,
            agentName: agentName,
            icon: xmlAttribute("icon", in: tag),
            threadId: xmlAttribute("thread_id", in: tag),
            jsonlPath: xmlAttribute("jsonl_path", in: tag),
            body: body
        )
    }

    private static func xmlAttribute(_ name: String, in tag: String) -> String? {
        let marker = name + "=\""
        guard let start = tag.range(of: marker) else { return nil }
        let valueStart = start.upperBound
        guard let valueEnd = tag[valueStart...].firstIndex(of: "\"") else { return nil }
        return unescapeXML(String(tag[valueStart..<valueEnd]))
    }

    private static func unescapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
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
}

// MARK: - Stream Reveal Controller

/// Reference-type controller that smoothly reveals streaming text line-by-line.
/// Timer captures `self` by reference, so it always sees the latest target.
@Observable
private final class StreamRevealController {
    var displayedContent = ""

    private var targetContent = ""
    private var cursorOffset = 0 // character offset into targetContent
    private var timer: Timer?

    /// Feed new target content from streaming deltas.
    func push(_ content: String) {
        targetContent = content
        if timer == nil {
            startTimer()
        }
    }

    /// Show all content immediately (streaming ended or non-streaming message).
    func flush(_ content: String) {
        stopTimer()
        targetContent = content
        cursorOffset = content.count
        displayedContent = content
    }

    func stop() {
        stopTimer()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Timer

    /// ~30 fps — enough for smooth feel without burning CPU on markdown re-parse.
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let target = targetContent
        guard cursorOffset < target.count else { return }

        // Advance to the next newline boundary (reveal one line per tick).
        // If no newline found, reveal a chunk of characters instead.
        let startIdx = target.index(target.startIndex, offsetBy: cursorOffset)
        let remaining = target[startIdx...]

        var newOffset: Int
        if let nlIdx = remaining.firstIndex(of: "\n") {
            // Reveal up to and including the newline
            newOffset = target.distance(from: target.startIndex, to: target.index(after: nlIdx))
        } else {
            // No newline yet — reveal a small chunk (partial line arriving)
            let gap = target.count - cursorOffset
            let step = max(min(gap, 8), 1)
            newOffset = min(cursorOffset + step, target.count)
        }

        cursorOffset = newOffset
        let endIdx = target.index(target.startIndex, offsetBy: cursorOffset)
        displayedContent = String(target[..<endIdx])
    }
}

// MARK: - Grid Spinner (3×3, outer ring cycles clockwise)

private struct GridSpinner: View {
    @State private var active = 0

    /// Clockwise order of the 8 outer cells: (row, col)
    private static let ring: [(Int, Int)] = [
        (0, 0), (0, 1), (0, 2),
        (1, 2),
        (2, 2), (2, 1), (2, 0),
        (1, 0),
    ]

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in
                        cell(row: row, col: col)
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            active = (active + 1) % Self.ring.count
        }
    }

    private func cell(row: Int, col: Int) -> some View {
        let size: CGFloat = 3
        let opacity = cellOpacity(row: row, col: col)

        return RoundedRectangle(cornerRadius: 0.5)
            .fill(Color.secondary)
            .opacity(opacity)
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.15), value: active)
    }

    private func cellOpacity(row: Int, col: Int) -> Double {
        // Center cell: always dim
        if row == 1 && col == 1 { return 0.1 }

        guard let idx = Self.ring.firstIndex(where: { $0.0 == row && $0.1 == col }) else {
            return 0.1
        }

        let distance = (idx - active + Self.ring.count) % Self.ring.count
        // Active cell + 2 trailing cells form a fading tail
        switch distance {
        case 0: return 1.0
        case 1: return 0.55
        case 2: return 0.3
        default: return 0.1
        }
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
