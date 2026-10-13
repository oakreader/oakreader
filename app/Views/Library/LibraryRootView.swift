import SwiftUI
import UniformTypeIdentifiers

// 3-pane layout: sidebar, table, detail panel
struct LibraryRootView: View {
    @Bindable var appState: AppState

    /// Width of the detail card. Nil until the user drags the gap, so the
    /// first layout follows the window (0.382 of the browse width).
    @State private var detailWidth: CGFloat?

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        HStack(spacing: 0) {
            // Left pane: Sidebar, on the surface base — chrome, not a card.
            if appState.isLibrarySidebarVisible {
                LibrarySidebarView(appState: appState)
                    .frame(width: 280)
            } else {
                Color.clear.frame(width: OakStyle.Surface.gutter)
            }

            // Right side: the classic catalog browser.
            browsePanes
        }
        .padding(.trailing, OakStyle.Surface.gutter)
        .padding(.bottom, OakStyle.Surface.gutter)
        .background(OakStyle.Surface.base)
        .onHover { inside in if inside { NSCursor.arrow.set() } }
    }

    /// Middle + Right cards (golden ratio: table ≥ 0.382, detail ≤ 0.618).
    private var browsePanes: some View {
        GeometryReader { geo in
            let available = geo.size.width
            let detailMin: CGFloat = 480
            let detailMax = available * 0.618
            let detail = min(max(detailWidth ?? available * 0.382, detailMin), detailMax)

            HStack(spacing: 0) {
                tablePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .surfaceCard()
                if appState.libraryDetailTab != nil {
                    resizeHandle { delta in
                        detailWidth = min(max(detail - delta, detailMin), detailMax)
                    }
                    detailContentPanel
                        .frame(width: detail)
                        .surfaceCard()
                }
            }
        }
    }

    /// The gutter between the two cards, made draggable. Nothing is drawn.
    private func resizeHandle(onDrag: @escaping (CGFloat) -> Void) -> some View {
        Color.clear
            .frame(width: OakStyle.Surface.gutter)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { onDrag($0.translation.width) })
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
    }

    private var tablePane: some View {
        // No divider under the toolbar: the card's edge already frames it.
        VStack(spacing: 0) {
            LibraryTableToolbar(appState: appState)
            switch store.viewMode {
            case .list:
                LibraryTableView(appState: appState, selection: $appState.selectedLibraryItemIDs)
            case .card:
                LibraryCardGridView(appState: appState, selection: $appState.selectedLibraryItemIDs)
            }
        }
    }

    @ViewBuilder
    private var detailContentPanel: some View {
        VStack(spacing: 0) {
            // The tab decides what the panel is, then the selection decides
            // what it is *about*. Chat is the exception: it is scoped to the
            // collection, so a selected row does not change the surface —
            // the row is something to `@`-mention, not something to replace it.
            switch appState.libraryDetailTab {
            case .chat:
                AIChatView(
                    chatVM: appState.libraryChat,
                    workspaceName: scopedCollectionName
                )
                // The chat follows the sidebar: its history and its `@`
                // completions are the selected collection's. The panel stays
                // mounted across a switch, so this cannot be left to onAppear.
                .onAppear { appState.libraryChat.rescope(toCollection: scopedCollectionId) }
                .onChange(of: scopedCollectionId) { _, id in
                    appState.libraryChat.rescope(toCollection: id)
                }
            case .metadata:
                if store.isDuplicatesSelected {
                    DuplicatesMergeView(appState: appState)
                } else if let item = selectedItemInCurrentFilter {
                    LibrarySidebarPanel(item: item, appState: appState)
                } else {
                    LibraryCollectionSidebarPanel(appState: appState)
                }
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The collection the chat is grounded in, or nil for the whole library.
    /// Mirrors `LLMContextProvider`'s test for a scopable collection, so the chip
    /// in the header names exactly what GROUNDED MODE scopes the model to.
    private var scopedCollectionName: String? {
        scopedCollection?.name
    }

    /// The same collection, as the id conversations are filed under.
    private var scopedCollectionId: String? {
        scopedCollection?.id.uuidString
    }

    private var scopedCollection: PDFCollection? {
        guard let collection = store.selectedCollection,
              !collection.isSmart,
              collection.id != SystemCollectionID.allItems else { return nil }
        return collection
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
        CollectionMetadataPanelView(appState: appState, title: contextTitle, items: items)
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
