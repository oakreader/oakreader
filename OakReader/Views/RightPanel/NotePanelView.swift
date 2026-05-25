import SwiftUI

/// Container view for the Notes right panel. Switches between list and editor.
struct NotePanelView: View {
    let notesVM: NotesViewModel

    var body: some View {
        VStack(spacing: 0) {
            if notesVM.selectedNoteId != nil {
                NoteEditorView(notesVM: notesVM)
            } else {
                noteListContainer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noteListContainer: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Notes")
                    .font(.system(size: 16, weight: .semibold))

                Spacer()

                Button(action: { notesVM.createNote() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: OakStyle.Font.icon))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New Note")
            }
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, OakStyle.Spacing.sm)

            if notesVM.notes.isEmpty {
                emptyState
            } else {
                NoteListView(notesVM: notesVM)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Notes Yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Create a note to capture your thoughts about this document.")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, OakStyle.Spacing.lg)
            Spacer()
        }
    }
}
