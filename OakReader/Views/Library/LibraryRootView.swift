import SwiftUI
import UniformTypeIdentifiers

/// L-shaped filled border: 1px top + left edges with a rounded top-left corner.
/// Uses a filled path instead of stroke so it renders fully inside the view bounds.
struct TopLeftBorderFill: Shape {
    let radius: CGFloat
    let thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let t = thickness
        let r = radius
        var path = Path()

        // Outer edge
        path.move(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: r, y: 0))
        path.addArc(center: CGPoint(x: r, y: r), radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: 0, y: rect.maxY))

        // Inner edge (back up)
        path.addLine(to: CGPoint(x: t, y: rect.maxY))
        path.addLine(to: CGPoint(x: t, y: r))
        path.addArc(center: CGPoint(x: r, y: r), radius: r - t,
                     startAngle: .degrees(180), endAngle: .degrees(-90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: t))
        path.closeSubpath()

        return path
    }
}

/// L-shaped filled border: 1px top + right edges with a rounded top-right corner.
struct TopRightBorderFill: Shape {
    let radius: CGFloat
    let thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let t = thickness
        let r = radius
        var path = Path()

        // Outer edge
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: 0))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: r), radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

        // Inner edge (back up)
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: r), radius: r - t,
                     startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        path.addLine(to: CGPoint(x: 0, y: t))
        path.closeSubpath()

        return path
    }
}

// 3-pane layout: sidebar, table, detail panel
struct LibraryRootView: View {
    @Bindable var appState: AppState

    @State private var detailPanelWidth: CGFloat?
    @GestureState private var detailPanelDragTranslation: CGFloat = 0

    private static let splitDividerWidth: CGFloat = 11
    private static let detailPanelMinWidth: CGFloat = 480

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
                let splitAvailable = splitAvailableWidth(for: available)
                let tableMin = splitAvailable * 0.382
                let detailWidth = resolvedDetailPanelWidth(
                    for: available,
                    dragTranslation: detailPanelDragTranslation
                )

                HStack(spacing: 0) {
                    tablePane
                        .frame(minWidth: tableMin, maxWidth: .infinity, maxHeight: .infinity)

                    // Detail content panel (only when a tab is selected)
                    if appState.libraryDetailTab != nil {
                        splitDivider(available: available)

                        detailContentPanel
                            .frame(width: detailWidth)
                    }
                }
                .background(libraryChromeBackground)
            }
            .background(libraryChromeBackground)

            // Side navigation strip — always visible, outside the resizable content panes.
            LibrarySideNavView(tab: $appState.libraryDetailTab)
        }
        .background(libraryChromeBackground)
        .onHover { inside in if inside { NSCursor.arrow.set() } }
    }

    private var libraryChromeBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private var tablePane: some View {
        VStack(spacing: 0) {
            LibraryTableToolbar(appState: appState)
            Divider()
            LibraryTableView(appState: appState, selection: $appState.selectedLibraryItemIDs)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: OakStyle.Radius.standard,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: appState.libraryDetailTab == nil ? OakStyle.Radius.standard : 0
        ))
        .overlay(
            TopLeftBorderFill(radius: OakStyle.Radius.standard, thickness: 1)
                .fill(Color(nsColor: .separatorColor))
        )
        .overlay(alignment: .topTrailing) {
            if appState.libraryDetailTab == nil {
                TopRightBorderFill(radius: OakStyle.Radius.standard, thickness: 1)
                    .fill(Color(nsColor: .separatorColor))
            }
        }
    }

    @ViewBuilder
    private var detailContentPanel: some View {
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
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: OakStyle.Radius.standard
        ))
        .overlay(
            TopRightBorderFill(radius: OakStyle.Radius.standard, thickness: 1)
                .fill(Color(nsColor: .separatorColor))
        )
    }

    private var selectedItemInCurrentFilter: LibraryItem? {
        guard let id = appState.selectedLibraryItemIDs.first else { return nil }
        return store.filteredItems.first { $0.id == id }
    }

    private func splitAvailableWidth(for available: CGFloat) -> CGFloat {
        guard appState.libraryDetailTab != nil else { return available }
        return max(available - Self.splitDividerWidth, 0)
    }

    private func detailPanelWidthRange(for available: CGFloat) -> ClosedRange<CGFloat> {
        let splitAvailable = splitAvailableWidth(for: available)
        let tableMin = splitAvailable * 0.382
        let detailMax = max(splitAvailable - tableMin, 0)
        let detailMin = min(Self.detailPanelMinWidth, detailMax)
        return detailMin...detailMax
    }

    private func resolvedDetailPanelWidth(for available: CGFloat, dragTranslation: CGFloat = 0) -> CGFloat {
        let range = detailPanelWidthRange(for: available)
        let idealWidth = splitAvailableWidth(for: available) * 0.382
        let baseWidth = min(max(detailPanelWidth ?? idealWidth, range.lowerBound), range.upperBound)
        return min(max(baseWidth - dragTranslation, range.lowerBound), range.upperBound)
    }

    private func splitDivider(available: CGFloat) -> some View {
        libraryChromeBackground
            .frame(width: Self.splitDividerWidth)
            .overlay(
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($detailPanelDragTranslation) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in
                        detailPanelWidth = resolvedDetailPanelWidth(
                            for: available,
                            dragTranslation: value.translation.width
                        )
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
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
        case .metadata, nil:
            EmptyView()
        }
    }
}

private struct CollectionNotesPanelView: View {
    @Bindable var appState: AppState
    let title: String
    let items: [LibraryItem]

    private var store: LibraryStore { appState.libraryStore }

    private var noteRows: [CollectionNoteRow] {
        let service = NoteService(database: store.database)
        var rows: [CollectionNoteRow] = []

        for item in items {
            let notes = (try? service.fetchNotes(forItemId: item.id.uuidString)) ?? []
            rows.append(contentsOf: notes.map { note in
                CollectionNoteRow(item: item, note: note)
            })
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

@ViewBuilder
private func panelHeader(_ title: String, subtitle: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
}

@ViewBuilder
private func emptyState(icon: String, title: String, subtitle: String) -> some View {
    VStack(spacing: 10) {
        Spacer()
        Image(systemName: icon)
            .font(.system(size: 36))
            .foregroundStyle(.tertiary)
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
        Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
