import Foundation
import GRDB

/// Stateless service for conversation CRUD operations.
/// Metadata lives in the GRDB `conversations` table; message content lives as JSONL files on disk.
struct ConversationService {
    let database: CatalogDatabase

    // MARK: - Fetch

    /// Fetch all conversations for a specific item, ordered by updated_at descending.
    func fetchSessions(forItemId itemId: String) throws -> [ConversationMeta] {
        let records = try database.dbQueue.read { db in
            try ConversationRecord
                .filter(ConversationRecord.CodingKeys.itemId == itemId)
                .order(ConversationRecord.CodingKeys.updatedAt.desc)
                .fetchAll(db)
        }
        return records.map { ConversationMeta(record: $0, snippet: snippet(forId: $0.id)) }
    }

    /// Fetch all library conversations (item_id IS NULL), ordered by updated_at descending.
    func fetchLibrarySessions() throws -> [ConversationMeta] {
        let records = try database.dbQueue.read { db in
            try ConversationRecord
                .filter(ConversationRecord.CodingKeys.itemId == nil)
                .order(ConversationRecord.CodingKeys.updatedAt.desc)
                .fetchAll(db)
        }
        return records.map { ConversationMeta(record: $0, snippet: snippet(forId: $0.id)) }
    }

    // MARK: - Snippet

    /// Minimal projection of a persisted JSONL turn — just enough to find the
    /// first user message for the history list's teaser line.
    private struct SnippetTurn: Decodable {
        let role: String
        let content: String
    }

    /// Extracts a short teaser (first user message) from a session's JSONL file.
    /// Reads only a bounded prefix so a long conversation doesn't cost a full file read.
    private func snippet(forId idString: String) -> String {
        guard let id = UUID(uuidString: idString) else { return "" }
        let url = CatalogDatabase.chatFileURL(sessionId: id)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        // The first user turn is almost always the first line; 64 KB covers it.
        let prefix = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let text = String(data: prefix, encoding: .utf8) else { return "" }

        // Only consider complete lines (drop a possibly-truncated trailing line).
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let completeLines = text.hasSuffix("\n") ? lines : lines.dropLast()

        let decoder = JSONDecoder()
        for line in completeLines {
            guard let data = line.data(using: .utf8),
                  let turn = try? decoder.decode(SnippetTurn.self, from: data),
                  turn.role == "user" else { continue }
            return Self.cleanSnippet(turn.content)
        }
        return ""
    }

    /// Strips inline skill tags and collapses whitespace into a single tidy line.
    private static func cleanSnippet(_ raw: String) -> String {
        var s = raw
        // Drop leading `[[skill:…]]` / `[[ref:…]]` tags used for durable UI rendering.
        while let open = s.range(of: "[["), let close = s.range(of: "]]"),
              open.lowerBound == s.startIndex || s[s.startIndex..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s = String(s[close.upperBound...])
        }
        return s
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
