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
        let contentData = try JSONEncoder().encode(content)
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
            type: content.quizType.rawValue,
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
        return try database.dbQueue.read { db in
            guard let record = try QuizCardRecord.fetchOne(db, key: card.id.uuidString) else {
                throw NSError(domain: "QuizCardService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Card not found"])
            }
            return QuizCard(record: record)
        }
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
