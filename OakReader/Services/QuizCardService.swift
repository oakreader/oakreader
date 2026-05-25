import Foundation
import GRDB
import FSRS

/// Stateless service for quiz card CRUD and review operations.
struct QuizCardService {
    let database: CatalogDatabase

    // MARK: - Fetch

    /// Fetch all non-pending cards for a document, ordered by due date.
    func fetchCards(forItemId itemId: String) throws -> [QuizCard] {
        try database.dbQueue.read { db in
            let records = try QuizCardRecord
                .filter(QuizCardRecord.CodingKeys.itemId == itemId)
                .filter(QuizCardRecord.CodingKeys.isSuspended == false)
                .filter(QuizCardRecord.CodingKeys.isPending == false)
                .order(QuizCardRecord.CodingKeys.dueAt.asc)
                .fetchAll(db)
            return records.map { QuizCard(record: $0) }
        }
    }

    /// Fetch cards that are currently due for review (excludes pending).
    func fetchDueCards(forItemId itemId: String, limit: Int = 50) throws -> [QuizCard] {
        let now = Date().iso8601String
        return try database.dbQueue.read { db in
            let records = try QuizCardRecord
                .filter(QuizCardRecord.CodingKeys.itemId == itemId)
                .filter(QuizCardRecord.CodingKeys.isSuspended == false)
                .filter(QuizCardRecord.CodingKeys.isPending == false)
                .filter(QuizCardRecord.CodingKeys.dueAt <= now)
                .order(QuizCardRecord.CodingKeys.dueAt.asc)
                .limit(limit)
                .fetchAll(db)
            return records.map { QuizCard(record: $0) }
        }
    }

    /// Count cards due for review (excludes pending).
    func dueCount(forItemId itemId: String) throws -> Int {
        let now = Date().iso8601String
        return try database.dbQueue.read { db in
            try QuizCardRecord
                .filter(QuizCardRecord.CodingKeys.itemId == itemId)
                .filter(QuizCardRecord.CodingKeys.isSuspended == false)
                .filter(QuizCardRecord.CodingKeys.isPending == false)
                .filter(QuizCardRecord.CodingKeys.dueAt <= now)
                .fetchCount(db)
        }
    }

    /// Fetch pending cards for a document (awaiting user review).
    func fetchPendingCards(forItemId itemId: String) throws -> [QuizCard] {
        try database.dbQueue.read { db in
            let records = try QuizCardRecord
                .filter(QuizCardRecord.CodingKeys.itemId == itemId)
                .filter(QuizCardRecord.CodingKeys.isPending == true)
                .order(QuizCardRecord.CodingKeys.createdAt.desc)
                .fetchAll(db)
            return records.map { QuizCard(record: $0) }
        }
    }

    /// Approve a pending card — sets is_pending=0 and due_at=now so it enters FSRS scheduling.
    func approveCard(id: UUID) throws {
        let now = Date().iso8601String
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE quiz_cards SET is_pending = 0, due_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id.uuidString]
            )
        }
    }

    /// Approve all pending cards for a given annotation.
    func approveBatch(annotationId: String) throws {
        let now = Date().iso8601String
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE quiz_cards SET is_pending = 0, due_at = ?, updated_at = ? WHERE annotation_id = ? AND is_pending = 1",
                arguments: [now, now, annotationId]
            )
        }
    }

    /// Delete all pending cards for a given annotation.
    func deletePendingCards(annotationId: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM quiz_cards WHERE annotation_id = ? AND is_pending = 1",
                arguments: [annotationId]
            )
        }
    }

    // MARK: - Collection-level Fetch

    /// Fetch all non-pending cards for a collection, ordered by due date.
    func fetchCards(forCollectionId collectionId: String) throws -> [QuizCard] {
        try database.dbQueue.read { db in
            let records = try QuizCardRecord
                .filter(QuizCardRecord.CodingKeys.collectionId == collectionId)
                .filter(QuizCardRecord.CodingKeys.isSuspended == false)
                .filter(QuizCardRecord.CodingKeys.isPending == false)
                .order(QuizCardRecord.CodingKeys.dueAt.asc)
                .fetchAll(db)
            return records.map { QuizCard(record: $0) }
        }
    }

    /// Count cards due for review in a collection (excludes pending).
    func dueCount(forCollectionId collectionId: String) throws -> Int {
        let now = Date().iso8601String
        return try database.dbQueue.read { db in
            try QuizCardRecord
                .filter(QuizCardRecord.CodingKeys.collectionId == collectionId)
                .filter(QuizCardRecord.CodingKeys.isSuspended == false)
                .filter(QuizCardRecord.CodingKeys.isPending == false)
                .filter(QuizCardRecord.CodingKeys.dueAt <= now)
                .fetchCount(db)
        }
    }

    /// Fetch pending cards for a collection (awaiting user review).
    func fetchPendingCards(forCollectionId collectionId: String) throws -> [QuizCard] {
        try database.dbQueue.read { db in
            let records = try QuizCardRecord
                .filter(QuizCardRecord.CodingKeys.collectionId == collectionId)
                .filter(QuizCardRecord.CodingKeys.isPending == true)
                .order(QuizCardRecord.CodingKeys.createdAt.desc)
                .fetchAll(db)
            return records.map { QuizCard(record: $0) }
        }
    }

    /// Fetch all non-pending cards for multiple items in a single query, ordered by due date.
    func fetchCards(forItemIds itemIds: [String]) throws -> [QuizCard] {
        guard !itemIds.isEmpty else { return [] }
        return try database.dbQueue.read { db in
            let records = try QuizCardRecord
                .filter(itemIds.contains(QuizCardRecord.CodingKeys.itemId))
                .filter(QuizCardRecord.CodingKeys.isSuspended == false)
                .filter(QuizCardRecord.CodingKeys.isPending == false)
                .order(QuizCardRecord.CodingKeys.dueAt.asc)
                .fetchAll(db)
            return records.map { QuizCard(record: $0) }
        }
    }

    /// Fetch pending cards for multiple items in a single query.
    func fetchPendingCards(forItemIds itemIds: [String]) throws -> [QuizCard] {
        guard !itemIds.isEmpty else { return [] }
        return try database.dbQueue.read { db in
            let records = try QuizCardRecord
                .filter(itemIds.contains(QuizCardRecord.CodingKeys.itemId))
                .filter(QuizCardRecord.CodingKeys.isPending == true)
                .order(QuizCardRecord.CodingKeys.createdAt.desc)
                .fetchAll(db)
            return records.map { QuizCard(record: $0) }
        }
    }

    /// Fetch all non-pending cards across all items, ordered by due date.
    func fetchAllCards() throws -> [QuizCard] {
        try database.dbQueue.read { db in
            let records = try QuizCardRecord
                .filter(QuizCardRecord.CodingKeys.isSuspended == false)
                .filter(QuizCardRecord.CodingKeys.isPending == false)
                .order(QuizCardRecord.CodingKeys.dueAt.asc)
                .fetchAll(db)
            return records.map { QuizCard(record: $0) }
        }
    }

    // MARK: - Create

    /// Create a new quiz card from parsed quiz content.
    @discardableResult
    func createCard(
        itemId: String,
        collectionId: String? = nil,
        conversationId: String? = nil,
        groupId: String? = nil,
        content: QuizContent,
        annotationId: String? = nil,
        sourceText: String? = nil,
        pageContext: String? = nil,
        isPending: Bool = false
    ) throws -> QuizCard {
        let cardId = UUID()
        let now = Date().iso8601String

        // Copy occlusion image to deck attachments if applicable
        let resolvedContent = try copyOcclusionImage(content: content, cardId: cardId)

        let contentData = try JSONEncoder().encode(resolvedContent)
        let contentJson = String(data: contentData, encoding: .utf8) ?? "{}"

        // Resolve collection from item if not provided
        let resolvedCollectionId: String? = collectionId ?? {
            try? database.dbQueue.read { db in
                try String.fetchOne(db, sql: """
                    SELECT collection_id FROM collection_items
                    WHERE item_id = ?
                    ORDER BY created_at ASC LIMIT 1
                """, arguments: [itemId])
            }
        }()

        var record = QuizCardRecord(
            id: cardId.uuidString,
            itemId: itemId,
            collectionId: resolvedCollectionId,
            conversationId: conversationId,
            groupId: groupId,
            type: resolvedContent.quizType.rawValue,
            contentJson: contentJson,
            state: QuizCardState.new.rawValue,
            dueAt: now,
            stability: 0,
            difficulty: 0,
            elapsedDays: 0,
            scheduledDays: 0,
            reps: 0,
            lapses: 0,
            lastReviewAt: nil,
            isSuspended: false,
            annotationId: annotationId,
            sourceText: sourceText,
            pageContext: pageContext,
            isPending: isPending,
            createdAt: now,
            updatedAt: now
        )
        try database.dbQueue.write { db in
            try record.insert(db)
        }

        return QuizCard(record: record)
    }

    // MARK: - Review

    /// Record a review and reschedule using the swift-fsrs library.
    ///
    /// Flow (same as Anki):
    /// 1. Convert our QuizCard → FSRS Card
    /// 2. Call fsrs.next() to get the rescheduled card + review log
    /// 3. Persist the FSRS output fields back to the database
    /// 4. Store the review log for history/analytics
    @discardableResult
    func recordReview(card: QuizCard, rating: ReviewRating) throws -> QuizCard {
        let now = Date()

        guard let result = QuizScheduler.schedule(card: card, rating: rating, now: now) else {
            throw NSError(domain: "QuizCardService", code: 500, userInfo: [NSLocalizedDescriptionKey: "FSRS scheduling failed"])
        }

        let nowStr = now.iso8601String
        try database.dbQueue.write { db in
            // Update card with FSRS output
            try db.execute(sql: """
                UPDATE quiz_cards SET
                    state = ?, due_at = ?, stability = ?, difficulty = ?,
                    elapsed_days = ?, scheduled_days = ?, reps = ?, lapses = ?,
                    last_review_at = ?, updated_at = ?
                WHERE id = ?
            """, arguments: [
                result.state.rawValue,
                result.dueAt.iso8601String,
                result.stability,
                result.difficulty,
                result.elapsedDays,
                result.scheduledDays,
                result.reps,
                result.lapses,
                nowStr, nowStr,
                card.id.uuidString
            ])

            // Insert review log
            var logRecord = QuizReviewLogRecord(
                id: UUID().uuidString,
                cardId: card.id.uuidString,
                rating: rating.rawValue,
                state: card.state.rawValue,
                scheduledDays: result.scheduledDays,
                elapsedDays: result.elapsedDays,
                reviewedAt: nowStr
            )
            try logRecord.insert(db)
        }

        // Re-fetch to return updated card
        var updated = try database.dbQueue.read { db in
            guard let record = try QuizCardRecord.fetchOne(db, key: card.id.uuidString) else {
                throw NSError(domain: "QuizCardService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Card not found"])
            }
            return QuizCard(record: record)
        }

        // Auto-suspend if leech threshold reached
        if rating == .again && QuizCardService.isLeech(updated) {
            let autoSuspend = UserDefaults.standard.bool(forKey: "quizCard_autoSuspendLeech")
            if autoSuspend {
                try suspendCard(id: updated.id, suspended: true)
                updated.isSuspended = true
            }
        }

        return updated
    }

    // MARK: - Image Occlusion Storage

    /// Copy the occlusion image from its source (e.g. chat attachments) to deck/attachments/{cardId}/.
    /// Returns updated content with the new absolute path.
    private func copyOcclusionImage(content: QuizContent, cardId: UUID) throws -> QuizContent {
        guard case .occlusion(let c) = content else { return content }
        let sourceURL = URL(fileURLWithPath: c.imageURL)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return content }

        let destDir = CatalogDatabase.deckAttachmentDirectory(cardId: cardId)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let destURL = CatalogDatabase.deckAttachmentURL(cardId: cardId, fileName: sourceURL.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        }

        let updatedContent = QuizContent.OcclusionContent(
            imageURL: destURL.path,
            masks: c.masks,
            labels: c.labels
        )
        return .occlusion(updatedContent)
    }

    // MARK: - Leech Detection

    /// Whether a card qualifies as a leech based on current settings.
    static func isLeech(_ card: QuizCard) -> Bool {
        let threshold = UserDefaults.standard.integer(forKey: "quizCard_leechThreshold")
        let effectiveThreshold = threshold > 0 ? threshold : 6
        return card.lapses >= effectiveThreshold
    }

    // MARK: - Delete

    func deleteCard(id: UUID) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM quiz_cards WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: - Suspend / Unsuspend

    func suspendCard(id: UUID, suspended: Bool) throws {
        let now = Date().iso8601String
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE quiz_cards SET is_suspended = ?, updated_at = ? WHERE id = ?",
                arguments: [suspended, now, id.uuidString]
            )
        }
    }
}
