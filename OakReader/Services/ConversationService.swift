import Foundation
import GRDB

/// Stateless service for conversation CRUD operations.
/// Metadata lives in the GRDB `conversations` table; message content lives as JSONL files on disk.
struct ConversationService {
    let database: CatalogDatabase

    // MARK: - Fetch

    /// Fetch all conversations for a specific item, ordered by updated_at descending.
    func fetchSessions(forItemId itemId: String) throws -> [ConversationMeta] {
        try database.dbQueue.read { db in
            let records = try ConversationRecord
                .filter(ConversationRecord.CodingKeys.itemId == itemId)
                .order(ConversationRecord.CodingKeys.updatedAt.desc)
                .fetchAll(db)
            return records.map { ConversationMeta(record: $0) }
        }
    }

    /// Fetch all library conversations (item_id IS NULL), ordered by updated_at descending.
    func fetchLibrarySessions() throws -> [ConversationMeta] {
        try database.dbQueue.read { db in
            let records = try ConversationRecord
                .filter(ConversationRecord.CodingKeys.itemId == nil)
                .order(ConversationRecord.CodingKeys.updatedAt.desc)
                .fetchAll(db)
            return records.map { ConversationMeta(record: $0) }
        }
    }

    /// Fetch workspace conversations for a collection, ordered by updated_at descending.
    /// Workspace sessions use the convention `itemId = "workspace:{collectionId}"`.
    func fetchWorkspaceSessions(forCollectionId collectionId: UUID) throws -> [ConversationMeta] {
        let itemId = "workspace:\(collectionId.uuidString)"
        return try fetchSessions(forItemId: itemId)
    }

    // MARK: - Create

    @discardableResult
    func createSession(id: UUID, title: String, itemId: String?) throws -> ConversationMeta {
        let now = Date().iso8601String
        var record = ConversationRecord(
            id: id.uuidString,
            userId: localUserId,
            itemId: itemId,
            title: title,
            messageCount: 0,
            createdAt: now,
            updatedAt: now
        )
        try database.dbQueue.write { db in
            try record.insert(db)
        }
        return ConversationMeta(record: record)
    }

    // MARK: - Update

    func updateSession(id: UUID, title: String, messageCount: Int) throws {
        let now = Date().iso8601String
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversations SET title = ?, message_count = ?, updated_at = ? WHERE id = ?",
                arguments: [title, messageCount, now, id.uuidString]
            )
        }
    }

    // MARK: - Delete

    func deleteSession(id: UUID) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id.uuidString])
        }
    }
}
