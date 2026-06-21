import SwiftUI
import AppKit

/// The flomo capture/edit card — a Milkdown WYSIWYG editor plus the flomo toolbar
/// (#, image, Aa, bullet, numbered, @) and a green send button. The *same*
/// component backs both the top capture box (`.create`) and inline card editing
/// (`.edit`), so editing a memo looks and behaves exactly like writing one — the
/// edit variant just adds a char count and a Cancel button, and a heavier grey border.
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

    @State private var controller = NoteEditorController()
    @State private var isEmpty = true
    @State private var charCount = 0
    /// Formatting commands active at the caret (reported live by the editor), so
    /// the toolbar can highlight the matching buttons — the affordance that tells
    /// the user the same button toggles the style back off.
    @State private var activeFormats: Set<String> = []
    @State private var height: CGFloat = Self.minEditorHeight
    /// Default writing area floor — matches the AI chat input
    /// (`ChatInputTextView.minContentHeight` = 40) so a short jot (a single line, or a
    /// one-item bullet/quote) hugs its content instead of sitting in a tall, half-empty
    /// box. The editor still grows past this with content.
    private static let minEditorHeight: CGFloat = 40
    /// Images attached to this note, shown as a flomo-style thumbnail tray below
    /// the prose (kept out of the editor so they never crowd out the writing line).
    @State private var attachments: [String] = []
    @State private var didSeedAttachments = false
    /// Slack-style: the inline-format row (B/I/U/S, link, lists, quote, code) is
    /// collapsed by default and toggled by the `Aa` button on the action row, so
    /// the always-visible bar stays a clean capture surface (#, @, image, send).
    @State private var showFormatBar = false
    @State private var showLink = false
    @State private var linkURL = ""
    @FocusState private var linkFieldFocused: Bool

    /// Send is allowed when there's prose *or* at least one attached image.
    private var canSend: Bool { !isEmpty || !attachments.isEmpty }

    /// Code is literal text, so rich inline formatting (B/I/U/S, link) is unavailable
    /// in any code context, and inline-code can't nest inside a code block — Slack's
    /// rule. Driven by the live `activeFormats` the editor reports at the caret.
    private var inCodeBlock: Bool { activeFormats.contains("codeBlock") }
    private var inCodeContext: Bool { inCodeBlock || activeFormats.contains("code") }

    var body: some View {
        // 4pt (not 8) between the format bar, editor, tray and action row: a tighter,
        // more compact card — the format-bar→editor gap read as too airy at 8.
        VStack(spacing: 4) {
            if let quote, !quote.isEmpty {
                quoteChip(quote)
            }

            // Slack-style: the format bar sits at the TOP of the box (the `Aa`
            // toggle is on the bottom action row).
            if showFormatBar {
                // Fade in while the card grows to make room — no edge-slide (which
                // read as "flying in from the toolbar"). Calm, per motion.md.
                formatBar
                    .transition(.opacity)
            }

            // `@` references and `#` tags are driven inline by the editor itself
            // (same `ChatCompletionPanel` the chat composer uses), so there are no
            // SwiftUI popovers to host here anymore.
            NativeNoteEditorView(
                initialMarkdown: Self.splitBody(initialMarkdown).text,
                controller: controller,
                isEmpty: $isEmpty,
                charCount: $charCount,
                height: $height,
                activeFormats: $activeFormats,
                onSubmit: send,
                references: memos,
                tags: tags
            )
            .frame(height: max(height, Self.minEditorHeight), alignment: .topLeading)
            // Grow the frame in lockstep with content (no height animation) so the
            // first line stays pinned as the editor auto-grows.

            if !attachments.isEmpty {
                attachmentTray
            }

            toolbar
        }
        // Tighter top/bottom breathing room (the format bar and action row sat too far
        // from the box edges); keep the horizontal inset so text doesn't hug the border.
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    // Edit mode reuses the note card's calm-grey focus ring
                    // (Color.secondary.opacity(0.55), see CommentsPanelView) instead
                    // of a loud accent border — neutral, but heavier than the create
                    // hairline so it still reads as "editing an existing note".
                    mode == .edit ? Color.secondary.opacity(0.55) : Color.primary.opacity(0.15),
                    lineWidth: mode == .edit ? 1.5 : 1
                )
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .onAppear {
            guard !didSeedAttachments else { return }
            didSeedAttachments = true
            let split = Self.splitBody(initialMarkdown)
            attachments = split.images
            // Seed emptiness/char-count from the SwiftUI side. The editor reports these
            // via `onChange` from inside `setMarkdown`, but that runs during the
            // representable's `makeNSView` — and a SwiftUI @State mutation during view
            // construction is dropped, leaving `isEmpty == true` in edit mode (content
            // present, yet the Save button stayed disabled — "can't save my edit").
            let seedText = split.text.trimmingCharacters(in: .whitespacesAndNewlines)
            isEmpty = seedText.isEmpty
            charCount = split.text.count
            // Editing should land the caret in the box immediately (flomo behaviour),
            // so a double-click-to-edit is instantly typeable. Deferred a tick so the
            // text view is in the window before we make it first responder.
            if mode == .edit {
                DispatchQueue.main.async { controller.focus() }
            }
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

    /// The always-visible action row (Slack-style): formatting toggle + the note's
    /// own capture actions (#, @, image), then count/cancel/send.
    private var toolbar: some View {
        HStack(spacing: 2) {
            toolButton("textformat", active: showFormatBar) {
                // Bounded easeOut, never a spring: a spring's long settling tail keeps
                // re-rendering the view graph, which on a non-base locale snowballs into
                // the SF-Symbol accessibility CPU-peg (see [[sfsymbol-a11y-locale-hang]]).
                withAnimation(.easeOut(duration: 0.12)) { showFormatBar.toggle() }
            }
            .help("Formatting")

            toolButton("number") { controller.cmd("tag") }
                .help("Tag")

            toolButton("at") { controller.requestMention() }
                .help("Reference a note")

            imageButton

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
            .help(mode == .edit ? "Save (↩)" : "Save note (↩)")
        }
    }

    /// The collapsible inline-format row (toggled by the action row's `Aa`),
    /// matching Slack's: B/I/U/S · link · bullet/ordered · quote · inline/block code.
    /// Each lights up when active at the caret so the toggle-off affordance is clear.
    private var formatBar: some View {
        // Each tool button centers its glyph in a 26pt frame, so the first glyph (B)
        // sits ~6pt in from the frame's left edge — leaving the bar visually indented
        // from the editor text margin (and from the action row's active Aa background,
        // which fills its frame and so reads as flush). Pull the whole bar left by that
        // centering offset so B lines up with the text margin / Aa box.
        HStack(spacing: 2) {
            // B/I/S don't apply to literal code — disabled in any code context. No
            // Underline: Markdown has none (it serializes to raw `<u>` HTML, which the
            // card renderer doesn't display), and underlined text reads as a link.
            toolButton("bold", active: activeFormats.contains("bold"), disabled: inCodeContext) { controller.cmd("bold") }
                .help("Bold")
            toolButton("italic", active: activeFormats.contains("italic"), disabled: inCodeContext) { controller.cmd("italic") }
                .help("Italic")
            toolButton("strikethrough", active: activeFormats.contains("strikethrough"), disabled: inCodeContext) { controller.cmd("strikethrough") }
                .help("Strikethrough")

            toolDivider

            Button { showLink = true } label: {
                Image(systemName: "link")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .opacity(inCodeContext ? 0.35 : 1)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(ToolButtonStyle())
            .disabled(inCodeContext)   // no links in literal code
            .help("Link")
            .popover(isPresented: $showLink, arrowEdge: .bottom) { linkPopover }

            toolDivider

            toolButton("list.bullet", active: activeFormats.contains("bulletList")) { controller.cmd("bulletList") }
                .help("Bulleted list")
            toolButton("list.number", active: activeFormats.contains("orderedList")) { controller.cmd("orderedList") }
                .help("Numbered list")
            // `quote.opening` — a distinct quotation glyph for the blockquote toggle.
            // NOT `text.quote`: this app reserves that for a *source reference* (the
            // anchored-note chip / add-to-chat), so `text.quote` here read as "make a
            // reference" rather than "format this paragraph as a blockquote".
            toolButton("quote.opening", active: activeFormats.contains("quote")) { controller.cmd("quote") }
                .help("Quote")

            toolDivider

            // Code glyphs: inline = a slashed `< / >` bracket pair, block = the same
            // brackets in a rounded box. Template SVG assets so they tint like the rest
            // of the bar — and far cleaner than `curlybraces`.
            // Inline code can't nest inside a code block; the code-block toggle
            // stays enabled so you can always leave the block.
            toolButton(asset: "OakCode", active: activeFormats.contains("code"), disabled: inCodeBlock) { controller.cmd("code") }
                .help("Inline code")
            toolButton(asset: "OakCodeBlock", active: activeFormats.contains("codeBlock")) { controller.cmd("codeBlock") }
                .help("Code block")

            Spacer()
        }
        .padding(.leading, -6)

    }

    /// Small URL entry for the link button — applies a link to the current
    /// selection (or inserts the URL as the link text when nothing is selected).
    private var linkPopover: some View {
        HStack(spacing: 6) {
            Image(systemName: "link").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("https://…", text: $linkURL)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($linkFieldFocused)
                .onSubmit { applyLink() }
            Button("Add") { applyLink() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 280)
        .onAppear { linkFieldFocused = true }
    }

    private func applyLink() {
        let url = linkURL.trimmingCharacters(in: .whitespaces)
        showLink = false
        linkURL = ""
        guard !url.isEmpty else { return }
        controller.insertLink(url: url)
        controller.focus()
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


    private func toolButton(_ system: String, active: Bool = false, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                // Icon color stays constant whether or not the format is active —
                // the *background* (grey fill + hairline border) signals the toggle,
                // not a color change. A disabled button dims so it reads as inert.
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .opacity(disabled ? 0.35 : 1)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
                // The `.help(...)` tooltip is the real label, so hide the icon from a11y:
                // resolving an SF Symbol's localized description on a non-base locale is
                // the CPU-peg documented in [[sfsymbol-a11y-locale-hang]].
                .accessibilityHidden(true)
        }
        .buttonStyle(ToolButtonStyle(active: active))
        .disabled(disabled)
    }

    /// Same chrome as the SF-Symbol `toolButton`, but renders a template image asset
    /// — used by the code glyphs, which have no SF Symbol equivalent.
    private func toolButton(asset: String, active: Bool = false, disabled: Bool = false,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
                .foregroundStyle(.secondary)
                .opacity(disabled ? 0.35 : 1)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
                .accessibilityHidden(true)   // `.help(...)` is the real label — see above
        }
        .buttonStyle(ToolButtonStyle(active: active))
        .disabled(disabled)
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
        OakNoteImageURL.image(url) ?? URL(string: url).flatMap { NSImage(contentsOf: $0) }
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
            // Active (toggled) state reads purely as a heavier grey fill — no border —
            // so the toggle is obvious without a hairline outline.
            if active { return Color.primary.opacity(hovering ? 0.22 : 0.16) }
            if configuration.isPressed { return Color.primary.opacity(0.12) }
            return Color.primary.opacity(hovering ? 0.06 : 0)
        }
    }
}


