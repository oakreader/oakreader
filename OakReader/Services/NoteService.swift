import Foundation
import GRDB

/// Stateless service for note CRUD operations.
/// Metadata lives in the GRDB `notes` table; content lives as `.md` files on disk.
/// Storage layout: ~/OakReader/notes/{noteId}.md
struct NoteService {
    let database: CatalogDatabase

    // MARK: - Fetch

    /// Fetch all notes for a document, ordered by pinned-first then updated_at descending.
    func fetchNotes(forItemId itemId: String) throws -> [Note] {
        try database.dbQueue.read { db in
            let records = try NoteRecord
                .filter(NoteRecord.CodingKeys.itemId == itemId)
                .order(
                    NoteRecord.CodingKeys.isPinned.desc,
                    NoteRecord.CodingKeys.updatedAt.desc
                )
                .fetchAll(db)
            return records.map { Note(record: $0) }
        }
    }

    /// Fetch all notes for multiple items in a single query, grouped by item ID.
    func fetchNotes(forItemIds itemIds: [String]) throws -> [String: [Note]] {
        guard !itemIds.isEmpty else { return [:] }
        return try database.dbQueue.read { db in
            let records = try NoteRecord
                .filter(itemIds.contains(NoteRecord.CodingKeys.itemId))
                .order(
                    NoteRecord.CodingKeys.isPinned.desc,
                    NoteRecord.CodingKeys.updatedAt.desc
                )
                .fetchAll(db)
            var grouped: [String: [Note]] = [:]
            for record in records {
                grouped[record.itemId, default: []].append(Note(record: record))
            }
            return grouped
        }
    }

    // MARK: - Content (filesystem)

    /// Load note content from the .md file on disk.
    func loadContent(noteId: UUID) -> String {
        let url = CatalogDatabase.noteFileURL(noteId: noteId)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Save note content to the .md file and update metadata in the database.
    func saveContent(noteId: UUID, title: String, content: String) throws {
        let url = CatalogDatabase.noteFileURL(noteId: noteId)
        try content.write(to: url, atomically: true, encoding: .utf8)

        let now = Date().iso8601String
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET title = ?, updated_at = ? WHERE id = ?",
                arguments: [title, now, noteId.uuidString]
            )
        }
    }

    // MARK: - Create

    @discardableResult
    func createNote(itemId: String) throws -> Note {
        let noteId = UUID()
        let now = Date().iso8601String

        var record = NoteRecord(
            id: noteId.uuidString,
            userId: localUserId,
            itemId: itemId,
            title: "",
            isPinned: false,
            createdAt: now,
            updatedAt: now
        )
        try database.dbQueue.write { db in
            try record.insert(db)
        }

        // Create the empty .md file
        let url = CatalogDatabase.noteFileURL(noteId: noteId)
        try "".write(to: url, atomically: true, encoding: .utf8)

        return Note(record: record)
    }

    // MARK: - Pin

    func togglePin(id: UUID, isPinned: Bool) throws {
        let now = Date().iso8601String
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notes SET is_pinned = ?, updated_at = ? WHERE id = ?",
                arguments: [isPinned, now, id.uuidString]
            )
        }
    }

    // MARK: - Delete

    func deleteNote(id: UUID) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id.uuidString])
        }
        let url = CatalogDatabase.noteFileURL(noteId: id)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: CatalogDatabase.noteAttachmentDirectory(noteId: id))
    }

    // MARK: - Image attachment

    /// Save image data to the notes attachments directory.
    /// Returns the relative path suitable for markdown insertion (e.g., "attachments/{noteId}/uuid.png").
    func saveImage(noteId: UUID, data: Data, fileExtension: String = "png") throws -> String {
        let attachDir = CatalogDatabase.noteAttachmentDirectory(noteId: noteId)
        try FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)

        let fileName = "\(UUID().uuidString).\(fileExtension)"
        let url = attachDir.appendingPathComponent(fileName)
        try data.write(to: url)

        return "attachments/\(noteId.uuidString)/\(fileName)"
    }

    /// Absolute URL for the notes directory (for WKWebView base URL).
    var notesDirectoryURL: URL {
        CatalogDatabase.notesDirectory
    }
}
