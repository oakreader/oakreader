import SwiftUI
import AppKit
import OakMarkdownUI

/// The right-panel **Notes** surface — a flomo-style, capture-first stream.
/// A persistent Milkdown capture card at the top jots freestanding memos (with a
/// WYSIWYG editor + the flomo toolbar: tag, image, bold/italic, lists, mention);
/// below it, a reverse-chrono list of memo cards. Each card shows its timestamp,
/// `#tag` chips, rendered markdown body, and — for selection-anchored notes — a
/// source row that jumps back to the highlight on tap. Editing a card reuses the
/// exact same composer (`NoteComposerBox`).
struct CommentsPanelView: View {
    let viewModel: DocumentViewModel

    @State private var flashId: String?
    @State private var focusSignal = 0

    private var model: CommentsViewModel { viewModel.comments }

    var body: some View {
        VStack(spacing: 0) {
            notesHeader

            NoteComposerBox(
                mode: .create,
                quote: model.pendingAnchorId != nil ? model.pendingQuote : nil,
                onDetachQuote: { model.cancelPending() },
                onSubmit: { md in
                    if model.pendingAnchorId != nil {
                        model.commitPending(md)
                    } else {
                        model.addMemo(md)
                    }
                },
                focusSignal: focusSignal,
                onCaptureRegion: { viewModel.beginAreaCaptureForNote() },
                captureURL: model.pendingCaptureURL,
                onCaptureConsumed: { model.pendingCaptureURL = nil }
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)

            stream
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: viewModel.attachmentId) { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .commentsDidChange)) { note in
            guard (note.object as AnyObject) === viewModel else { return }
            model.reload()
        }
        .onChange(of: model.pendingAnchorId) { _, new in
            if new != nil { focusSignal += 1 }
        }
        .onAppear { if model.pendingAnchorId != nil { focusSignal += 1 } }
    }

    private var subtitle: String {
        let n = model.cards.count
        return n == 1 ? "1 note" : "\(n) notes"
    }

    /// flomo-style title row with the count inline to the right of "Notes"
    /// (the shared `panelHeader` stacks the subtitle below, which we don't want here).
    private var notesHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Notes")
                .font(.system(size: 16, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Stream

    @ViewBuilder
    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.cards, id: \.id) { record in
                        CommentCardView(record: record, model: model, isFlashing: flashId == record.id)
                            .id(record.id)
                    }
                    if model.cards.isEmpty { emptyHint }
                }
                .padding(12)
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

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No Notes")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Jot a thought above, or select text in the document to add a note.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }
}

// MARK: - Card

private struct CommentCardView: View {
    let record: AnnotationRecord
    let model: CommentsViewModel
    var isFlashing: Bool = false

    @State private var isHovering = false
    @State private var isEditing = false

    private var anchored: Bool { model.isAnchored(record) }
    private var accent: Color { Self.color(from: record.color) }
    private var rawBody: String { record.comment ?? "" }
    private var tags: [String] { NoteTags.extract(rawBody) }
    private var body0: String { NoteTags.strippedBody(rawBody) }

    var body: some View {
        Group {
            if isEditing {
                NoteComposerBox(
                    mode: .edit,
                    initialMarkdown: record.comment ?? "",
                    // Keep the anchored source visible while editing (read-only),
                    // so an anchored note doesn't look like a freestanding memo.
                    quote: anchored ? record.text : nil,
                    onSubmit: { md in
                        model.updateComment(id: record.id, text: md)
                        isEditing = false
                    },
                    onCancel: { isEditing = false }
                )
            } else {
                card
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFlashing ? accent : Color.primary.opacity(0.06),
                              lineWidth: isFlashing ? 2 : 1)
        )
        .shadow(color: .black.opacity(isHovering ? 0.07 : 0.04), radius: isHovering ? 8 : 5, y: 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.35), value: isFlashing)
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    // MARK: Header (timestamp + ⋯)

    private var header: some View {
        HStack {
            Text(Self.absoluteTime(record.createdAt))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
            Menu {
                if anchored {
                    Button("Jump to source") { model.jump(record) }
                }
                Button("Edit") { isEditing = true }
                Button("Delete", role: .destructive) { model.delete(record) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: Display

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { NoteTagChip(tag: $0) }
                }
            }

            if !body0.isEmpty {
                StreamingMarkdownView(markdown: body0, theme: .oak(fontSize: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if anchored, let quoted = record.text, !quoted.isEmpty {
                sourceRow(quoted)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if anchored { model.jump(record) } }
    }

    /// flomo "source" affordance — a circular badge (tinted with the highlight
    /// color) + the quoted passage; taps jump back to it in the document.
    private func sourceRow(_ quoted: String) -> some View {
        Button {
            model.jump(record)
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(accent.opacity(0.9)).frame(width: 18, height: 18)
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(quoted)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to source")
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
    private static let absFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func absoluteTime(_ iso: String) -> String {
        guard let date = isoParser.date(from: iso) else { return "" }
        return absFormatter.string(from: date)
    }
}
