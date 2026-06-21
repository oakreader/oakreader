import SwiftUI
import AppKit
import OakMarkdownUI
import UniformTypeIdentifiers

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
    @State private var showDeleteAllConfirm = false
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
                        return await model.commitPending(md)
                    } else {
                        return await model.addMemo(md)
                    }
                },
                focusSignal: focusSignal,
                onCaptureRegion: { model.captureTargetId = nil; viewModel.beginAreaCaptureForNote() },
                captureURL: model.captureTargetId == nil ? model.pendingCaptureURL : nil,
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
        .onAppear {
            // Auto-focus the composer when the Notes tab opens, so the user can start
            // jotting immediately without clicking into the box (matches the AI chat
            // input). Deferred ~0.1s — same as the chat — so the focus lands AFTER the
            // toolbar tab button that switched here releases first-responder, and after
            // the editor's text view is in the window. The anchored-note path also bumps
            // `focusSignal` (onChange above); a double bump is harmless.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusSignal += 1 }
        }
        .confirmationDialog(
            "Delete all \(model.cards.count) notes?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { model.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every note in this document, including the highlights anchored notes point to. This can't be undone.")
        }
    }

    private var subtitle: String {
        let n = model.cards.count
        return n == 1 ? "1 note" : "\(n) notes"
    }

    // MARK: - Export

    /// The document name (no extension) used as the export folder/file base.
    private var docTitle: String {
        (viewModel.fileName as NSString).deletingPathExtension
    }

    /// Export one Markdown file per note into a user-chosen folder (images copied
    /// alongside), then reveal the new folder in Finder.
    private func exportToFolder() {
        guard !model.cards.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to create the notes folder"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let folder = try NoteExporter.exportToFolder(records: model.cards, title: docTitle, parentDir: dir)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            presentError(error)
        }
    }

    /// Export every note into a single Markdown file, then reveal it in Finder.
    private func exportSingleMarkdown() {
        guard !model.cards.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(docTitle) Notes.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let md = NoteExporter.combinedMarkdown(records: model.cards, title: docTitle)
            try md.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentError(error)
        }
    }

    /// Copy an `oak notes` CLI command that prints this document's notes as
    /// Markdown — paste it into a terminal, or hand it to an AI agent as the
    /// "how to read my notes on this" instruction. Scoped by the exact item ID
    /// (not the title): titles aren't unique — duplicate imports share one — so
    /// the ID is the only identifier guaranteed to resolve to *this* document.
    /// Falls back to the title only when there's no item ID yet.
    private func copyFetchCommand() {
        let identifier = viewModel.itemId ?? (viewModel.libraryItem?.title ?? docTitle)
        let command = "oak notes --item \(shellQuote(identifier)) --markdown"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    /// Wrap a value in double quotes for a shell command line, escaping the few
    /// characters that would otherwise break out of the quotes.
    private func shellQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't export notes"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
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

            moreMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Overflow menu (⋯) next to the search button: bulk export + delete. Notes
    /// live in SQLite (not on disk), so export is how they reach the filesystem —
    /// either one file per note in a folder, or all of them in one Markdown file.
    private var moreMenu: some View {
        Menu {
            Button { exportToFolder() } label: {
                Label("Export Notes to Folder…", systemImage: "folder")
            }
            Button { exportSingleMarkdown() } label: {
                Label("Export as Single Markdown…", systemImage: "doc.text")
            }
            Divider()
            Button { copyFetchCommand() } label: {
                Label("Copy Command to Fetch Notes", systemImage: "terminal")
            }
            Divider()
            Button(role: .destructive) { showDeleteAllConfirm = true } label: {
                Label("Delete All Notes", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                // Pin the a11y label so SwiftUI never resolves the `ellipsis`
                // symbol's localized description on a non-base locale (the
                // CPU-peg in [[sfsymbol-a11y-locale-hang]]).
                .accessibilityLabel(Text("More"))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.cards.isEmpty)
        .help("More")
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
            // Eager `VStack` (not `LazyVStack`) so an inline editor opened on a
            // filtered card keeps working hit-frames — see `stream` above and
            // [[note-card-menu-detached-frame]].
            VStack(spacing: 12) {
                ForEach(model.filteredCards, id: \.id) { record in
                    CommentCardView(record: record, model: model, isFlashing: flashId == record.id)
                        .id(record.id)
                }
                if model.filteredCards.isEmpty { filteredEmptyHint }
            }
            .padding(12)
            // Overlay scrollbar so filtered cards stay full-width too (see `stream`).
            .background(OverlayScrollerConfigurator())
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) { scrollEdgeFade(.top) }
        .overlay(alignment: .bottom) { scrollEdgeFade(.bottom) }
    }

    // MARK: - Stream

    /// A soft "scroll edge" fade — cards dissolve into the panel background at the
    /// top (under the tag/search bar) and bottom (under the composer) instead of
    /// being clipped by a hard line. The gradient runs from the opaque panel
    /// background at the very edge to fully clear where the content reads, which
    /// reads as the Liquid-Glass scroll-edge effect (Apple's own list/scroll chrome).
    /// Non-interactive so it never eats clicks on the cards beneath it.
    private func scrollEdgeFade(_ edge: VerticalEdge) -> some View {
        let isTop = edge == .top
        let bg = Color(nsColor: .windowBackgroundColor)
        return LinearGradient(
            stops: [
                .init(color: bg, location: 0),
                .init(color: bg.opacity(0), location: 1)
            ],
            startPoint: isTop ? .top : .bottom,
            endPoint: isTop ? .bottom : .top
        )
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Eager `VStack`, NOT `LazyVStack`. A card can switch into an inline
                // editor (`NoteComposerBox`), and SwiftUI controls / AppKit-backed
                // representables inside a `LazyVStack` get DETACHED hit-frames — the
                // hit region drifts away from where the control is drawn, so clicks on
                // the editor's Cancel/Save/format buttons fall through to the scroll
                // view and the box looks "frozen". (Same root cause as the card `⋯`
                // menu — see [[note-card-menu-detached-frame]].) Notes lists are small
                // (tens), so eager layout is cheap and gives every row a stable frame.
                VStack(spacing: 12) {
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
                // Float the scrollbar over the content (overlay style) so a legacy /
                // always-on scrollbar doesn't shave ~15pt off the cards' right edge —
                // which left them misaligned with the bottom composer (it lives OUTSIDE
                // this scroll view, so it never lost that width). Overlay keeps the cards
                // full-width, so both share the same right margin.
                .background(OverlayScrollerConfigurator())
            }
            // Open at the live edge (newest note), chat-style.
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) { scrollEdgeFade(.top) }
            .overlay(alignment: .bottom) { scrollEdgeFade(.bottom) }
            // Land at the bottom on load and after a fresh capture — but WITHOUT an
            // animated scroll. Slack-style: switching to a long thread just shows the
            // newest message at the bottom instantly; it never animates the whole list
            // down (which, on a long note list, reads as a distracting fly-by).
            .onChange(of: model.cards.count) { _, _ in
                proxy.scrollTo("bottom")
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
    @State private var showActions = false

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
                    // Same region-capture affordance as the create composer, routed
                    // back to *this* card's editor via `captureTargetId`.
                    onCaptureRegion: {
                        model.captureTargetId = record.id
                        model.parent?.beginAreaCaptureForNote()
                    },
                    captureURL: model.captureTargetId == record.id ? model.pendingCaptureURL : nil,
                    onCaptureConsumed: {
                        model.pendingCaptureURL = nil
                        model.captureTargetId = nil
                    },
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
            // A plain Button + popover, NOT a `Menu`. SwiftUI backs a `Menu` with an
            // AppKit `AppKitPopUpAdaptor` (NSPopUpButton); inside this ScrollView +
            // LazyVStack that backing control gets a DETACHED/stale frame — its hit
            // region sits hundreds of points away from where the glyph is drawn, so
            // clicking the visible `⋯` falls through to the scroll view and the menu
            // never opens (the card looked "frozen"). A plain Button keeps a correct
            // hit region at its layout position, and the popover anchors to it reliably.
            Button { showActions = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
                    // Pin the a11y label so SwiftUI never resolves the `ellipsis`
                    // symbol's *localized* accessibility description — on a non-base
                    // locale (en-GB) that walks CFBundle tables. See
                    // [[sfsymbol-a11y-locale-hang]].
                    .accessibilityLabel(Text("More"))
            }
            .buttonStyle(.plain)
            // Pop a REAL `NSMenu` from the button (not a SwiftUI `Menu`, which
            // mis-frames inside the scrolling card list, nor a hand-rolled popover,
            // which can't match the system look). A manual `popUp` is positioned at
            // the anchor directly, so it sidesteps the scroll-view frame bug AND gets
            // the native material / hover / metrics — identical to the header `⋯`.
            .background(CardMenuPresenter(isPresented: $showActions, items: menuItems))
        }
    }

    /// Actions for the card's `⋯`, rendered as a native `NSMenu`. Mirrors the
    /// header menu's icon+label convention; order: navigate, copy, edit, then a
    /// separator before the destructive delete.
    private var menuItems: [CardMenuItem] {
        var items: [CardMenuItem] = []
        if anchored {
            items.append(CardMenuItem(title: "Jump to Source", icon: "arrow.up.left") { model.jump(record) })
        }
        items.append(CardMenuItem(title: "Copy", icon: "square.on.square") { copyToPasteboard() })
        items.append(CardMenuItem(title: "Edit", icon: "pencil") { isEditing = true })
        items.append(.separator)
        items.append(CardMenuItem(title: "Delete", icon: "trash") { showDeleteConfirm = true })
        return items
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
            if !body0.isEmpty {
                // Cards render with OakMarkdownUI, which sizes to its content
                // intrinsically — no scroll view, no height measurement. (The engine
                // is a scroll view and only earns its keep in the live composer.)
                StreamingMarkdownView(markdown: body0, theme: .oak(fontSize: 15), onOpenURL: openURL)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            cardImages

            // Tags render *below* the body — metadata that closes the note, matching
            // flomo/Bear (the timestamp frames the top, tags frame the bottom). The
            // panel's own `tagFilterBar` is the primary filter affordance; these chips
            // are mostly display, so they don't need to sit above the content.
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        NoteTagChip(tag: tag, isActive: model.activeTagFilter == tag) {
                            withAnimation(.easeOut(duration: 0.15)) { model.toggleTagFilter(tag) }
                        }
                    }
                }
                // A touch more breathing room than the 8pt sibling rhythm, so the tag
                // row reads as a metadata *footer* closing the note rather than one
                // more line of body. Small (≈11pt total) — flomo keeps tags tight to
                // their note, so the chips stay clearly attached to this card.
                .padding(.top, 3)
            }

            if anchored, let quoted = record.text, !quoted.isEmpty {
                sourceRow(quoted)
            }

            let backlinks = model.backlinks(to: record.id)
            if !backlinks.isEmpty {
                backlinksSection(backlinks)
            }
        }
        .contentShape(Rectangle())
        // Double-click an empty part of the card to edit it. A *single* click is left
        // for the embedded markdown NSTextView, so links inside the note stay clickable
        // and the text stays selectable — a full-area single-tap gesture here used to
        // swallow the mouse-down before the text view could fire `clickedOnLink:`, which
        // is why neither links nor click-to-edit worked. "Jump to source" still lives on
        // `sourceRow`'s own button (and the ⋯ menu), so that affordance isn't lost.
        .onTapGesture(count: 2) { isEditing = true }
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

/// Forces the enclosing `NSScrollView` to use **overlay** scrollers (so the bar
/// floats over the content instead of shaving ~15pt off the cards' right edge — which
/// would misalign them with the bottom composer, which lives outside the scroll view
/// and keeps full width) AND reveals the scrollbar only while the pointer is over the
/// list. Slack-style: the bar is hidden at rest, fades in on hover, fades out on exit.
/// Placed as a `.background` inside the scroll content so it can walk up to the scroll
/// view via `enclosingScrollView`.
private struct OverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HoverScrollerRevealView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.enclosingScrollView?.scrollerStyle = .overlay }
    }
}

/// A zero-size probe in the scroll content. Once in the window it walks up to the
/// enclosing `NSScrollView`, forces overlay scrollers, and installs a tracking area
/// over the visible clip region. While the pointer is inside, it keeps the overlay
/// scrollers flashed in (they fade ~1s after the last flash, so a short repeat keeps
/// them up); on exit the timer stops and they fade away — so the scrollbar shows only
/// on hover, never at rest.
private final class HoverScrollerRevealView: NSView {
    private weak var scrollView: NSScrollView?
    private var tracking: NSTrackingArea?
    private var revealTimer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { stopReveal(); return }
        let sv = enclosingScrollView
        scrollView = sv
        sv?.scrollerStyle = .overlay
        installTracking()
    }

    private func installTracking() {
        guard let clip = scrollView?.contentView else { return }
        if let t = tracking { clip.removeTrackingArea(t) }
        // `.inVisibleRect` keeps the area pinned to the clip's visible region as the
        // content scrolls, so we don't have to recompute the rect on every scroll.
        let ta = NSTrackingArea(
            rect: clip.bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        clip.addTrackingArea(ta)
        tracking = ta
    }

    override func mouseEntered(with event: NSEvent) { startReveal() }
    override func mouseExited(with event: NSEvent) { stopReveal() }

    private func startReveal() {
        scrollView?.flashScrollers()
        revealTimer?.invalidate()
        // Overlay scrollers fade ~1s after the last flash; re-flashing well within that
        // window keeps them continuously visible while the pointer lingers.
        revealTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollView?.flashScrollers() }
        }
    }

    private func stopReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
    }
}

/// One entry in a card's native `⋯` menu (`NSMenu`). A separator carries no title
/// or action.
struct CardMenuItem {
    var title: String = ""
    var icon: String? = nil
    var isSeparator: Bool = false
    var action: () -> Void = {}

    static let separator = CardMenuItem(isSeparator: true)
}

/// Pops a real `NSMenu` from its host SwiftUI view when `isPresented` flips true.
/// Used instead of a SwiftUI `Menu` (whose AppKit control mis-frames inside a
/// scrolling `LazyVStack`, so the button becomes unclickable) and instead of a
/// hand-rolled popover (which can't reproduce the native material / hover / metrics).
/// A manual `popUp(positioning:at:in:)` anchors to this view directly, dodging the
/// scroll-view frame bug while staying 100% native — matching the header `⋯`.
private struct CardMenuPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let items: [CardMenuItem]

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.anchor = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.items = items
        guard isPresented, !context.coordinator.isShowing else { return }
        context.coordinator.isShowing = true
        // Defer past this layout pass; popping a modal menu synchronously from
        // `updateNSView` would re-enter SwiftUI's update.
        DispatchQueue.main.async {
            context.coordinator.present()
            context.coordinator.isShowing = false
            isPresented = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var anchor: NSView?
        var items: [CardMenuItem] = []
        var isShowing = false
        private var actions: [() -> Void] = []

        func present() {
            guard let anchor, anchor.window != nil else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            actions = []
            for item in items {
                if item.isSeparator { menu.addItem(.separator()); continue }
                let mi = NSMenuItem(title: item.title, action: #selector(fire(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = actions.count
                if let icon = item.icon {
                    mi.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
                }
                actions.append(item.action)
                menu.addItem(mi)
            }
            // Drop the menu just below the ⋯ glyph (anchor fills the button's frame).
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
        }

        @objc private func fire(_ sender: NSMenuItem) {
            let i = sender.tag
            guard i >= 0, i < actions.count else { return }
            actions[i]()
        }
    }
}
