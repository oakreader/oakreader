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
                        return model.commitPending(md)
                    } else {
                        return await model.addMemo(md)
                    }
                },
                focusSignal: focusSignal,
                onCaptureRegion: { viewModel.beginAreaCaptureForNote() },
                captureURL: model.pendingCaptureURL,
                onCaptureConsumed: { model.pendingCaptureURL = nil },
                memos: model.referenceableMemos(excluding: nil)
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
            Image(systemName: "note.text")
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
    // Pull images out of the body so they render as native, tappable thumbnails
    // (full-screen on click) instead of inert markdown attachments.
    private var images: [String] { NoteComposerBox.splitBody(rawBody).images }
    private var body0: String { NoteTags.strippedBody(NoteComposerBox.splitBody(rawBody).text) }

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
                        let ok = model.updateComment(id: record.id, text: md)
                        if ok { isEditing = false }
                        return ok
                    },
                    onCancel: { isEditing = false },
                    memos: model.referenceableMemos(excluding: record.id)
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
            Text(NoteTime.absolute(record.createdAt))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
            Menu {
                if anchored {
                    Button("Jump to source") { model.jump(record) }
                }
                Button("Copy") { copyToPasteboard() }
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

    /// Copy the note's text to the clipboard. Uses the readable body (tags and
    /// image markup stripped); falls back to the raw markdown if that's empty.
    private func copyToPasteboard() {
        let text = body0.isEmpty ? rawBody : body0
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
                StreamingMarkdownView(markdown: body0, theme: .oak(fontSize: 13), onOpenURL: openURL)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(images, id: \.self) { cardImage($0) }

            if anchored, let quoted = record.text, !quoted.isEmpty {
                sourceRow(quoted)
            }

            let backlinks = model.backlinks(to: record.id)
            if !backlinks.isEmpty {
                backlinksSection(backlinks)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if anchored { model.jump(record) } }
    }

    /// flomo "关联" — the notes that reference this one. Each row jumps to the
    /// referencing memo.
    private func backlinksSection(_ refs: [NoteRef]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(refs.count == 1 ? "1 reference" : "\(refs.count) references",
                  systemImage: "arrow.turn.up.left")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(refs) { ref in
                Button { model.focusCard(id: ref.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "note.text")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(ref.preview.isEmpty ? "Untitled" : ref.preview)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jump to the note that references this one")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    /// Handle a link tap in the card body. An `oak-note://<id>` reference jumps to
    /// the linked memo (returning true to consume the click); other links fall
    /// through to the default handler (open externally).
    private func openURL(_ url: URL) -> Bool {
        guard let id = NoteLink.id(from: url) else { return false }
        model.focusCard(id: id)
        return true
    }

    /// A native, tappable image thumbnail in a card — click opens it full screen.
    @ViewBuilder
    private func cardImage(_ urlString: String) -> some View {
        if let url = URL(string: urlString), let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
                .onTapGesture { ImageLightbox.show(url: urlString) }
                .help("Click to view full screen")
        }
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

}
