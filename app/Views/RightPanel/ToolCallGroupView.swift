import SwiftUI

/// The tool calls of one assistant step.
///
/// Two shapes, after Cursor 3.17's agent panel:
///
/// - **While any call is live** (the model is still writing its arguments, it
///   waits for approval, or it runs) the steps are listed in a `TailWindow`
///   that follows the newest one, under a shimmering label naming it. A call
///   appears as soon as the model starts writing it, so a long argument shows
///   as it forms instead of as a silent gap.
/// - **When all have finished** the group collapses to one summary line
///   ("Searched library, read 2 documents"). Opening it lists the steps; a
///   step with a result opens to show it.
///
/// Every tool names its step with three verb forms — running, done, failed —
/// so the row says what is happening and what happened in the same words.
struct ToolCallGroupView: View {
    let records: [ToolUseRecord]

    @State private var isExpanded = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if isLive {
                TailWindow {
                    stepList(showsResults: false)
                }
                .transition(.opacity)
            } else if isExpanded {
                stepList(showsResults: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.chatDisclosure, value: isLive)
        .animation(.chatDisclosure, value: isExpanded)
    }

    // MARK: - Header

    private var header: some View {
        Button {
            guard !isLive else { return }
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                if isLive {
                    // Keyed on the call, not the text: a query that streams in
                    // character by character must not re-run the transition.
                    ShimmerText(text: liveLabel)
                        .id(liveRecord?.id)
                        .transition(.opacity)
                } else {
                    Text(summaryText)
                        .font(OakStyle.ChatFont.messageBody)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // Cursor hides the chevron until hover or open.
                        .opacity(isHovered || isExpanded ? 1 : 0)
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

    private func stepList(showsResults: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(records) { record in
                ToolStepRow(record: record, showsResult: showsResults)
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
    }

    // MARK: - State

    private var isLive: Bool { records.contains { $0.status.isLive } }

    private var liveRecord: ToolUseRecord? { records.last { $0.status.isLive } }

    private var liveLabel: String {
        guard let record = liveRecord else { return "Working…" }
        if record.status == .pending { return "Waiting for approval" }
        let step = ToolStep(record)
        return step.detail.isEmpty ? "\(step.running)…" : "\(step.running) \(step.detail)…"
    }

    /// "Searched library for “agents”, read 3 documents". One phrase per kind
    /// of step, in call order; failures are counted apart.
    private var summaryText: String {
        var order: [String] = []
        var groups: [String: (step: ToolStep, failed: Bool, count: Int)] = [:]
        for record in records {
            let step = ToolStep(record)
            let failed = record.isError
            let key = "\(failed)|\(step.done)|\(step.plural)"
            if groups[key] == nil {
                order.append(key)
                groups[key] = (step, failed, 0)
            }
            groups[key]!.count += 1
        }
        let parts = order.map { key -> String in
            let g = groups[key]!
            if g.failed {
                return g.count == 1 ? "\(g.step.failed) attempted" : "\(g.count) \(g.step.plural) failed"
            }
            if g.count == 1 {
                // A search names its query; a read names what it read.
                let object = g.step.noun.isEmpty ? g.step.detail : g.step.noun
                return object.isEmpty ? g.step.done : "\(g.step.done) \(object)"
            }
            return "\(g.step.summaryDone ?? g.step.done) \(g.count) \(g.step.plural)"
        }
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}

private extension ToolUseStatus {
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
                    .transition(.opacity)
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
            self.init("Listing", "Listed", "List", flag("--collection") ?? "items", "items", "lists")
        case ("collections", "list"):
            self.init("Listing", "Listed", "List", "collections", "collections", "lists")
        case ("tags", "list"):
            self.init("Listing", "Listed", "List", "tags", "tags", "lists")
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
