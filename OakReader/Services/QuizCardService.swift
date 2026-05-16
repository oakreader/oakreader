import Foundation
import GRDB

/// Stateless service for quiz card CRUD and review operations.
struct QuizCardService {
    let database: CatalogDatabase

    // MARK: - Fetch

    /// Fetch all cards for a document, ordered by due date.
    func fetchCards(forItemId itemId: String) throws -> [QuizCard] {
        try database.dbQueue.read { db in
            let records = try QuizCardRecord
                .filter(QuizCardRecord.CodingKeys.itemId == itemId)
                .filter(QuizCardRecord.CodingKeys.isSuspended == false)
                .order(QuizCardRecord.CodingKeys.dueAt.asc)
                .fetchAll(db)
            return records.map { QuizCard(record: $0) }
        }
    }

    /// Fetch cards that are currently due for review.
    func fetchDueCards(forItemId itemId: String, limit: Int = 50) throws -> [QuizCard] {
        let now = Date().iso8601String
        return try database.dbQueue.read { db in
            let records = try QuizCardRecord
                .filter(QuizCardRecord.CodingKeys.itemId == itemId)
                .filter(QuizCardRecord.CodingKeys.isSuspended == false)
                .filter(QuizCardRecord.CodingKeys.dueAt <= now)
                .order(QuizCardRecord.CodingKeys.dueAt.asc)
                .limit(limit)
                .fetchAll(db)
            return records.map { QuizCard(record: $0) }
        }
    }

    /// Count cards due for review.
    func dueCount(forItemId itemId: String) throws -> Int {
        let now = Date().iso8601String
        return try database.dbQueue.read { db in
            try QuizCardRecord
                .filter(QuizCardRecord.CodingKeys.itemId == itemId)
                .filter(QuizCardRecord.CodingKeys.isSuspended == false)
                .filter(QuizCardRecord.CodingKeys.dueAt <= now)
                .fetchCount(db)
        }
    }

    // MARK: - Create

    /// Create a new quiz card from parsed quiz content.
    @discardableResult
    func createCard(
        itemId: String,
        conversationId: String? = nil,
        groupId: String? = nil,
        content: QuizContent
    ) throws -> QuizCard {
        let cardId = UUID()
        let now = Date().iso8601String
        let contentData = try JSONEncoder().encode(content)
        let contentJson = String(data: contentData, encoding: .utf8) ?? "{}"

        var record = QuizCardRecord(
            id: cardId.uuidString,
            itemId: itemId,
            conversationId: conversationId,
            groupId: groupId,
            type: content.quizType.rawValue,
            contentJson: contentJson,
            state: CardState.new.rawValue,
            dueAt: now,
            stability: 0,
            difficulty: 0,
            elapsedDays: 0,
            scheduledDays: 0,
            reps: 0,
            lapses: 0,
            lastReviewAt: nil,
            isSuspended: false,
            createdAt: now,
            updatedAt: now
        )
        try database.dbQueue.write { db in
            try record.insert(db)
        }

        return QuizCard(record: record)
    }

    // MARK: - Review

    /// Record a review and reschedule using FSRS.
    @discardableResult
    func recordReview(card: QuizCard, rating: ReviewRating) throws -> QuizCard {
        let now = Date()
        let result = QuizScheduler.schedule(card: card, rating: rating, now: now)

        let nowStr = now.iso8601String
        try database.dbQueue.write { db in
            // Update card
            try db.execute(sql: """
                UPDATE quiz_cards SET
                    state = ?, due_at = ?, stability = ?, difficulty = ?,
                    elapsed_days = ?, scheduled_days = ?, reps = reps + 1,
                    lapses = CASE WHEN ? = 'relearning' AND state = 'review' THEN lapses + 1 ELSE lapses END,
                    last_review_at = ?, updated_at = ?
                WHERE id = ?
            """, arguments: [
                result.state.rawValue, result.dueAt.iso8601String,
                result.stability, result.difficulty,
                result.elapsedDays, result.scheduledDays,
                result.state.rawValue, nowStr, nowStr,
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
