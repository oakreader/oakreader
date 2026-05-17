import SwiftUI
import UniformTypeIdentifiers

// 3-pane layout: sidebar, table, detail panel
struct LibraryRootView: View {
    @Bindable var appState: AppState

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        HStack(spacing: 0) {
            // Left pane: Sidebar
            if appState.isLibrarySidebarVisible {
                LibrarySidebarView(appState: appState)
                    .frame(width: 280)
                    .background(OakStyle.Colors.sidebarBackground)
            }

            // Middle + Right panes (golden ratio: table ≥ 0.382, detail ≤ 0.618)
            GeometryReader { geo in
                let available = geo.size.width
                let tableMin = available * 0.382
                let detailMax = available * 0.618

                HSplitView {
                    tablePane(hasTrailingCorner: appState.libraryDetailTab == nil)
                        .frame(minWidth: tableMin, maxWidth: .infinity, maxHeight: .infinity)
                    // Detail content panel (only when a tab is selected)
                    if appState.libraryDetailTab != nil {
                        detailContentPanel
                            .frame(minWidth: 480, idealWidth: available * 0.382, maxWidth: detailMax)
                    }
                }
            }

            // Side navigation strip — always visible, outside the resizable content panes.
            LibrarySideNavView(tab: $appState.libraryDetailTab)
        }
        .background(libraryChromeBackground)
        .onHover { inside in if inside { NSCursor.arrow.set() } }
    }

    private var libraryChromeBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private func tablePane(hasTrailingCorner: Bool) -> some View {
        ZStack {
            libraryChromeBackground

            let paneShape = UnevenRoundedRectangle(
                topLeadingRadius: OakStyle.Radius.standard,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: hasTrailingCorner ? OakStyle.Radius.standard : 0
            )

            VStack(spacing: 0) {
                LibraryTableToolbar(appState: appState)
                Divider()
                LibraryTableView(appState: appState, selection: $appState.selectedLibraryItemIDs)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: paneShape)
            .clipShape(paneShape)
        }
    }

    @ViewBuilder
    private var detailContentPanel: some View {
        ZStack {
            libraryChromeBackground

            let paneShape = UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: OakStyle.Radius.standard
            )

            VStack(spacing: 0) {
                if store.isDuplicatesSelected {
                    DuplicatesMergePane(appState: appState)
                } else if let item = selectedItemInCurrentFilter {
                    LibrarySidebarPanel(item: item, appState: appState)
                } else {
                    LibraryCollectionSidebarPanel(appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: paneShape)
            .clipShape(paneShape)
        }
    }

    private var selectedItemInCurrentFilter: LibraryItem? {
        guard let id = appState.selectedLibraryItemIDs.first else { return nil }
        return store.filteredItems.first { $0.id == id }
    }

}

// MARK: - Collection Detail Panel

private struct LibraryCollectionSidebarPanel: View {
    @Bindable var appState: AppState

    private var store: LibraryStore { appState.libraryStore }
    private var items: [LibraryItem] { store.filteredItems }

    private var contextTitle: String {
        if let collection = store.selectedCollection, store.selectedTagOptionId == nil {
            return collection.name
        }
        if let tagId = store.selectedTagOptionId,
           let tag = store.tagsProperty?.options.first(where: { $0.id == tagId }) {
            return tag.name
        }
        return "Library"
    }

    var body: some View {
        switch appState.libraryDetailTab {
        case .chat:
            AIChatView(chatVM: appState.libraryChatVM)
        case .notes:
            CollectionNotesPanelView(
                appState: appState,
                title: contextTitle,
                items: items
            )
        case .quizCards:
            CollectionQuizCardsPanelView(appState: appState, title: contextTitle)
        case .metadata, nil:
            EmptyView()
        }
    }
}

private struct CollectionNotesPanelView: View {
    @Bindable var appState: AppState
    let title: String
    let items: [LibraryItem]

    @State private var noteRows: [CollectionNoteRow] = []

    private var store: LibraryStore { appState.libraryStore }

    private func loadData() {
        let service = NoteService(database: store.database)
        let itemIds = items.map { $0.id.uuidString }
        let grouped = (try? service.fetchNotes(forItemIds: itemIds)) ?? [:]
        var rows: [CollectionNoteRow] = []
        for item in items {
            let notes = grouped[item.id.uuidString] ?? []
            rows.append(contentsOf: notes.map { CollectionNoteRow(item: item, note: $0) })
        }
        noteRows = rows.sorted { lhs, rhs in
            if lhs.note.isPinned != rhs.note.isPinned {
                return lhs.note.isPinned
            }
            return lhs.note.updatedAt > rhs.note.updatedAt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("Notes", subtitle: "\(noteRows.count) notes in \(title)")

            if items.isEmpty {
                emptyState(icon: "note.text", title: "No Items", subtitle: "This collection has no items.")
            } else if noteRows.isEmpty {
                emptyState(icon: "note.text", title: "No Notes", subtitle: "No items in this collection have notes.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(noteRows) { row in
                            Button {
                                appState.selectedLibraryItemIDs = [row.item.id]
                            } label: {
                                CollectionNoteListRow(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .onAppear { loadData() }
        .onChange(of: store.selectedCollectionId) { _, _ in loadData() }
        .onChange(of: store.selectedTagOptionId) { _, _ in loadData() }
        .onChange(of: store.revision) { _, _ in loadData() }
    }
}

private struct CollectionNoteRow: Identifiable {
    let item: LibraryItem
    let note: Note

    var id: String {
        "\(item.id.uuidString)-\(note.id.uuidString)"
    }
}

private struct CollectionNoteListRow: View {
    let row: CollectionNoteRow

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()

    var body: some View {
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

            Text(Self.dateFormatter.string(from: row.note.updatedAt))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

