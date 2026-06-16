import SwiftUI
import AppKit
import OakMarkdownUI

/// The right-panel **Comments** surface — a flomo-style, capture-first stream.
/// A persistent compose box at the top jots freestanding memos; below it, a
/// reverse-chronological card list of every comment for the document (memos +
/// selection-anchored notes). Anchored cards carry a colored edge + quoted
/// source and jump to it on tap.
struct CommentsPanelView: View {
    let viewModel: DocumentViewModel

    @State private var composeText = ""
    @State private var flashId: String?
    @FocusState private var composeFocused: Bool

    private var model: CommentsViewModel { viewModel.comments }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("Notes", subtitle: subtitle)
            Divider()
            composeBox
            Divider()
            stream
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: viewModel.attachmentId) { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .commentsDidChange)) { note in
            guard (note.object as AnyObject) === viewModel else { return }
            model.reload()
        }
        // A text selection started an anchored note → focus the composer.
        .onChange(of: model.pendingAnchorId) { _, new in
            if new != nil { composeFocused = true }
        }
        .onAppear { if model.pendingAnchorId != nil { composeFocused = true } }
    }

    private var subtitle: String {
        let n = model.cards.count
        return n == 1 ? "1 note" : "\(n) notes"
    }

    // MARK: - Compose

    private var composeBox: some View {
        // Slack-style composer: a bordered field with a bottom action bar
        // (a "+" menu, a quick #tag button, and the send button). When a text
        // selection started a note, a quote chip shows what it's anchored to.
        VStack(spacing: 6) {
            if model.pendingAnchorId != nil, let quote = model.pendingQuote, !quote.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(quote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button { model.cancelPending() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Detach — save as a standalone note")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }

            TextEditor(text: $composeText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(height: 54)
                .focused($composeFocused)
                .overlay(alignment: .topLeading) {
                    if composeText.isEmpty {
                        Text(model.pendingAnchorId != nil ? "Add a note…" : "Jot a thought…")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 4) {
                Menu {
                    Button { insert("#") } label: { Label("Insert tag", systemImage: "number") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add to note")

                actionIcon("number") { insert("#") }
                    .help("Insert tag")

                Spacer()

                Button {
                    save()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(canSave ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Save note (⌘↩)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    composeFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12),
                    lineWidth: 1
                )
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func actionIcon(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var canSave: Bool {
        !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave else { return }
        if model.pendingAnchorId != nil {
            model.commitPending(composeText)
        } else {
            model.addMemo(composeText)
        }
        composeText = ""
    }

    private func insert(_ s: String) {
        composeText += s
        composeFocused = true
    }

    // MARK: - Stream

    @ViewBuilder
    private var stream: some View {
        if model.cards.isEmpty {
            emptyState(
                icon: "text.bubble",
                title: "No Notes",
                subtitle: "Jot a thought above, or select text in the document to add a note."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.cards, id: \.id) { record in
                            CommentCardView(record: record, model: model, isFlashing: flashId == record.id)
                                .id(record.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .onChange(of: model.focusedCardId) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    flashId = id
                    model.focusedCardId = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if flashId == id { flashId = nil }
                    }
                }
            }
        }
    }
}

// MARK: - Card

private struct CommentCardView: View {
    let record: AnnotationRecord
    let model: CommentsViewModel
    var isFlashing: Bool = false

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""

    private var anchored: Bool { model.isAnchored(record) }
    private var accent: Color { Self.color(from: record.color) }

    var body: some View {
        HStack(spacing: 0) {
            // 2px highlight-color edge for anchored cards (wayfinding + anchored/memo cue).
            if anchored {
                Rectangle()
                    .fill(accent)
                    .frame(width: 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    editor
                } else {
                    displayContent
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.07 : 0.045))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent, lineWidth: isFlashing ? 2 : 0)
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.4), value: isFlashing)
    }

    // MARK: Display

    private var displayContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            StreamingMarkdownView(markdown: record.comment ?? "", theme: .oak(fontSize: 13))
                .frame(maxWidth: .infinity, alignment: .leading)

            if anchored, let quoted = record.text, !quoted.isEmpty {
                Text(quoted)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(accent.opacity(0.6)).frame(width: 2)
                    }
            }

            footer
        }
        .contentShape(Rectangle())
        .onTapGesture { if anchored { model.jump(record) } }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(Self.relativeTime(record.createdAt))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            if isHovering {
                if anchored {
                    Button {
                        model.jump(record)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Jump to source")
                }

                Menu {
                    Button("Edit") {
                        editText = record.comment ?? ""
                        isEditing = true
                    }
                    Button("Delete", role: .destructive) { model.delete(record) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    // MARK: Inline edit

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $editText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 56)

            HStack {
                Spacer()
                Button("Cancel") { isEditing = false }
                    .controlSize(.small)
                Button("Save") {
                    model.updateComment(id: record.id, text: editText)
                    isEditing = false
                }
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: Helpers

    /// Parse the stored color, which is hex (`#rrggbb`, PDF/memo) or a CSS
    /// `rgba(r,g,b,a)` string (web highlights).
    static func color(from raw: String) -> Color {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            if let v = Int(hex, radix: 16), hex.count == 6 {
                return Color(
                    .sRGB,
                    red: Double((v >> 16) & 0xFF) / 255,
                    green: Double((v >> 8) & 0xFF) / 255,
                    blue: Double(v & 0xFF) / 255
                )
            }
        }
        let nums = s.components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted)
            .compactMap { Int($0) }
        if nums.count >= 3 {
            return Color(.sRGB, red: Double(nums[0]) / 255, green: Double(nums[1]) / 255, blue: Double(nums[2]) / 255)
        }
        return .yellow
    }

    private static let isoParser = ISO8601DateFormatter()
    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relativeTime(_ iso: String) -> String {
        guard let date = isoParser.date(from: iso) else { return "" }
        return relFormatter.localizedString(for: date, relativeTo: Date())
    }
}
