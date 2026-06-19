import SwiftUI
import AppKit

/// The flomo capture/edit card — a Milkdown WYSIWYG editor plus the flomo toolbar
/// (#, image, Aa, bullet, numbered, @) and a green send button. The *same*
/// component backs both the top capture box (`.create`) and inline card editing
/// (`.edit`), so editing a memo looks and behaves exactly like writing one — the
/// edit variant just adds a char count and a Cancel button, and a green border.
struct NoteComposerBox: View {
    enum Mode { case create, edit }

    let mode: Mode
    var initialMarkdown: String = ""
    /// Pending-anchor quote shown as a chip above the editor (create mode).
    var quote: String? = nil
    var onDetachQuote: (() -> Void)? = nil
    /// Persist the composed note. Returns whether the save succeeded — the
    /// composer only clears itself on success, so a failed save (e.g. a live page
    /// that couldn't be imported) keeps the user's text instead of dropping it.
    let onSubmit: (String) async -> Bool
    var onCancel: (() -> Void)? = nil
    /// Bump to pull keyboard focus into the editor (e.g. a text selection started
    /// an anchored note).
    var focusSignal: Int = 0
    /// When provided, the image button offers "Capture region" (a viewer crosshair
    /// clip, like AI chat) alongside "Choose file"; nil → file picker only.
    var onCaptureRegion: (() -> Void)? = nil
    /// A finished region capture's `file://` URL to insert as a markdown image.
    var captureURL: String? = nil
    var onCaptureConsumed: (() -> Void)? = nil
    /// Other memos in this doc the `@` button can reference (flomo note-to-note link).
    var memos: [NoteRef] = []
    /// Existing `#tags` in this doc, offered by the `#` picker so the user reuses a
    /// tag instead of retyping it (recognition over recall → prevents tag sprawl).
    var tags: [String] = []
    /// When set (create composer only), reuse the document's already-booted editor
    /// across Notes-tab visits instead of reloading — kills the boot+fade "flick".
    var reuseHolder: ComposerWebHolder? = nil

    @State private var controller = MilkdownComposerController()
    @State private var isEmpty = true
    @State private var charCount = 0
    /// Formatting commands active at the caret (reported live by the editor), so
    /// the toolbar can highlight the matching buttons — the affordance that tells
    /// the user the same button toggles the style back off.
    @State private var activeFormats: Set<String> = []
    @State private var height: CGFloat = Self.minEditorHeight
    /// Default writing area floor — a touch roomier than the AI chat input
    /// (`ChatInputTextView.minContentHeight` = 40) so the composer invites a real
    /// jot, without towering over it. The editor still grows past this with content.
    private static let minEditorHeight: CGFloat = 60
    /// Images attached to this note, shown as a flomo-style thumbnail tray below
    /// the prose (kept out of the editor so they never crowd out the writing line).
    @State private var attachments: [String] = []
    @State private var didSeedAttachments = false
    @State private var showMention = false
    @State private var mentionQuery = ""
    @State private var mentionAnchor: CGPoint = .zero
    @FocusState private var mentionFieldFocused: Bool
    @State private var showTag = false
    @State private var tagQuery = ""
    @State private var tagAnchor: CGPoint = .zero
    @FocusState private var tagFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// The shared dropdown palette — the same source the chat `@`/`/` panel renders
    /// from — so the note `@`/`#` pickers stay pixel-identical to it.
    private var mentionPalette: CompletionPalette { CompletionPalette(isDark: colorScheme == .dark) }

    /// Send is allowed when there's prose *or* at least one attached image.
    private var canSend: Bool { !isEmpty || !attachments.isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            if let quote, !quote.isEmpty {
                quoteChip(quote)
            }

            ZStack(alignment: .topLeading) {
                MilkdownComposerView(
                    initialMarkdown: Self.splitBody(initialMarkdown).text,
                    controller: controller,
                    isEmpty: $isEmpty,
                    charCount: $charCount,
                    height: $height,
                    activeFormats: $activeFormats,
                    reuseHolder: reuseHolder,
                    onSubmit: send,
                    onMention: { point in
                        if let point { mentionAnchor = point }
                        showMention = true
                    },
                    onTag: { point in
                        if let point { tagAnchor = point }
                        showTag = true
                    }
                )

                // Invisible caret anchor so the `@` picker pops up next to the
                // cursor (coords reported from the editor), flomo-style.
                Color.clear
                    .frame(width: 1, height: 1)
                    .offset(x: mentionAnchor.x, y: mentionAnchor.y)
                    .popover(isPresented: $showMention, arrowEdge: .bottom) { mentionPicker }

                // Same caret-anchored popover for the `#` tag picker.
                Color.clear
                    .frame(width: 1, height: 1)
                    .offset(x: tagAnchor.x, y: tagAnchor.y)
                    .popover(isPresented: $showTag, arrowEdge: .bottom) { tagPicker }
            }
            .frame(height: max(height, Self.minEditorHeight), alignment: .topLeading)
            // No height animation: animating the frame made it TRAIL the web
            // content for ~100ms after each newline, and in that window the
            // content was taller than the frame — so ProseMirror scrolled to keep
            // the caret in view, yanking the first line up and back (the visible
            // "晃一下" wobble). Growing the frame in lockstep with the content
            // keeps the first line pinned.

            if !attachments.isEmpty {
                attachmentTray
            }

            toolbar
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    mode == .edit ? Color.accentColor : Color.primary.opacity(0.15),
                    lineWidth: mode == .edit ? 1.5 : 1
                )
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .onAppear {
            guard !didSeedAttachments else { return }
            didSeedAttachments = true
            attachments = Self.splitBody(initialMarkdown).images
        }
        .onChange(of: focusSignal) { _, _ in controller.focus() }
        .onChange(of: captureURL) { _, url in
            guard let url else { return }
            attachments.append(url)
            onCaptureConsumed?()
        }
    }

    // MARK: Image attachment tray (flomo-style)

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments, id: \.self) { url in
                    NoteAttachmentThumbnail(url: url) {
                        attachments.removeAll { $0 == url }
                    }
                }
                addTile
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var addTile: some View {
        if let onCaptureRegion {
            Button(action: onCaptureRegion) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .frame(width: 72, height: 72)
                    .overlay(
                        Image(systemName: "viewfinder")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Capture a region of the document")
        }
    }

    // MARK: Quote chip (anchored note)

    private func quoteChip(_ quote: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.quote")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(quote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let onDetachQuote {
                Button(action: onDetachQuote) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Detach — save as a standalone note")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            toolButton("number") { controller.cmd("tag") }
                .help("Tag")
            imageButton

            toolDivider

            // Inline-format toggles laid out flat in the bar (no `Aa` popover) —
            // each is a single tap and lights up when active at the caret, matching
            // flomo's flat capture toolbar.
            toolButton("bold", active: activeFormats.contains("bold")) { controller.cmd("bold") }
                .help("Bold")
            toolButton("italic", active: activeFormats.contains("italic")) { controller.cmd("italic") }
                .help("Italic")
            toolButton("textformat.size", active: activeFormats.contains("heading")) { controller.cmd("heading") }
                .help("Heading")
            toolButton("chevron.left.forwardslash.chevron.right", active: activeFormats.contains("code")) { controller.cmd("code") }
                .help("Inline code")

            toolDivider

            toolButton("list.bullet", active: activeFormats.contains("bulletList")) { controller.cmd("bulletList") }
                .help("Bulleted list")
            toolButton("list.number", active: activeFormats.contains("orderedList")) { controller.cmd("orderedList") }
                .help("Numbered list")

            toolDivider

            Button { controller.requestMention() } label: {
                Image(systemName: "at")
                    .font(.system(size: 14))
                    .foregroundStyle(showMention ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ToolButtonStyle())
            .help("Reference a note")

            Spacer()

            if mode == .edit {
                Text("\(charCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Button("Cancel") { onCancel?() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            // Matches the AI chat send button: a filled circle (primary when there's
            // something to send, grey when not) with a bold up-arrow glyph.
            Button(action: send) {
                ZStack {
                    Circle()
                        .fill(canSend ? Color.primary : Color.gray.opacity(0.3))
                        .frame(width: 28, height: 28)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(mode == .edit ? "Save (⌘↩)" : "Save note (⌘↩)")
        }
    }

    /// Image affordance — captures a region of the document (a viewer crosshair
    /// clip, like AI chat). Notes only take document screenshots, never file
    /// uploads, so this is hidden when capture isn't wired (e.g. inline edit).
    @ViewBuilder
    private var imageButton: some View {
        if let onCaptureRegion {
            toolButton("viewfinder", onCaptureRegion)
                .help("Capture a region of the document")
        }
    }

    // MARK: @ memo-reference picker (flomo note-to-note link)

    private var filteredMemos: [NoteRef] {
        let q = mentionQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return memos }
        return memos.filter { $0.preview.lowercased().contains(q) }
    }

    private var mentionPicker: some View {
        let palette = mentionPalette
        return VStack(spacing: 0) {
            // The picker can't observe keystrokes typed into the WKWebView editor
            // (the native chat input filters inline because it owns its NSTextView),
            // so it carries its own search field to filter the note list.
            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryColor)
                TextField("Search notes…", text: $mentionQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.titleColor)
                    .focused($mentionFieldFocused)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle().fill(palette.borderColor).frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredMemos) { ref in
                        MentionRow(ref: ref, palette: palette) { insertReference(ref) }
                    }
                    if filteredMemos.isEmpty {
                        Text(memos.isEmpty ? "No other notes yet" : "No matches")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.secondaryColor)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                    }
                }
                // 6/5pt content inset matches the chat panel's card padding, so the
                // selection pill insets the same 6pt from the card edge.
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 300)
        .background(palette.panelBackgroundColor)
        .onAppear { mentionFieldFocused = true }
    }

    private func insertReference(_ ref: NoteRef) {
        controller.insertReference(label: Self.referenceLabel(ref.preview), href: NoteLink.href(ref.id))
        showMention = false
        mentionQuery = ""
        controller.focus()
    }

    // MARK: # tag picker (reuse existing tags → no sprawl)

    private var filteredTags: [String] {
        let q = tagQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tags }
        return tags.filter { $0.lowercased().contains(q) }
    }

    /// A "create this tag" candidate from the query — shown only when it isn't
    /// already an existing tag. Spaces are stripped (tags are single tokens).
    private var newTagCandidate: String? {
        let c = tagQuery.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard !c.isEmpty,
              !tags.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) else { return nil }
        return c
    }

    private var tagPicker: some View {
        let palette = mentionPalette
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryColor)
                TextField("Filter or create a tag…", text: $tagQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.titleColor)
                    .focused($tagFieldFocused)
                    .onSubmit {
                        if let c = newTagCandidate { insertTag(c) }
                        else if let first = filteredTags.first { insertTag(first) }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle().fill(palette.borderColor).frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let c = newTagCandidate {
                        TagPickerRow(label: "Create #\(c)", icon: "plus", palette: palette) { insertTag(c) }
                    }
                    ForEach(filteredTags, id: \.self) { tag in
                        // The leading `#` glyph already marks these as tags — don't
                        // repeat it in the label (was rendering "# #tag").
                        TagPickerRow(label: tag, icon: "number", palette: palette) { insertTag(tag) }
                    }
                    if filteredTags.isEmpty && newTagCandidate == nil {
                        Text(tags.isEmpty ? "No tags yet — type to create one" : "No matches")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.secondaryColor)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 300)
        .background(palette.panelBackgroundColor)
        .onAppear { tagFieldFocused = true }
    }

    private func insertTag(_ tag: String) {
        controller.insertTag(tag)
        showTag = false
        tagQuery = ""
        controller.focus()
    }

    /// A compact, markdown-safe label for an inserted note reference.
    static func referenceLabel(_ preview: String) -> String {
        let oneLine = preview
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespaces)
        if oneLine.isEmpty { return "MEMO" }
        return oneLine.count > 24 ? String(oneLine.prefix(24)) + "…" : oneLine
    }

    private func toolButton(_ system: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolButtonStyle(active: active))
    }

    private var toolDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }

    // MARK: Actions

    private func send() {
        controller.getMarkdown { md in
            let text = md.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = Self.combine(text: text, images: attachments)
            guard !body.isEmpty else { return }
            Task { @MainActor in
                let ok = await onSubmit(body)
                // Only clear on a successful save so a failed one keeps the text.
                if ok, mode == .create {
                    controller.clear()
                    attachments = []
                }
            }
        }
    }

    // MARK: Body <-> (prose, images)

    /// Split a stored note body into its prose and the `![](…)` image URLs, so the
    /// editor shows text only and images live in the tray. Round-trips with `combine`.
    static func splitBody(_ md: String) -> (text: String, images: [String]) {
        guard !md.isEmpty,
              let re = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)]+)\)"#)
        else { return (md, []) }
        let ns = md as NSString
        let full = NSRange(location: 0, length: ns.length)
        let images = re.matches(in: md, range: full).compactMap { m -> String? in
            guard m.numberOfRanges > 1 else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
        let text = re.stringByReplacingMatches(in: md, range: full, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, images)
    }

    /// Recombine prose + attached images into a single markdown body (images last).
    static func combine(text: String, images: [String]) -> String {
        let imgs = images.map { "![](\($0))" }.joined(separator: "\n")
        switch (text.isEmpty, imgs.isEmpty) {
        case (false, false): return text + "\n\n" + imgs
        case (false, true): return text
        default: return imgs
        }
    }
}

/// A 72pt note-tray thumbnail that, like the AI chat input's `AttachmentPill`,
/// reveals an enlarged preview on hover (a short dwell so a cursor passing over
/// doesn't flash it) — so the tray stays compact without hiding the picture.
private struct NoteAttachmentThumbnail: View {
    let url: String
    let onRemove: () -> Void

    @State private var hovering = false
    @State private var showPreview = false

    private var image: NSImage? {
        guard let u = URL(string: url) else { return nil }
        return NSImage(contentsOf: u)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help("Remove image")
        }
        .onHover { h in
            hovering = h
            if h {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if hovering { showPreview = true }
                }
            } else {
                showPreview = false
            }
        }
        .popover(isPresented: $showPreview, arrowEdge: .top) { preview }
    }

    @ViewBuilder
    private var preview: some View {
        if let img = image {
            // Hug the picture's own aspect ratio (a wide screenshot → a wide, short
            // popover) instead of floating it in a fixed square with empty space.
            let size = previewSize(for: img)
            Image(nsImage: img)
                .resizable()
                .frame(width: size.width, height: size.height)
                .padding(8)
        } else {
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .padding(24)
        }
    }

    private func previewSize(for image: NSImage) -> CGSize {
        let maxW: CGFloat = 460, maxH: CGFloat = 360
        let s = image.size
        guard s.width > 0, s.height > 0 else { return CGSize(width: 240, height: 180) }
        let scale = min(maxW / s.width, maxH / s.height)
        return CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
    }
}

/// A plain icon button that lights up with a light-grey rounded background on
/// hover (and a slightly darker one while pressed), used for the note toolbar's
/// `#`/image/`Aa`/list/`@` icons so they read as tappable affordances.
private struct ToolButtonStyle: ButtonStyle {
    /// The button's style is currently ON at the caret — show a persistent
    /// accent-tinted background so the user sees it's toggled (and can untoggle).
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, active: active)
    }

    fileprivate struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fill)
                )
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: active)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if active { return Color.accentColor.opacity(hovering ? 0.22 : 0.15) }
            if configuration.isPressed { return Color.primary.opacity(0.12) }
            return Color.primary.opacity(hovering ? 0.06 : 0)
        }
    }
}

/// A row in the `@` note picker, styled to match the chat composer's completion
/// panel (`ChatCompletionPanel`): 26pt tall, a leading glyph shown directly, the
/// note preview as the title and the timestamp right-aligned, with an accent-blue
/// selection pill and white text on hover.
private struct MentionRow: View {
    let ref: NoteRef
    let palette: CompletionPalette
    let onSelect: () -> Void
    @State private var hovering = false

    private typealias M = CompletionPalette.Metrics

    var body: some View {
        HStack(spacing: M.iconToTitle) {
            Image(systemName: "note.text")
                .font(.system(size: M.iconPointSize, weight: .medium))
                .foregroundStyle(hovering ? palette.onSelectionTextColor : palette.secondaryColor)
                .frame(width: M.iconFrame)
            Text(ref.preview.isEmpty ? "Untitled" : ref.preview)
                .font(.system(size: M.titleSize))
                .foregroundStyle(hovering ? palette.onSelectionTextColor : palette.titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 10)
            Text(ref.time)
                .font(.system(size: M.secondarySize))
                .foregroundStyle(hovering ? palette.onSelectionSecondaryColor : palette.secondaryColor)
                .lineLimit(1)
        }
        .padding(.horizontal, M.horizontalInset)
        .frame(height: M.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: M.selectionRadius, style: .continuous)
                .fill(hovering ? palette.selectionFillColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}

/// A row in the `#` tag picker — same 26pt / selection-pill styling as `MentionRow`.
private struct TagPickerRow: View {
    let label: String
    let icon: String
    let palette: CompletionPalette
    let onSelect: () -> Void
    @State private var hovering = false

    private typealias M = CompletionPalette.Metrics

    var body: some View {
        HStack(spacing: M.iconToTitle) {
            Image(systemName: icon)
                .font(.system(size: M.iconPointSize, weight: .medium))
                .foregroundStyle(hovering ? palette.onSelectionTextColor : palette.secondaryColor)
                .frame(width: M.iconFrame)
            Text(label)
                .font(.system(size: M.titleSize))
                .foregroundStyle(hovering ? palette.onSelectionTextColor : palette.titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 10)
        }
        .padding(.horizontal, M.horizontalInset)
        .frame(height: M.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: M.selectionRadius, style: .continuous)
                .fill(hovering ? palette.selectionFillColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}

