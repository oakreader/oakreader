import SwiftUI

/// Apple Notes-style list with monthly grouping, bold titles, date, and preview text.
struct NoteListView: View {
    let notesVM: NotesViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(notesVM.groupedNotes, id: \.key) { group in
                    // Section header
                    HStack {
                        Text(group.key)
                            .font(OakStyle.Font.styled(size: OakStyle.Font.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                    // Note rows
                    ForEach(group.notes) { note in
                        NoteRowView(
                            note: note,
                            isSelected: notesVM.selectedNoteId == note.id,
                            onSelect: { notesVM.selectNote(note) },
                            onDelete: { notesVM.deleteNote(note) },
                            onTogglePin: { notesVM.togglePin(note) }
                        )
                    }
                }
            }
            .padding(.bottom, OakStyle.Spacing.sm)
        }
    }
}

// MARK: - Note Row

private struct NoteRowView: View {
    let note: Note
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void

    @State private var isHovered = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy"
        return f
    }()

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                // Title (bold)
                HStack(spacing: 4) {
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    Text(note.displayTitle)
                        .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .semibold))
                        .foregroundStyle(OakStyle.Colors.textPrimary)
                        .lineLimit(1)
                }

                // Date
                Text(Self.dateFormatter.string(from: note.updatedAt))
                    .font(OakStyle.Font.styledCaption)
                    .foregroundStyle(OakStyle.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: OakStyle.Radius.small)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(action: onTogglePin) {
                Label(
                    note.isPinned ? "Unpin" : "Pin to Top",
                    systemImage: note.isPinned ? "pin.slash" : "pin"
                )
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete Note", systemImage: "trash")
            }
        }
        .padding(.horizontal, 4)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.15)
        } else if isHovered {
            return OakStyle.Colors.hoverBackground
        }
        return .clear
    }
}
