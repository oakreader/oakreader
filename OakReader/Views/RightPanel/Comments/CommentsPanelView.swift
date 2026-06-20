import SwiftUI
import AppKit
import OakMarkdownUI

/// The right-panel **Notes** surface — a chat-to-self, capture-first stream.
/// The memo list fills the panel (oldest first, newest at the bottom) and a
/// persistent Milkdown capture card is pinned at the **bottom**, mirroring the AI
/// chat panel: you jot at the bottom and the stream grows downward, like Telegram
/// Saved Messages / 微信文件传输助手. The composer carries the flomo toolbar (tag,
/// image, bold/italic, lists, mention). Each card shows its timestamp,
/// `#tag` chips, rendered markdown body, and — for selection-anchored notes — a
/// source row that jumps back to the highlight on tap. Editing a card reuses the
/// exact same composer (`NoteComposerBox`).
struct CommentsPanelView: View {
    let viewModel: DocumentViewModel

    @State private var flashId: String?
    @State private var focusSignal = 0
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    private var model: CommentsViewModel { viewModel.comments }

    var body: some View {
        VStack(spacing: 0) {
            notesHeader

            searchField

            tagFilterBar

            // While filtering, show a dedicated TOP-anchored results list right
            // under the controls. Reusing the bottom-anchored chat stream pinned a
            // handful of matches to the bottom with a big empty gap above them.
            if model.isFiltering {
                resultsList
            } else {
                stream
            }

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
                memos: model.referenceableMemos(excluding: nil),
                tags: model.allTags
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
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
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    showSearch.toggle()
                    if !showSearch { model.searchQuery = "" }
                }
                if showSearch { searchFocused = true }
            } label: {
                Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(showSearch ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showSearch ? "Close search" : "Search notes")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Inline search field, revealed by the header's magnifying-glass button.
    /// Filters the stream by text; combines with the tag filter bar below.
    @ViewBuilder
    private var searchField: some View {
        if showSearch {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search notes…", text: Binding(
                    get: { model.searchQuery },
                    set: { model.searchQuery = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OakStyle.Colors.buttonBackground)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Horizontal row of the doc's tags; tap one to filter the stream, tap again
    /// to clear. Only shown when there are ≥2 distinct tags (filtering a single
    /// tag has nothing to narrow against).
    @ViewBuilder
    private var tagFilterBar: some View {
        let tags = model.allTags
        if tags.count >= 2 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        NoteTagChip(tag: tag, isActive: model.activeTagFilter == tag) {
                            withAnimation(.easeOut(duration: 0.15)) { model.toggleTagFilter(tag) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    /// Top-anchored results list for active search / tag filter — matches grow
    /// downward from just below the search input (not the chat stream's bottom edge).
    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.filteredCards, id: \.id) { record in
                    CommentCardView(record: record, model: model, isFlashing: flashId == record.id)
                        .id(record.id)
                }
                if model.filteredCards.isEmpty { filteredEmptyHint }
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
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
                    // Invisible anchor at the very bottom — newest note lives here,
                    // so we land on it when the panel opens and after each capture.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            // Open at the live edge (newest note), chat-style.
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: .infinity)
            // A fresh capture lands at the bottom — follow it down.
            .onChange(of: model.cards.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") }
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
            Text("Jot a thought below, or select text in the document to add a note.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }

    /// Shown when a tag filter is active but matches nothing (rare — the filter
    /// auto-clears when its tag disappears, but the stream can momentarily be empty).
    private var filteredEmptyHint: some View {
        VStack(spacing: 8) {
            Text(model.activeTagFilter.map { "No notes tagged #\($0)" } ?? "No matching notes")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Show all notes") {
                withAnimation(.easeOut(duration: 0.15)) {
                    model.activeTagFilter = nil
                    model.searchQuery = ""
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Card

private struct CommentCardView: View {
    let record: AnnotationRecord
    let model: CommentsViewModel
    var isFlashing: Bool = false

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var showDeleteConfirm = false
    @State private var showDetail = false

    private var anchored: Bool { model.isAnchored(record) }
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
                    memos: model.referenceableMemos(excluding: record.id),
                    tags: model.allTags
                )
            } else {
                card
            }
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.delete(record) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .sheet(isPresented: $showDetail) {
            NoteDetailSheet(record: record, model: model) { showDetail = false }
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
            // The "jump-to" flash uses a neutral grey ring, not the note's highlight
            // colour — a yellow memo flashed an alarming yellow border. Grey reads as
            // a calm focus pulse regardless of the note's colour.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFlashing ? Color.secondary.opacity(0.55) : Color.primary.opacity(0.15),
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
                Button("Delete", role: .destructive) { showDeleteConfirm = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
                    // Pin the a11y label so SwiftUI never resolves the `ellipsis`
                    // symbol's *localized* accessibility description. This Menu is an
                    // AppKitPopUpAdaptor rendered once per card; on a non-base locale
                    // (en-GB) that resolution walks CFBundle tables and, re-applied to
                    // every card's menu on each transaction flush the composer drives,
                    // pegs the main thread. See [[sfsymbol-a11y-locale-hang]].
                    .accessibilityLabel(Text("More"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// Copy the note to the clipboard. For an anchored note the quoted source is
    /// part of its meaning, so copy it too — the quote as a markdown blockquote,
    /// then the note body (the Zotero/Readwise export convention, and it stays
    /// readable as plain text). Uses the readable body (tags and image markup
    /// stripped); falls back to the raw markdown if that's empty.
    private func copyToPasteboard() {
        let note = body0.isEmpty ? rawBody : body0
        var parts: [String] = []
        if anchored,
           let quote = record.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quote.isEmpty {
            parts.append(quote.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }.joined(separator: "\n"))
        }
        if !note.isEmpty { parts.append(note) }
        let text = parts.joined(separator: "\n\n")
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
                    ForEach(tags, id: \.self) { tag in
                        NoteTagChip(tag: tag, isActive: model.activeTagFilter == tag) {
                            withAnimation(.easeOut(duration: 0.15)) { model.toggleTagFilter(tag) }
                        }
                    }
                }
            }

            if !body0.isEmpty {
                StreamingMarkdownView(markdown: body0, theme: .oak(), onOpenURL: openURL)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            cardImages

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

    /// flomo "关联" — the notes that reference this one. Tapping the section opens
    /// the flomo-style Note Detail popup (this note + every note quoting it).
    private func backlinksSection(_ refs: [NoteRef]) -> some View {
        Button { showDetail = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Label(refs.count == 1 ? "1 reference" : "\(refs.count) references",
                          systemImage: "arrow.turn.up.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                ForEach(refs) { ref in
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
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open note detail")
    }

    /// Handle a link tap in the card body. An `oak-note://<id>` reference jumps to
    /// the linked memo. When the note belongs to a live web tab, a web link
    /// navigates that tab's page in place — e.g. a YouTube `?t=209` link jumps to
    /// that timestamp in the video you're watching, instead of bouncing out to an
    /// external browser. Anything else falls through to the default handler.
    private func openURL(_ url: URL) -> Bool {
        if let id = NoteLink.id(from: url) {
            model.focusCard(id: id)
            return true
        }
        if let doc = model.parent, doc.liveURL != nil || doc.state.currentURL != nil,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NotificationCenter.default.post(name: .webViewLoadURL, object: doc, userInfo: ["url": url])
            return true
        }
        return false
    }

    /// Card images, flomo-style: uniform square thumbnails (九宫格) that wrap, so
    /// they read as compact cards instead of spanning a full-width line. A click
    /// opens the full-screen lightbox so the crop never hides anything.
    @ViewBuilder
    private var cardImages: some View {
        if !images.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(images, id: \.self) { cardImageTile($0) }
            }
        }
    }

    /// A uniform square thumbnail (cropped to fill) for the image grid —
    /// click opens the full image so the crop never hides anything.
    @ViewBuilder
    private func cardImageTile(_ urlString: String) -> some View {
        if let url = URL(string: urlString), let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.tileSize, height: Self.tileSize)
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

    /// Grid tile edge — small enough that 3–4 sit across the right panel per row,
    /// like flomo's 九宫格.
    private static let tileSize: CGFloat = 80

    /// flomo "source" affordance — a circular badge (tinted with the highlight
    /// color) + the quoted passage; taps jump back to it in the document.
    private func sourceRow(_ quoted: String) -> some View {
        Button {
            model.jump(record)
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(OakStyle.Colors.noteAccent.opacity(0.14)).frame(width: 18, height: 18)
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(OakStyle.Colors.noteAccentIcon)
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

    static func color(from raw: String) -> Color { NoteColor.parse(raw) }

}
