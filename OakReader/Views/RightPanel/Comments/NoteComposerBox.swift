import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    let onSubmit: (String) -> Void
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

    @State private var controller = MilkdownComposerController()
    @State private var isEmpty = true
    @State private var charCount = 0
    @State private var height: CGFloat = 44
    /// Images attached to this note, shown as a flomo-style thumbnail tray below
    /// the prose (kept out of the editor so they never crowd out the writing line).
    @State private var attachments: [String] = []
    @State private var didSeedAttachments = false
    @State private var showFormat = false
    @State private var showMention = false
    @State private var mentionQuery = ""
    @State private var mentionAnchor: CGPoint = .zero
    @FocusState private var mentionFieldFocused: Bool

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
                    onSubmit: send,
                    onMention: { point in
                        if let point { mentionAnchor = point }
                        showMention = true
                    }
                )

                // Invisible caret anchor so the `@` picker pops up next to the
                // cursor (coords reported from the editor), flomo-style.
                Color.clear
                    .frame(width: 1, height: 1)
                    .offset(x: mentionAnchor.x, y: mentionAnchor.y)
                    .popover(isPresented: $showMention, arrowEdge: .bottom) { mentionPicker }
            }
            .frame(height: height)

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
                    mode == .edit ? Color.accentColor : OakStyle.Colors.border,
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
                    thumbnail(url)
                }
                addTile
            }
            .padding(.vertical, 2)
        }
    }

    private func thumbnail(_ url: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = Self.loadImage(url) {
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

            Button {
                attachments.removeAll { $0 == url }
            } label: {
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
    }

    @ViewBuilder
    private var addTile: some View {
        let tile = RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
            .foregroundStyle(Color.secondary.opacity(0.4))
            .frame(width: 72, height: 72)
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            )
            .contentShape(Rectangle())

        if let onCaptureRegion {
            Menu {
                Button { onCaptureRegion() } label: { Label("Capture region…", systemImage: "viewfinder") }
                Button { pickImage() } label: { Label("Choose file…", systemImage: "photo") }
            } label: {
                tile
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add image")
        } else {
            Button(action: pickImage) { tile }
                .buttonStyle(.plain)
                .help("Add image")
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

            Button { showFormat.toggle() } label: {
                Image(systemName: "textformat")
                    .font(.system(size: 14))
                    .foregroundStyle(showFormat ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Text format")
            .popover(isPresented: $showFormat, arrowEdge: .top) {
                HStack(spacing: 2) {
                    formatButton("bold", "Bold") { controller.cmd("bold") }
                    formatButton("italic", "Italic") { controller.cmd("italic") }
                    formatButton("textformat.size", "Heading") { controller.cmd("heading") }
                    formatButton("chevron.left.forwardslash.chevron.right", "Inline code") { controller.cmd("code") }
                }
                .padding(6)
            }

            toolButton("list.bullet") { controller.cmd("bulletList") }
                .help("Bulleted list")
            toolButton("list.number") { controller.cmd("orderedList") }
                .help("Numbered list")

            toolDivider

            Button { controller.requestMention() } label: {
                Image(systemName: "at")
                    .font(.system(size: 14))
                    .foregroundStyle(showMention ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(canSend ? Color.accentColor : OakStyle.Colors.buttonBackground)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(mode == .edit ? "Save (⌘↩)" : "Save note (⌘↩)")
        }
    }

    /// Image affordance — a menu (capture a region of the document, like AI chat,
    /// or choose a file) when capture is wired; otherwise a plain file picker.
    @ViewBuilder
    private var imageButton: some View {
        if let onCaptureRegion {
            Menu {
                Button { onCaptureRegion() } label: { Label("Capture region…", systemImage: "viewfinder") }
                Button { pickImage() } label: { Label("Choose file…", systemImage: "photo") }
            } label: {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add image")
        } else {
            toolButton("photo") { pickImage() }
                .help("Insert image")
        }
    }

    // MARK: @ memo-reference picker (flomo note-to-note link)

    private var filteredMemos: [NoteRef] {
        let q = mentionQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return memos }
        return memos.filter { $0.preview.lowercased().contains(q) }
    }

    private var mentionPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search memos…", text: $mentionQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($mentionFieldFocused)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredMemos) { ref in
                        Button { insertReference(ref) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ref.time)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Text(ref.preview.isEmpty ? "Untitled" : ref.preview)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MentionRowStyle())
                    }
                    if filteredMemos.isEmpty {
                        Text(memos.isEmpty ? "No other notes yet" : "No matches")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 320)
        .onAppear { mentionFieldFocused = true }
    }

    private func insertReference(_ ref: NoteRef) {
        controller.insertReference(label: Self.referenceLabel(ref.preview), href: NoteLink.href(ref.id))
        showMention = false
        mentionQuery = ""
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

    private func toolButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// An icon button inside the `Aa` formatting popover.
    private func formatButton(_ system: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
            onSubmit(body)
            if mode == .create {
                controller.clear()
                attachments = []
            }
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let saved = NoteImageStore.save(fileAt: url) else { return }
        attachments.append(saved)
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

    private static func loadImage(_ urlString: String) -> NSImage? {
        guard let url = URL(string: urlString) else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// A row in the `@` memo picker that highlights on hover / press.
private struct MentionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background((hovering || configuration.isPressed) ? Color.accentColor.opacity(0.12) : Color.clear)
                .onHover { hovering = $0 }
        }
    }
}
