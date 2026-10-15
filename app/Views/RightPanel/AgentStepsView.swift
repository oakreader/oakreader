import AppKit
import OakMarkdownUI
import SwiftUI

// MARK: - What the chat shows between a question and its answer

/// One thing the agent did: thought, said a short aside, or called a tool.
enum AgentStep: Identifiable {
    case thinking(id: String, text: String, seconds: Double?, isLive: Bool)
    case note(id: String, text: String)
    case tool(ToolUseRecord)

    var id: String {
        switch self {
        case .thinking(let id, _, _, _), .note(let id, _): return id
        case .tool(let record): return record.id
        }
    }
}

/// A row in the chat list: a message bubble, or a group of agent steps.
enum ChatDisplayItem: Identifiable {
    case turn(Turn)
    case steps(id: String, steps: [AgentStep], isLive: Bool)

    var id: String {
        switch self {
        case .turn(let turn): return turn.id.uuidString
        case .steps(let id, _, _): return id
        }
    }

    /// Merge each run of agent iterations into one step group.
    ///
    /// Every iteration of the agent loop is its own assistant turn, so a
    /// three-step run used to stack as "Thought briefly / Listed items /
    /// Thought briefly / Listed 2 lists / Thought for 1s". Cursor's
    /// `step-grouping.js` folds them: thinking and tool calls join the open
    /// group, and so does a short aside (one line, 100 characters or less)
    /// said before a tool call. Any other text is an answer: it closes the
    /// group and shows as a normal bubble.
    static func build(from turns: [Turn], isStreaming: Bool) -> [ChatDisplayItem] {
        var items: [ChatDisplayItem] = []
        var pending: [AgentStep] = []
        var groupID: String?

        func add(_ step: AgentStep, from turn: Turn) {
            if groupID == nil { groupID = "steps-\(turn.id.uuidString)" }
            pending.append(step)
        }
        func flush() {
            if let id = groupID, !pending.isEmpty {
                items.append(.steps(id: id, steps: pending, isLive: false))
            }
            pending = []
            groupID = nil
        }

        for turn in turns {
            guard turn.role == .assistant else {
                flush()
                items.append(.turn(turn))
                continue
            }
            if let thinking = turn.thinking, !thinking.isEmpty {
                let live = turn.isStreaming && turn.thinkingSeconds == nil
                    && turn.content.isEmpty && turn.toolUses.isEmpty
                add(.thinking(id: "thinking-\(turn.id.uuidString)", text: thinking,
                              seconds: turn.thinkingSeconds, isLive: live), from: turn)
            }
            let text = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if !turn.toolUses.isEmpty, text.count <= 100, !text.contains("\n") {
                    add(.note(id: "note-\(turn.id.uuidString)", text: text), from: turn)
                } else {
                    flush()
                    items.append(.turn(turn))
                }
            } else if turn.error != nil {
                flush()
                items.append(.turn(turn))
            }
            for record in turn.toolUses { add(.tool(record), from: turn) }
        }
        flush()

        // The newest group stays live for the whole run, including the gaps
        // between iterations, so its label does not flicker to a summary.
        if isStreaming, case .steps(let id, let steps, _)? = items.last {
            items[items.count - 1] = .steps(id: id, steps: steps, isLive: true)
        }
        return items
    }
}

/// The steps of one agent run, after Cursor 3.17's agent panel.
///
/// - **Live:** one shimmering label naming the current step, over a window
///   that follows the newest step. Live thinking shows its text there; a tool
///   call shows as soon as the model starts writing it.
/// - **Done:** one summary line ("Listed collections and tags, read 3
///   documents"). Opened, it lists the thinking and tool steps in order; each
///   opens to its text or output.
struct AgentStepsView: View {
    let steps: [AgentStep]
    let isLive: Bool
    /// The bubble's markdown theme, for the thinking text.
    var theme: MarkdownTheme = .oak()

    @State private var isExpanded = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if isLive {
                TailWindow {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(steps) { liveRow($0) }
                    }
                    // Same left edge as the header label and the answer text.
                    .padding(.leading, 4)
                }
                .transition(.chatReveal)
            } else if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let thinking = onlyThinking {
                        // The header already says "Thought for 4s"; a row
                        // repeating it would be the same line twice.
                        StreamingMarkdownView(markdown: thinking,
                                              theme: ThinkingStepRow.muted(theme),
                                              isStreaming: false)
                    } else {
                        ForEach(steps) { doneRow($0) }
                    }
                }
                .padding(.leading, 10)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 2)
                        .padding(.leading, 4)
                }
                .transition(.chatReveal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Nothing of the group may draw outside its own frame.
        .clipped()
        .animation(.chatDisclosure, value: isLive)
        .animation(.chatDisclosure, value: isExpanded)
    }

    // MARK: Header

    private var header: some View {
        Button {
            guard !isLive else { return }
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                if isLive {
                    // ChatGPT leads its live reasoning label with the same
                    // breathing dot it shows while writing
                    // (`usesPulsingDotForCoTV5Thinking`).
                    StreamingCursor()
                        .padding(.trailing, 4)
                    ShimmerText(text: liveLabel)
                } else {
                    Text(summary)
                        .font(OakStyle.ChatFont.messageBody)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // Always shown, as ChatGPT's "Thought for 12s ›": a
                        // chevron that appears only on hover hides that the
                        // line opens at all.
                        .opacity(isHovered || isExpanded ? 1 : 0.6)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    /// The text of a group that is one stretch of thinking and nothing else.
    private var onlyThinking: String? {
        guard steps.count == 1, case .thinking(_, let text, _, _) = steps[0] else { return nil }
        return text
    }

    private var liveLabel: String {
        for step in steps.reversed() {
            switch step {
            case .thinking(_, let text, _, true):
                return Self.sectionTitle(in: text) ?? "Thinking"
            case .tool(let record) where record.status.isLive:
                if record.status == .pending { return "Waiting for approval" }
                let s = ToolStep(record)
                return s.detail.isEmpty ? "\(s.running)…" : "\(s.running) \(s.detail)…"
            default:
                continue
            }
        }
        return "Working…"
    }

    private var summary: String {
        let records = steps.compactMap { step -> ToolUseRecord? in
            if case .tool(let r) = step { return r }
            return nil
        }
        if !records.isEmpty { return ToolStep.summary(of: records) }
        var total = 0.0
        for case .thinking(_, _, let seconds, _) in steps {
            guard let seconds else { return "Thought" }
            total += seconds
        }
        return ThinkingStepRow.label(seconds: total)
    }

    // MARK: Rows

    @ViewBuilder
    private func liveRow(_ step: AgentStep) -> some View {
        switch step {
        case .thinking(_, let text, _, let live):
            // Only the thinking in progress shows its text here; finished
            // thinking is in the summary once the run ends.
            if live { LiveThinkingText(text: text) }
        case .note(_, let text):
            Text(text)
                .font(OakStyle.ChatFont.messageBody)
                .foregroundStyle(.secondary)
        case .tool(let record):
            ToolStepRow(record: record, showsResult: false)
        }
    }

    @ViewBuilder
    private func doneRow(_ step: AgentStep) -> some View {
        switch step {
        case .thinking(_, let text, let seconds, _):
            ThinkingStepRow(text: text, seconds: seconds, theme: theme)
        case .note(_, let text):
            Text(text)
                .font(OakStyle.ChatFont.messageBody)
                .foregroundStyle(.secondary)
        case .tool(let record):
            ToolStepRow(record: record, showsResult: true)
        }
    }

    /// The newest `**Title**` line of a reasoning summary, if there is one.
    static func sectionTitle(in thinking: String) -> String? {
        for line in thinking.suffix(4000).split(separator: "\n").reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.count > 4, t.hasPrefix("**"), t.hasSuffix("**") {
                let title = t.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty, !title.contains("**") { return title }
            }
        }
        return nil
    }
}

/// Thinking as it streams: plain SwiftUI text with inline markdown.
///
/// Not the NSTextView-backed `StreamingMarkdownView`: inside a scroll view
/// that resizes every frame, that view is the likeliest source of stale or
/// overlapping glyphs, and the window only needs the tail anyway.
private struct LiveThinkingText: View {
    let text: String

    var body: some View {
        Text(attributed)
            .font(OakStyle.ChatFont.messageBody)
            .foregroundStyle(.secondary.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        // The window shows the newest lines only; parse just the tail, cut at
        // a line break so no markdown run is split.
        var tail = String(text.suffix(3000))
        if tail.count < text.count, let nl = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: nl)...])
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: tail, options: options)) ?? AttributedString(tail)
    }
}

/// A finished stretch of thinking: "Thought for 4s", opening to its text.
private struct ThinkingStepRow: View {
    let text: String
    let seconds: Double?
    let theme: MarkdownTheme

    @State private var isOpen = false

    static func label(seconds: Double?) -> String {
        guard let seconds else { return "Thought" }
        if seconds < 0.5 { return "Thought briefly" }
        return "Thought for \(Int(seconds.rounded()))s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { isOpen.toggle() } label: {
                Text(Self.label(seconds: seconds))
                    .font(OakStyle.ChatFont.messageBody)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                StreamingMarkdownView(markdown: text, theme: Self.muted(theme), isStreaming: false)
                    .transition(.chatReveal)
            }
        }
        .animation(.chatDisclosure, value: isOpen)
    }

    /// The bubble's theme with its text dropped to the secondary tone.
    static func muted(_ theme: MarkdownTheme) -> MarkdownTheme {
        var t = theme
        t.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.75)
        t.secondaryTextColor = NSColor.secondaryLabelColor.withAlphaComponent(0.6)
        return t
    }
}

extension ToolUseStatus {
    var isLive: Bool { self == .streaming || self == .pending || self == .executing }
}

// MARK: - One step

private struct ToolStepRow: View {
    let record: ToolUseRecord
    let showsResult: Bool

    @State private var showsOutput = false

    var body: some View {
        let step = ToolStep(record)
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if canOpen { showsOutput.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(verb(step))
                        .fontWeight(record.status.isLive ? .medium : .regular)
                        .foregroundStyle(record.isError ? AnyShapeStyle(Color.red.opacity(0.8))
                                         : record.status.isLive ? AnyShapeStyle(.primary)
                                         : AnyShapeStyle(.secondary))
                    if !step.detail.isEmpty {
                        Text(step.detail)
                            .foregroundStyle(.secondary.opacity(0.8))
                            .truncationMode(.middle)
                    }
                    if let outcome = outcome {
                        Text(outcome)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(OakStyle.ChatFont.messageBody)
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)

            // The argument the model is still writing, newest lines in view.
            if record.status == .streaming, let body = streamingBody {
                TailWindow(maxHeight: 80) {
                    Text(body)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if showsOutput, let result = record.result, !result.isEmpty {
                ToolResultPreview(text: result)
                    .transition(.chatReveal)
            }
        }
        .animation(.chatDisclosure, value: showsOutput)
    }

    private var canOpen: Bool {
        showsResult && !(record.result ?? "").isEmpty
    }

    private func verb(_ step: ToolStep) -> String {
        switch record.status {
        case .streaming, .executing: return step.running
        case .pending: return step.running
        case .denied: return "Skipped"
        case .completed: return record.isError ? "\(step.failed) attempted" : step.done
        }
    }

    /// "12 results" from an `oak` JSON envelope, or an error's first line.
    private var outcome: String? {
        guard record.status == .completed, let result = record.result else { return nil }
        if record.isError {
            let line = result.split(separator: "\n").first.map(String.init) ?? ""
            return line.count > 60 ? String(line.prefix(60)) + "…" : line
        }
        if let start = result.firstIndex(of: "{"),
           let data = String(result[start...]).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let count = (json["meta"] as? [String: Any])?["count"] as? Int {
            return count == 1 ? "1 result" : "\(count) results"
        }
        return nil
    }

    /// The longest string argument, once it is long enough to be worth showing
    /// as it forms: a note body, a command, a long query.
    private var streamingBody: String? {
        let longest = record.input.values.values
            .compactMap(\.scalarString)
            .max { $0.count < $1.count }
        guard let text = longest, text.count > 80 else { return nil }
        // Only the tail is visible, so do not lay out the whole body.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(10).joined(separator: "\n")
    }
}

/// A finished step's output: the first lines, in a box that scrolls past 96 pt.
private struct ToolResultPreview: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            Text(preview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 96)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Long results (a read document) are cut: the box is a glance, not a reader.
    private var preview: String {
        text.count > 2000 ? String(text.prefix(2000)) + "\n…" : text
    }
}

// MARK: - Step naming

/// How one tool call is named: three verb forms (Cursor's
/// `tool-action-labels.js` pattern), the object it acts on, and the noun used
/// when several calls collapse into one summary.
private struct ToolStep {
    var running: String
    var done: String
    var failed: String
    var detail: String = ""
    var noun: String = ""
    var plural: String = ""
    /// Several calls name their objects instead of counting them: "Listed
    /// collections and tags", not "Listed 2 lists".
    var joinsObjects = false
    /// The verb for "N of these", when `done` reads wrong with a count:
    /// "Ran 3 web searches", not "Searched the web for 3 web searches".
    var summaryDone: String?

    init(_ record: ToolUseRecord) {
        let input = record.input
        func quoted(_ key: String) -> String {
            guard let value = input[key], !value.isEmpty else { return "" }
            return "“\(value.count > 40 ? String(value.prefix(40)) + "…" : value)”"
        }
        switch record.name {
        case "search_document":
            self.init("Searching", "Searched", "Search", quoted("query"), "the document", "documents")
        case "read_document":
            let pages = input["pages"].map { "pages \($0)" } ?? ""
            self.init("Reading", "Read", "Read", pages, "the document", "documents")
        case "read_current_page":
            self.init("Reading", "Read", "Read", "the page", "the page", "pages")
        case "search_web":
            self.init("Searching the web for", "Searched the web for", "Search the web for",
                      quoted("query"), "", "queries")
            summaryDone = "Ran"; plural = "web searches"
        case "fetch_web":
            self.init("Opening", "Opened", "Open", Self.host(input["url"]), "a page", "pages")
        case "search_academic":
            self.init("Searching papers for", "Searched papers for", "Search papers for",
                      quoted("query"), "", "paper searches")
            summaryDone = "Ran"
        case "manage_memory":
            let op = (input["operation"] ?? "").lowercased()
            if op == "list" {
                self.init("Reading", "Read", "Read", "memory", "memory", "memory")
            } else {
                self.init("Updating", "Updated", "Update", "memory", "memory", "memory")
            }
        case "bash":
            self.init("Running", "Ran", "Run", Self.short(input["command"]), "a command", "commands")
        case "read", "read_file":
            self.init("Reading", "Read", "Read", Self.path(input["path"]), "a file", "files")
        case "write", "write_file":
            self.init("Writing", "Wrote", "Write", Self.path(input["path"]), "a file", "files")
        case "edit":
            self.init("Editing", "Edited", "Edit", Self.path(input["path"]), "a file", "files")
        case "oak":
            self.init(oakCommand: input["command"] ?? "")
        default:
            self.init("Running", "Ran", "Run", record.name, "a tool", "tools")
        }
    }

    private init(_ running: String, _ done: String, _ failed: String,
                 _ detail: String, _ noun: String, _ plural: String) {
        self.running = running
        self.done = done
        self.failed = failed
        self.detail = detail
        self.noun = noun
        self.plural = plural
    }

    /// `items read <key>` → Reading / Read <key>; `search <q>` → Searching library for “q”.
    private init(oakCommand command: String) {
        let words = command.split(separator: " ").map(String.init)
        func unquote(_ s: String) -> String {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        // The object: words after the verb up to the first flag.
        func object(after count: Int) -> String {
            unquote(words.dropFirst(count).prefix { !$0.hasPrefix("--") }.joined(separator: " "))
        }
        func flag(_ name: String) -> String? {
            guard let i = words.firstIndex(of: name), i + 1 < words.count else { return nil }
            return unquote(words[i + 1])
        }
        switch (words.first, words.dropFirst().first) {
        case ("items", "read"):
            self.init("Reading", "Read", "Read", object(after: 2), "a document", "documents")
        case ("items", "show"):
            self.init("Looking up", "Looked up", "Look up", object(after: 2), "a document", "documents")
        case ("items", "list"):
            let scope = flag("--collection").map { "items in \($0)" } ?? "items"
            self.init("Listing", "Listed", "List", scope, scope, "lists")
            joinsObjects = true
        case ("collections", "list"):
            self.init("Listing", "Listed", "List", "collections", "collections", "lists")
            joinsObjects = true
        case ("tags", "list"):
            self.init("Listing", "Listed", "List", "tags", "tags", "lists")
            joinsObjects = true
        case ("search", _):
            let q = object(after: 1)
            self.init("Searching library for", "Searched library for", "Search library for",
                      q.isEmpty ? "" : "“\(q)”", "", "searches")
            summaryDone = "Ran"; plural = "library searches"
        case ("import", _):
            self.init("Importing", "Imported", "Import", Self.host(object(after: 1)), "a document", "documents")
        default:
            self.init("Updating", "Updated", "Update", "library", "the library", "library changes")
        }
    }

    /// "Searched library for “agents”, read 3 documents". One phrase per kind
    /// of step, in call order; failures are counted apart.
    static func summary(of records: [ToolUseRecord]) -> String {
        struct Group {
            let step: ToolStep
            let failed: Bool
            var objects: [String] = []
            var count = 0
        }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for record in records {
            let step = ToolStep(record)
            let failed = record.isError
            // List steps share one phrase whatever they list.
            let key = "\(failed)|\(step.done)|\(step.joinsObjects ? "" : step.plural)"
            if groups[key] == nil {
                order.append(key)
                groups[key] = Group(step: step, failed: failed)
            }
            groups[key]!.count += 1
            let object = step.noun.isEmpty ? step.detail : step.noun
            if !object.isEmpty, !groups[key]!.objects.contains(object) {
                groups[key]!.objects.append(object)
            }
        }
        let parts = order.map { key -> String in
            let g = groups[key]!
            if g.failed {
                return g.count == 1 ? "\(g.step.failed) attempted" : "\(g.count) \(g.step.plural) failed"
            }
            if g.count == 1 || (g.step.joinsObjects && g.objects.count <= 3) {
                let objects = ListFormatter.localizedString(byJoining: g.objects)
                return objects.isEmpty ? g.step.done : "\(g.step.done) \(objects)"
            }
            return "\(g.step.summaryDone ?? g.step.done) \(g.count) \(g.step.plural)"
        }
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private static func path(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        let parts = path.split(separator: "/")
        return parts.count <= 2 ? path : parts.suffix(2).joined(separator: "/")
    }

    private static func host(_ url: String?) -> String {
        guard let url, !url.isEmpty else { return "" }
        return URL(string: url)?.host() ?? url
    }

    private static func short(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }
}
