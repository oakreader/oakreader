import SwiftUI
import AppKit

/// Editor modes for the note editor.
enum NoteEditorMode: String, CaseIterable {
    case edit
    case preview
    case split

    var icon: String {
        switch self {
        case .edit: return "pencil"
        case .preview: return "eye"
        case .split: return "rectangle.split.1x2"
        }
    }

    var label: String {
        switch self {
        case .edit: return "Edit"
        case .preview: return "Preview"
        case .split: return "Split"
        }
    }
}

/// Note editor with Edit / Preview / Split mode toggle.
/// Replaces the old WYSIWYG WKWebView editor with a plain-text NSTextView
/// and a Textual-based markdown preview.
struct NoteEditorView: View {
    let notesVM: NotesViewModel

    @AppStorage("noteEditorMode") private var currentModeRaw: String = "edit"
    @AppStorage("noteEditorFontFamily") private var fontFamily = ".AppleSystemUIFont"
    @AppStorage("noteEditorFontSize") private var fontSize: Double = 16
    @AppStorage("noteEditorLineHeight") private var lineHeight: Double = 1.3
    @AppStorage("noteEditorLineSpacing") private var lineSpacing: Double = 3.0
    @AppStorage("noteEditorLetterSpacing") private var letterSpacing: Double = 0.5
    @AppStorage("noteEditorAccentColor") private var accentColorHex: String = "#0CA69A"

    @State private var editorCoordinator: MarkdownTextView.Coordinator?

    private var currentMode: NoteEditorMode {
        NoteEditorMode(rawValue: currentModeRaw) ?? .edit
    }

    private var editorFont: NSFont {
        NSFont(name: fontFamily, size: CGFloat(fontSize))
            ?? NSFont.systemFont(ofSize: CGFloat(fontSize))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            switch currentMode {
            case .edit:
                editorPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .preview:
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .split:
                splitPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            // Back button
            Button(action: { notesVM.deselectNote() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                    Text("Notes")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Back to notes list")

            Spacer()

            // Mode toggle — individual icon buttons
            ForEach(NoteEditorMode.allCases, id: \.rawValue) { mode in
                toolbarButton(
                    icon: mode.icon,
                    style: currentMode == mode ? .primary : .tertiary,
                    help: mode.label
                ) { currentModeRaw = mode.rawValue }
            }

            // More menu (delete, pin)
            if let note = notesVM.selectedNote {
                Menu {
                    Button(action: { notesVM.togglePin(note) }) {
                        Label(
                            note.isPinned ? "Unpin" : "Pin to Top",
                            systemImage: note.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    Divider()
                    Button(role: .destructive, action: { notesVM.deleteNote(note) }) {
                        Label("Delete Note", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: OakStyle.Font.icon, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                .contentShape(Rectangle())
                .help("More options")
            }
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.sm)
    }

    // MARK: - Editor Pane

    private var editorPane: some View {
        MarkdownTextView(
            text: Binding(
                get: { notesVM.editorContent },
                set: { notesVM.editorContentDidChange($0) }
            ),
            font: editorFont,
            lineHeight: CGFloat(lineHeight),
            lineSpacing: CGFloat(lineSpacing),
            letterSpacing: CGFloat(letterSpacing),
            accentColorHex: accentColorHex,
            onReferenceClick: handleReferenceClick,
            onImagePaste: { data in notesVM.saveImage(data) }
        )
    }

    // MARK: - Toolbar Button

    private func toolbarButton(
        icon: String, style: HierarchicalShapeStyle = .secondary,
        help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: OakStyle.Font.icon))
                .foregroundStyle(style)
                .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        NotePreviewView(
            content: notesVM.editorContent,
            baseURL: notesVM.notesDirectoryURL,
            onReferenceClick: handleReferenceClick
        )
    }

    // MARK: - Split Pane

    private var splitPane: some View {
        VSplitView {
            editorPane
                .frame(minHeight: 120)
            previewPane
                .frame(minHeight: 120)
        }
    }

    // MARK: - Reference Click

    private func handleReferenceClick(_ reference: String) {
        // Try to navigate to the referenced page
        if let pageIndex = NotesViewModel.pageIndex(from: "[[\(reference)]]") {
            notesVM.parent?.viewer.goToPage(pageIndex)
        }
    }

}
