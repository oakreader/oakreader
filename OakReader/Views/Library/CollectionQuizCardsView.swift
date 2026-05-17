import SwiftUI

// MARK: - Service Action Helper

struct CollectionQuizCardActions {
    let service: QuizCardService

    func approve(_ card: QuizCard) {
        try? service.approveCard(id: card.id)
    }

    func approveAll(_ cards: [QuizCard]) {
        for card in cards { approve(card) }
    }

    func delete(_ card: QuizCard) {
        try? service.deleteCard(id: card.id)
    }
}

// MARK: - Collection Quiz Tab

enum CollectionQuizTab: String, CaseIterable, Identifiable {
    case deck, pending, browse
    var id: String { rawValue }

    var label: String {
        switch self {
        case .deck: "Deck"
        case .pending: "Pending"
        case .browse: "Browse"
        }
    }

    var systemImage: String {
        switch self {
        case .deck: "rectangle.stack"
        case .pending: "sparkles"
        case .browse: "list.bullet"
        }
    }
}

// MARK: - Collection Quiz Cards Panel

struct CollectionQuizCardsPanelView: View {
    @Bindable var appState: AppState
    let title: String
    @State private var tab: CollectionQuizTab = .deck
    @State private var cardRows: [CollectionQuizCardRow] = []
    @State private var pendingCardRows: [QuizCard] = []

    private var store: LibraryStore { appState.libraryStore }
    private var items: [LibraryItem] { store.filteredItems }

    /// True when the selected sidebar entry is a user-created (non-system) collection.
    private var isUserCollection: Bool {
        store.selectedCollection?.isSystem == false
    }

    private var actions: CollectionQuizCardActions {
        CollectionQuizCardActions(service: QuizCardService(database: store.database))
    }

    private func loadData() {
        let service = QuizCardService(database: store.database)
        let currentItems = items

        // Load cards
        let cards: [QuizCard]
        if let collectionId = store.selectedCollectionId, isUserCollection {
            cards = (try? service.fetchCards(forCollectionId: collectionId.uuidString)) ?? []
        } else {
            var all: [QuizCard] = []
            for item in currentItems {
                let itemCards = (try? service.fetchCards(forItemId: item.id.uuidString)) ?? []
                all.append(contentsOf: itemCards)
            }
            all.sort { $0.dueAt < $1.dueAt }
            cards = all
        }
        cardRows = cards.map { card in
            let item = currentItems.first(where: { $0.id.uuidString == card.itemId })
            return CollectionQuizCardRow(card: card, itemTitle: item?.title)
        }

        // Load pending
        if let collectionId = store.selectedCollectionId, isUserCollection {
            pendingCardRows = (try? service.fetchPendingCards(forCollectionId: collectionId.uuidString)) ?? []
        } else {
            var all: [QuizCard] = []
            for item in currentItems {
                let itemPending = (try? service.fetchPendingCards(forItemId: item.id.uuidString)) ?? []
                all.append(contentsOf: itemPending)
            }
            pendingCardRows = all.sorted { $0.createdAt > $1.createdAt }
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
                        cardRows: cardRows
                    )
                case .pending:
                    CollectionQuizPendingView(
                        appState: appState,
                        pendingCards: pendingCardRows,
                        actions: actions,
                        onChanged: loadData
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
        .onAppear { loadData() }
        .onChange(of: store.selectedCollectionId) { _, _ in loadData() }
        .onChange(of: store.selectedTagOptionId) { _, _ in loadData() }
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

struct CollectionQuizDeckView: View {
    @Bindable var appState: AppState
    let cardRows: [CollectionQuizCardRow]

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

    var body: some View {
        if cardRows.isEmpty {
            emptyState(icon: "rectangle.on.rectangle.angled", title: "No Quiz Cards", subtitle: "No items in this collection have quiz cards.")
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    statsSection

                    if dueCount > 0 {
                        studyButton
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
            if let firstDueRow = cardRows.first(where: { $0.card.isDue }),
               let itemId = UUID(uuidString: firstDueRow.card.itemId),
               let item = store.filteredItems.first(where: { $0.id == itemId }) {
                appState.openLibraryItem(item)
                // Defer startReview so the tab's view model is fully wired up
                DispatchQueue.main.async {
                    appState.activeTab?.viewModel.quizCards.startReview()
                }
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
}

// MARK: - Pending Tab View

struct CollectionQuizPendingView: View {
    @Bindable var appState: AppState
    let pendingCards: [QuizCard]
    let actions: CollectionQuizCardActions
    var onChanged: (() -> Void)?
    @State private var pendingIndex: Int = 0

    private var store: LibraryStore { appState.libraryStore }

    private var currentPendingCard: QuizCard? {
        guard !pendingCards.isEmpty, pendingIndex < pendingCards.count else { return nil }
        return pendingCards[pendingIndex]
    }

    var body: some View {
        if pendingCards.isEmpty {
            emptyState(icon: "sparkles", title: "No Pending Cards", subtitle: "Generate quiz cards from your documents to review them here.")
        } else {
            VStack(spacing: 0) {
                // Header with count + Save All
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
                        actions.approveAll(pendingCards)
                        onChanged?()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // Card preview
                if let card = currentPendingCard {
                    ScrollView {
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

                            QuizCardPreviewContent(content: card.content)
                        }
                        .padding(16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    )
                    .padding(.horizontal, 12)
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
                            actions.delete(card)
                            onChanged?()
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            actions.approve(card)
                            onChanged?()
                        } label: {
                            Label("Save", systemImage: "checkmark.circle")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.green)
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
    }
}

// MARK: - Browse Tab Helpers

struct CollectionQuizCardRow: Identifiable {
    let card: QuizCard
    let itemTitle: String?

    var id: String { card.id.uuidString }
}

struct CollectionQuizCardListRow: View {
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

// MARK: - Shared Panel Helpers

@ViewBuilder
func panelHeader(_ title: String, subtitle: String) -> some View {
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
func emptyState(icon: String, title: String, subtitle: String) -> some View {
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
