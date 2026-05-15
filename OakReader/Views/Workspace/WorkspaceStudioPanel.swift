import SwiftUI

struct WorkspaceStudioPanel: View {
    let studioTab: WorkspaceStudioTab
    @Bindable var viewModel: WorkspaceViewModel
    let appState: AppState

    var body: some View {
        switch studioTab {
        case .notes:
            WorkspaceNotesPanel(viewModel: viewModel, appState: appState)
        }
    }
}

// MARK: - Workspace Notes Panel

private struct WorkspaceNotesPanel: View {
    @Bindable var viewModel: WorkspaceViewModel
    let appState: AppState

    private var store: LibraryStore { appState.libraryStore }

    private var collectionName: String {
        store.collections.first { $0.id == viewModel.collectionId }?.name ?? "Collection"
    }

    private var noteRows: [(item: LibraryItem, note: Note)] {
        let service = NoteService(database: store.database)
        var rows: [(item: LibraryItem, note: Note)] = []

        for item in viewModel.sourceItems {
            let notes = (try? service.fetchNotes(forItemId: item.id.uuidString)) ?? []
            for note in notes {
                rows.append((item: item, note: note))
            }
        }

        return rows.sorted { lhs, rhs in
            if lhs.note.isPinned != rhs.note.isPinned {
                return lhs.note.isPinned
            }
            return lhs.note.updatedAt > rhs.note.updatedAt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(noteRows.count) notes in \(collectionName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if noteRows.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "note.text")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No Notes")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("No items in this collection have notes.")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(noteRows, id: \.note.id) { row in
                            Button {
                                appState.selectedLibraryItemIDs = [row.item.id]
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 5) {
                                        if row.note.isPinned {
                                            Image(systemName: "pin.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.orange)
                                        }
                                        Text(row.note.displayTitle)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                    }
                                    Text(row.item.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(width: 320)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
