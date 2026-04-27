import SwiftUI
import AppKit
import MarkdownEditor

/// Wraps the note markdown editor with a header toolbar.
struct NoteEditorView: View {
    let notesVM: NotesViewModel

    // Observe preference changes so the editor rebuilds when settings change
    @AppStorage("noteEditorFontFamily") private var fontFamily = ""
    @AppStorage("noteEditorFontSize") private var fontSize: Double = 17
    @AppStorage("noteEditorCodeFontFamily") private var codeFontFamily = ""
    @AppStorage("noteEditorLineHeight") private var lineHeight: Double = 1.75
    @AppStorage("noteEditorShowLineNumbers") private var showLineNumbers = false
    @AppStorage("noteEditorRenderMath") private var renderMath = true
    @AppStorage("noteEditorRenderImages") private var renderImages = true
    @AppStorage("noteEditorHideSyntax") private var hideSyntax = true

    /// Combined hash of all settings — when it changes, the editor is recreated.
    private var configId: Int {
        var h = Hasher()
        h.combine(fontFamily)
        h.combine(fontSize)
        h.combine(codeFontFamily)
        h.combine(lineHeight)
        h.combine(showLineNumbers)
        h.combine(renderMath)
        h.combine(renderImages)
        h.combine(hideSyntax)
        return h.finalize()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Back button header
            HStack(spacing: 6) {
                Button(action: { notesVM.deselectNote() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: OakStyle.Font.icon, weight: .medium))
                        Text("Notes")
                            .font(.system(size: OakStyle.Font.body))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back to notes list")

                Spacer()

                // Insert Image
                Button(action: insertImage) {
                    Image(systemName: "photo")
                        .font(.system(size: OakStyle.Font.icon))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Insert Image")

                if let note = notesVM.selectedNote {
                    // Pin toggle
                    Button(action: { notesVM.togglePin(note) }) {
                        Image(systemName: note.isPinned ? "pin.slash" : "pin")
                            .font(.system(size: OakStyle.Font.icon))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(note.isPinned ? "Unpin" : "Pin to top")

                    // Delete
                    Button(action: { notesVM.deleteNote(note) }) {
                        Image(systemName: "trash")
                            .font(.system(size: OakStyle.Font.icon))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete note")
                }
            }
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, OakStyle.Spacing.sm)

            Divider()

            // WYSIWYG Markdown Editor (custom wrapper with clean styling)
            NoteEditorWebView(
                text: Binding(
                    get: { notesVM.editorContent },
                    set: { notesVM.editorContentDidChange($0) }
                ),
                configuration: Self.editorConfiguration(),
                baseURL: notesVM.notesDirectoryURL
            )
            .id(configId)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Insert Image

    private func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .tiff, .bmp]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select an image to insert into the note"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else { return }

        let ext = url.pathExtension.lowercased()
        guard let relativePath = notesVM.saveImage(data, fileExtension: ext.isEmpty ? "png" : ext) else { return }

        // Append markdown image reference
        let imageName = url.deletingPathExtension().lastPathComponent
        let markdown = "\n![\(imageName)](\(relativePath))\n"
        notesVM.editorContentDidChange(notesVM.editorContent + markdown)
    }

    // MARK: - Configuration from Preferences

    private static func editorConfiguration() -> EditorConfiguration {
        let prefs = Preferences.shared
        return EditorConfiguration(
            fontSize: prefs.noteEditorFontSize,
            fontFamily: prefs.noteEditorFontFamily,
            lineHeight: prefs.noteEditorLineHeight,
            showLineNumbers: prefs.noteEditorShowLineNumbers,
            wrapLines: true,
            renderMermaid: false,
            renderMath: prefs.noteEditorRenderMath,
            renderImages: prefs.noteEditorRenderImages,
            hideSyntax: prefs.noteEditorHideSyntax
        )
    }

}
