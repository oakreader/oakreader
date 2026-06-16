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

    @State private var controller = MilkdownComposerController()
    @State private var isEmpty = true
    @State private var charCount = 0
    @State private var height: CGFloat = 44

    static let flomoGreen = Color(red: 0.31, green: 0.78, blue: 0.47)

    var body: some View {
        VStack(spacing: 8) {
            if let quote, !quote.isEmpty {
                quoteChip(quote)
            }

            MilkdownComposerView(
                initialMarkdown: initialMarkdown,
                controller: controller,
                isEmpty: $isEmpty,
                charCount: $charCount,
                height: $height,
                onSubmit: send
            )
            .frame(height: height)

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
                    mode == .edit ? Self.flomoGreen : Color.primary.opacity(0.10),
                    lineWidth: mode == .edit ? 1.5 : 1
                )
        )
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .onChange(of: focusSignal) { _, _ in controller.focus() }
        .onChange(of: captureURL) { _, url in
            guard let url else { return }
            controller.insertImage(url)
            onCaptureConsumed?()
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

            Menu {
                Button("Bold") { controller.cmd("bold") }
                Button("Italic") { controller.cmd("italic") }
                Button("Heading") { controller.cmd("heading") }
                Button("Inline code") { controller.cmd("code") }
            } label: {
                Image(systemName: "textformat")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Text format")

            toolButton("list.bullet") { controller.cmd("bulletList") }
                .help("Bulleted list")
            toolButton("list.number") { controller.cmd("orderedList") }
                .help("Numbered list")

            toolDivider

            toolButton("at") { controller.cmd("mention") }
                .help("Mention")

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
                            .fill(isEmpty ? Color.secondary.opacity(0.3) : Self.flomoGreen)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
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

    private var toolDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }

    // MARK: Actions

    private func send() {
        controller.getMarkdown { md in
            let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onSubmit(trimmed)
            if mode == .create { controller.clear() }
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let saved = NoteImageStore.save(fileAt: url) else { return }
        controller.insertImage(saved)
        controller.focus()
    }
}
