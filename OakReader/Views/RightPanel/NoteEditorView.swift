import SwiftUI
import AppKit

/// Editor modes for the note editor.
enum NoteEditorMode: String, CaseIterable {
    case edit
    case preview

    var icon: String {
        switch self {
        case .edit: return "square.and.pencil"
        case .preview: return "book"
        }
    }

    var label: String {
        switch self {
        case .edit: return "Edit"
        case .preview: return "Preview"
        }
    }
}

/// Note editor with Edit / Preview mode toggle.
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
    @AppStorage("noteEditorFontOverridden") private var fontOverridden: Bool = false
    @AppStorage("globalFontFamily") private var globalFontFamily: String = "system"
    @AppStorage("globalFontSize") private var globalFontSize: Double = 14.0

    @State private var editorCoordinator: MarkdownTextView.Coordinator?

    private var currentMode: NoteEditorMode {
        NoteEditorMode(rawValue: currentModeRaw) ?? .edit
    }

    private var effectiveFontFamily: String {
        if fontOverridden { return fontFamily }
        return FontFamily(rawValue: globalFontFamily)?.fontName ?? ".AppleSystemUIFont"
    }

    private var effectiveFontSize: CGFloat {
        if fontOverridden { return CGFloat(fontSize) }
        return CGFloat(globalFontSize)
    }

    private var editorFont: NSFont {
        NSFont(name: effectiveFontFamily, size: effectiveFontSize)
            ?? NSFont.systemFont(ofSize: effectiveFontSize)
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

            // Mode toggle — segmented picker
            Picker("Mode", selection: $currentModeRaw) {
                ForEach(NoteEditorMode.allCases, id: \.rawValue) { mode in
                    Image(systemName: mode.icon)
                        .tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 60)
            .help("Switch editor mode")

            // New note (compose)
            Button(action: { notesVM.createNote() }) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: OakStyle.Font.icon))
                    .foregroundStyle(.secondary)
                    .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Note")

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
            onImagePaste: { data in notesVM.saveImage(data) },
            onSelectionPopup: { screenPoint, text, range, textView in
                MarkdownSelectionPopupPanel.show(
                    at: screenPoint,
                    text: text,
                    range: range,
                    textView: textView,
                    viewModel: notesVM.parent
                )
            },
            onCoordinatorReady: { coordinator in
                editorCoordinator = coordinator
            }
        )
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        NotePreviewView(
            content: notesVM.editorContent,
            baseURL: notesVM.notesDirectoryURL,
            onReferenceClick: handleReferenceClick
        )
    }

    // MARK: - Reference Click

    private func handleReferenceClick(_ reference: String) {
        if reference.hasPrefix("@") {
            // Cite key reference: "@smith2024, p.12"
            let body = reference.dropFirst()
            let parts = body.split(separator: ",", maxSplits: 1)
            var pageIndex: Int?
            if parts.count > 1 {
                let pageStr = String(parts[1])
                let pattern = #"pp?\.\s*(\d+)"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: pageStr, range: NSRange(pageStr.startIndex..., in: pageStr)),
                   let range = Range(match.range(at: 1), in: pageStr),
                   let page = Int(pageStr[range]) {
                    pageIndex = page - 1
                }
            }
            if let pageIndex {
                notesVM.parent?.viewer.goToPage(pageIndex)
            }
        } else if let pageIndex = NotesViewModel.pageIndex(from: "[[\(reference)]]") {
            notesVM.parent?.viewer.goToPage(pageIndex)
        }
    }

}
