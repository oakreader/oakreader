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

                Divider()
            }

            // Right side: full-page agent workspace, or the classic catalog browser.
            if appState.librarySurface == .agent {
                AgentWorkspaceView(appState: appState)
            } else {
                browsePanes
            }
        }
        .background(libraryChromeBackground)
        .onHover { inside in if inside { NSCursor.arrow.set() } }
    }

    /// Middle + Right panes (golden ratio: table ≥ 0.382, detail ≤ 0.618).
    private var browsePanes: some View {
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
                if appState.libraryDetailTab == .chat {
                    // Chat lives outside the item-selection branch so its
                    // structural identity stays stable when the selection changes,
                    // preventing AIChatView from being destroyed & recreated
                    // (which would replay the empty-state entrance animation).
                    AIChatView(chatVM: appState.libraryChatVM)
                } else if store.isDuplicatesSelected {
                    DuplicatesMergeView(appState: appState)
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
            EmptyView() // Handled at detailContentPanel level for stable identity
        case .notes:
            CollectionNotesPanelView(
                appState: appState,
                title: contextTitle,
                items: items
            )
        case .quizCards:
            CollectionQuizCardsPanelView(appState: appState, title: contextTitle)
        case .metadata:
            CollectionMetadataPanelView(appState: appState, title: contextTitle, items: items)
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Collection Metadata (Summary Stats)

private struct CollectionMetadataPanelView: View {
    @Bindable var appState: AppState
    let title: String
    let items: [LibraryItem]

    private var totalSize: Int64 {
        items.reduce(0) { $0 + $1.fileSize }
    }

    private var typeCounts: [(type: ContentType, count: Int)] {
        var map: [ContentType: Int] = [:]
        for item in items { map[item.contentType, default: 0] += 1 }
        return map.sorted { $0.value > $1.value }.map { (type: $0.key, count: $0.value) }
    }

    private var dateRange: (earliest: Date, latest: Date)? {
        guard let earliest = items.min(by: { $0.dateAdded < $1.dateAdded }),
              let latest = items.max(by: { $0.dateAdded < $1.dateAdded }) else { return nil }
        return (earliest.dateAdded, latest.dateAdded)
    }

    private var totalPages: Int {
        items.reduce(0) { $0 + $1.pageCount }
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader(title, subtitle: "\(items.count) items")

            if items.isEmpty {
                emptyState(icon: "tray", title: "No Items", subtitle: "This collection is empty.")
            } else {
                List {
                    // Stats section
                    Section {
                        statRow(label: "Items", value: "\(items.count)", icon: "doc.on.doc")
                        statRow(label: "Pages", value: "\(totalPages)", icon: "book.pages")
                        statRow(
                            label: "Total Size",
                            value: ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file),
                            icon: "internaldrive"
                        )
                        if let range = dateRange {
                            statRow(label: "Date Range", value: dateRangeString(range), icon: "calendar")
                        }
                    }

                    // Content types section
                    if typeCounts.count > 1 {
                        Section("Content Types") {
                            ForEach(typeCounts, id: \.type) { entry in
                                HStack(spacing: 8) {
                                    Image(systemName: entry.type.icon)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, alignment: .center)

                                    Text(entry.type.label)
                                        .font(.system(size: 13))

                                    Spacer()

                                    Text("\(entry.count)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()

                                    let fraction = Double(entry.count) / Double(items.count)
                                    Capsule()
                                        .fill(Color.primary.opacity(0.12))
                                        .frame(width: 48, height: 4)
                                        .overlay(alignment: .leading) {
                                            Capsule()
                                                .fill(Color.primary.opacity(0.35))
                                                .frame(width: 48 * fraction)
                                        }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func statRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func dateRangeString(_ range: (earliest: Date, latest: Date)) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM yy"
        let start = fmt.string(from: range.earliest)
        let end = fmt.string(from: range.latest)
        return start == end ? start : "\(start) – \(end)"
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

