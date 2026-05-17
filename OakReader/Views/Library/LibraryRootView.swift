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

// MARK: - Collection Quiz Cards Panel

private enum CollectionQuizTab: String, CaseIterable, Identifiable {
    case deck, browse
    var id: String { rawValue }

    var label: String {
        switch self {
        case .deck: "Deck"
        case .browse: "Browse"
        }
    }

    var systemImage: String {
        switch self {
        case .deck: "rectangle.stack"
        case .browse: "list.bullet"
        }
    }
}

private struct CollectionQuizCardsPanelView: View {
    @Bindable var appState: AppState
    let title: String
    @State private var tab: CollectionQuizTab = .deck

    private var store: LibraryStore { appState.libraryStore }
    private var items: [LibraryItem] { store.filteredItems }

    /// True when the selected sidebar entry is a user-created (non-system) collection.
    private var isUserCollection: Bool {
        store.selectedCollection?.isSystem == false
    }

    private var cardRows: [CollectionQuizCardRow] {
        let service = QuizCardService(database: store.database)
        let cards: [QuizCard]

        if let collectionId = store.selectedCollectionId, isUserCollection {
            cards = (try? service.fetchCards(forCollectionId: collectionId.uuidString)) ?? []
        } else {
            var all: [QuizCard] = []
            for item in items {
                let itemCards = (try? service.fetchCards(forItemId: item.id.uuidString)) ?? []
                all.append(contentsOf: itemCards)
            }
            all.sort { $0.dueAt < $1.dueAt }
            cards = all
        }

        return cards.map { card in
            let item = items.first(where: { $0.id.uuidString == card.itemId })
            return CollectionQuizCardRow(card: card, itemTitle: item?.title)
        }
    }

    private var pendingCardRows: [QuizCard] {
        let service = QuizCardService(database: store.database)

        if let collectionId = store.selectedCollectionId, isUserCollection {
            return (try? service.fetchPendingCards(forCollectionId: collectionId.uuidString)) ?? []
        } else {
            var all: [QuizCard] = []
            for item in items {
                let itemPending = (try? service.fetchPendingCards(forItemId: item.id.uuidString)) ?? []
                all.append(contentsOf: itemPending)
            }
            return all.sorted { $0.createdAt > $1.createdAt }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("Quiz Cards", subtitle: "\(cardRows.count) cards in \(title)")

            // Tab picker
            quizTabPicker

            if items.isEmpty {
                emptyState(icon: "rectangle.on.rectangle.angled", title: "No Items", subtitle: "This collection has no items.")
            } else {
                switch tab {
                case .deck:
                    CollectionQuizDeckView(
                        appState: appState,
                        cardRows: cardRows,
                        pendingCards: pendingCardRows
                    )
                case .browse:
                    if cardRows.isEmpty {
                        emptyState(icon: "rectangle.on.rectangle.angled", title: "No Quiz Cards", subtitle: "No items in this collection have quiz cards.")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(cardRows) { row in
                                    Button {
                                        if let itemId = UUID(uuidString: row.card.itemId) {
                                            appState.selectedLibraryItemIDs = [itemId]
                                        }
                                    } label: {
                                        CollectionQuizCardListRow(row: row)
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
    }

    private var quizTabPicker: some View {
        HStack(spacing: 2) {
            ForEach(CollectionQuizTab.allCases) { t in
                let selected = tab == t
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        tab = t
                    }
                } label: {
                    Label(t.label, systemImage: t.systemImage)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .foregroundStyle(selected ? .primary : .secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? Color(nsColor: .textBackgroundColor) : .clear)
                                .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Deck View (Anki-style overview)

private struct CollectionQuizDeckView: View {
    @Bindable var appState: AppState
    let cardRows: [CollectionQuizCardRow]
    let pendingCards: [QuizCard]
    @State private var pendingIndex: Int = 0

    private var store: LibraryStore { appState.libraryStore }

    private var newCount: Int {
        cardRows.filter { $0.card.state == .new }.count
    }

    private var learningCount: Int {
        cardRows.filter { $0.card.state == .learning || $0.card.state == .relearning }.count
    }

    private var dueCount: Int {
        cardRows.filter { $0.card.isDue }.count
    }

    private var currentPendingCard: QuizCard? {
        guard !pendingCards.isEmpty, pendingIndex < pendingCards.count else { return nil }
        return pendingCards[pendingIndex]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Stats boxes
                statsSection

                // Study Now button
                if dueCount > 0 {
                    studyButton
                }

                // Pending cards carousel
                if !pendingCards.isEmpty {
                    pendingSection
                }

                // Empty state when no cards at all
                if cardRows.isEmpty && pendingCards.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("No Quiz Cards")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("No items in this collection have quiz cards.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onChange(of: pendingCards.count) { _, newCount in
            if pendingIndex >= newCount {
                pendingIndex = max(0, newCount - 1)
            }
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        HStack(spacing: 8) {
            statBox(count: newCount, label: "New", color: .blue, icon: "plus.circle")
            statBox(count: learningCount, label: "Learning", color: .orange, icon: "arrow.triangle.2.circlepath")
            statBox(count: dueCount, label: "Due", color: .green, icon: "clock")
        }
    }

    private func statBox(count: Int, label: String, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.08))
        )
    }

    // MARK: - Study Button

    private var studyButton: some View {
        Button {
            // Select the first item that has a due card to navigate into per-item review
            if let firstDueRow = cardRows.first(where: { $0.card.isDue }),
               let itemId = UUID(uuidString: firstDueRow.card.itemId) {
                appState.selectedLibraryItemIDs = [itemId]
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                Text("Study Now")
                    .font(.system(size: 14, weight: .semibold))
                Text("(\(dueCount) due)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pending Section

    private var pendingSection: some View {
        VStack(spacing: 8) {
            // Section header
            HStack(spacing: 8) {
                Text("Pending Review")
                    .font(.system(size: 13, weight: .semibold))

                Text("\(pendingCards.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple))

                Spacer()

                Button("Save All") {
                    let service = QuizCardService(database: store.database)
                    for card in pendingCards {
                        try? service.approveCard(id: card.id)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Card preview
            if let card = currentPendingCard {
                VStack(alignment: .leading, spacing: 12) {
                    // Type badge
                    HStack(spacing: 6) {
                        Image(systemName: card.type.systemImage)
                            .font(.system(size: 12))
                            .foregroundStyle(.purple)
                        Text(card.type.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.purple)
                    }

                    // Card content
                    pendingCardContent(for: card)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                )
            }

            // Navigation + actions
            HStack(spacing: 8) {
                Button {
                    if pendingIndex > 0 { pendingIndex -= 1 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(pendingIndex == 0)

                Text("\(pendingIndex + 1) / \(pendingCards.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Button {
                    if pendingIndex < pendingCards.count - 1 { pendingIndex += 1 }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(pendingIndex >= pendingCards.count - 1)

                Spacer()

                if let card = currentPendingCard {
                    Button(role: .destructive) {
                        let service = QuizCardService(database: store.database)
                        try? service.deleteCard(id: card.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        let service = QuizCardService(database: store.database)
                        try? service.approveCard(id: card.id)
                    } label: {
                        Label("Save", systemImage: "checkmark.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.green)
                }
            }
        }
    }

    // MARK: - Pending Card Content

    @ViewBuilder
    private func pendingCardContent(for card: QuizCard) -> some View {
        switch card.content {
        case .flashcard(let content):
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Front")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    Text(content.front)
                        .font(.system(size: 14))
                        .lineLimit(3)
                }
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Back")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    Text(content.back)
                        .font(.system(size: 14))
                        .lineLimit(3)
                }
            }
        case .cloze(let content):
            Text(content.text.replacingOccurrences(
                of: "\\{\\{c\\d+::(.*?)\\}\\}",
                with: "[___]",
                options: .regularExpression
            ))
            .font(.system(size: 14))
            .lineLimit(4)
        case .choice(let content):
            VStack(alignment: .leading, spacing: 6) {
                Text(content.question)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                ForEach(Array(content.choices.enumerated()), id: \.offset) { index, choice in
                    HStack(spacing: 6) {
                        Image(systemName: index == content.correctIndex ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(index == content.correctIndex ? .green : .secondary)
                        Text(choice)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                }
            }
        case .matching(let content):
            VStack(alignment: .leading, spacing: 4) {
                Text("Match the pairs:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(Array(content.pairs.prefix(3).enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 8) {
                        Text(pair.left)
                            .font(.system(size: 12))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(pair.right)
                            .font(.system(size: 12))
                    }
                }
                if content.pairs.count > 3 {
                    Text("+\(content.pairs.count - 3) more")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        case .ordering(let content):
            VStack(alignment: .leading, spacing: 4) {
                Text(content.prompt)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                ForEach(Array(content.items.prefix(3).enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                }
                if content.items.count > 3 {
                    Text("+\(content.items.count - 3) more")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        case .occlusion:
            Text("Image occlusion card")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Browse Tab Helpers

private struct CollectionQuizCardRow: Identifiable {
    let card: QuizCard
    let itemTitle: String?

    var id: String { card.id.uuidString }
}

private struct CollectionQuizCardListRow: View {
    let row: CollectionQuizCardRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(row.card.type.label)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                if row.card.isDue {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                }
            }

            Text(row.card.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let itemTitle = row.itemTitle {
                Text(itemTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
