import Foundation
import GRDB

@Observable
class QuizCardsViewModel {
    weak var parent: DocumentViewModel?

    // MARK: - State

    var cards: [QuizCard] = []
    var dueCards: [QuizCard] = []
    var pendingCards: [QuizCard] = []
    var dueCount: Int = 0
    var isReviewing: Bool = false
    var currentReviewIndex: Int = 0
    var errorMessage: String?

    var pendingCount: Int { pendingCards.count }

    /// The card currently being reviewed.
    var currentReviewCard: QuizCard? {
        guard isReviewing, currentReviewIndex < dueCards.count else { return nil }
        return dueCards[currentReviewIndex]
    }

    // MARK: - Private

    private let cardService: QuizCardService?
    private let storageKey: String?
    private var itemId: String?

    // MARK: - Init

    init(parent: DocumentViewModel? = nil, database: CatalogDatabase?, storageKey: String?) {
        self.parent = parent
        self.storageKey = storageKey
        if let database {
            self.cardService = QuizCardService(database: database)
        } else {
            self.cardService = nil
        }
        resolveItemId()
        loadCards()
    }

    private func resolveItemId() {
        guard let storageKey, let cardService else { return }
        let record = try? cardService.database.dbQueue.read { db in
            try ItemRecord
                .filter(ItemRecord.CodingKeys.storageKey == storageKey)
                .fetchOne(db)
        }
        itemId = record?.id
    }

    // MARK: - Load

    func loadCards() {
        guard let itemId, let cardService else {
            cards = []
            dueCards = []
            pendingCards = []
            dueCount = 0
            return
        }
        do {
            cards = try cardService.fetchCards(forItemId: itemId)
            dueCards = try cardService.fetchDueCards(forItemId: itemId)
            pendingCards = try cardService.fetchPendingCards(forItemId: itemId)
            dueCount = dueCards.count
        } catch {
            Log.error(Log.store, "Failed to load quiz cards: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Save Card from Chat

    /// Save a quiz content item from an inline chat preview into the deck.
    @discardableResult
    func saveCard(content: QuizContent, conversationId: String? = nil, groupId: String? = nil) -> Bool {
        guard let itemId, let cardService else { return false }
        do {
            let card = try cardService.createCard(
                itemId: itemId,
                conversationId: conversationId,
                groupId: groupId,
                content: content
            )
            cards.insert(card, at: 0)
            dueCards.insert(card, at: 0)
            dueCount += 1
            return true
        } catch {
            Log.error(Log.store, "Failed to save quiz card: \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Review Session

    /// Starts a review session.
    func startReview() {
        guard !dueCards.isEmpty else { return }
        currentReviewIndex = 0
        isReviewing = true
    }

    /// Submit Remember/Forget for the current card.
    func submitRecognition(remembered: Bool) {
        let rating: ReviewRating = remembered ? .good : .again
        submitReview(rating: rating)
    }

    // MARK: - Core Review Submission

    func submitReview(rating: ReviewRating) {
        guard let cardService, let card = currentReviewCard else { return }
        do {
            let updated = try cardService.recordReview(card: card, rating: rating)

            // Update local arrays
            if let idx = cards.firstIndex(where: { $0.id == card.id }) {
                cards[idx] = updated
            }

            currentReviewIndex += 1
            if currentReviewIndex >= dueCards.count {
                endReview()
            }
        } catch {
            Log.error(Log.store, "Failed to record review: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    func endReview() {
        isReviewing = false
        currentReviewIndex = 0
        loadCards()
    }

    // MARK: - Delete

    func deleteCard(_ card: QuizCard) {
        guard let cardService else { return }
        do {
            try cardService.deleteCard(id: card.id)
            cards.removeAll { $0.id == card.id }
            dueCards.removeAll { $0.id == card.id }
            dueCount = dueCards.count
        } catch {
            Log.error(Log.store, "Failed to delete quiz card: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pending Cards

    /// Approve a single pending card, moving it into FSRS scheduling.
    func approveCard(_ card: QuizCard) {
        guard let cardService else { return }
        do {
            try cardService.approveCard(id: card.id)
            pendingCards.removeAll { $0.id == card.id }
            loadCards()
        } catch {
            Log.error(Log.store, "Failed to approve pending card: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Approve all pending cards for a given annotation.
    func approveAll(annotationId: String) {
        guard let cardService else { return }
        do {
            try cardService.approveBatch(annotationId: annotationId)
            pendingCards.removeAll { $0.annotationId == annotationId }
            loadCards()
        } catch {
            Log.error(Log.store, "Failed to approve batch: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Approve all pending cards regardless of annotation.
    func approveAllPending() {
        guard let cardService else { return }
        for card in pendingCards {
            do {
                try cardService.approveCard(id: card.id)
            } catch {
                Log.error(Log.store, "Failed to approve card \(card.id): \(error)")
            }
        }
        pendingCards = []
        loadCards()
    }

    /// Delete a single pending card.
    func deletePendingCard(_ card: QuizCard) {
        guard let cardService else { return }
        do {
            try cardService.deleteCard(id: card.id)
            pendingCards.removeAll { $0.id == card.id }
        } catch {
            Log.error(Log.store, "Failed to delete pending card: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Delete all pending cards for a given annotation.
    func deleteAllPending(annotationId: String) {
        guard let cardService else { return }
        do {
            try cardService.deletePendingCards(annotationId: annotationId)
            pendingCards.removeAll { $0.annotationId == annotationId }
        } catch {
            Log.error(Log.store, "Failed to delete pending cards: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Suspend

    func toggleSuspend(_ card: QuizCard) {
        guard let cardService else { return }
        let newSuspended = !card.isSuspended
        do {
            try cardService.suspendCard(id: card.id, suspended: newSuspended)
            if let idx = cards.firstIndex(where: { $0.id == card.id }) {
                cards[idx].isSuspended = newSuspended
            }
            loadCards() // Refresh due counts
        } catch {
            Log.error(Log.store, "Failed to suspend card: \(error)")
        }
    }

    // MARK: - Grouped Cards (for list display)

    var groupedByType: [(key: QuizType, cards: [QuizCard])] {
        let grouped = Dictionary(grouping: cards) { $0.type }
        return QuizType.allCases.compactMap { type in
            guard let items = grouped[type], !items.isEmpty else { return nil }
            return (key: type, cards: items)
        }
    }
}
