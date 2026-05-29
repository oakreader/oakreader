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

/// Note editor — Milkdown (Crepe) WYSIWYG hosted in a WKWebView.
/// Markdown stays the source of truth; edits autosave through NotesViewModel.
struct NoteEditorView: View {
    let notesVM: NotesViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            if let noteId = notesVM.selectedNoteId {
                MilkdownEditorView(
                    notesVM: notesVM,
                    noteId: noteId,
                    onReferenceClick: handleReferenceClick
                )
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
