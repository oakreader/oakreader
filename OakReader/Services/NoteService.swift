import Foundation
import GRDB

/// Stateless service for note CRUD operations.
/// Metadata lives in the GRDB `notes` table; content lives as `.md` files on disk.
/// Storage layout: ~/OakReader/storage/{storageKey}/notes/{noteId}.md
struct NoteService {
    let database: CatalogDatabase

    // MARK: - Fetch

    /// Fetch all notes for a document, ordered by pinned-first then updated_at descending.
    func fetchNotes(forDocumentId documentId: String) throws -> [Note] {
        try database.dbQueue.read { db in
            let records = try NoteRecord
                .filter(NoteRecord.CodingKeys.documentId == documentId)
                .order(
                    NoteRecord.CodingKeys.isPinned.desc,
                    NoteRecord.CodingKeys.updatedAt.desc
                )
                .fetchAll(db)
            return records.map { Note(record: $0) }
        }
    }

    // MARK: - Content (filesystem)

    /// Load note content from the .md file on disk.
    func loadContent(noteId: UUID, storageKey: String) -> String {
        let url = noteFileURL(noteId: noteId, storageKey: storageKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Save note content to the .md file and update metadata in the database.
    func saveContent(noteId: UUID, storageKey: String, title: String, content: String) throws {
        let notesDir = CatalogDatabase.documentNotesDirectory(storageKey: storageKey)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        let url = noteFileURL(noteId: noteId, storageKey: storageKey)
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
    func createNote(documentId: String, storageKey: String) throws -> Note {
        let noteId = UUID()
        let now = Date().iso8601String

        var record = NoteRecord(
            id: noteId.uuidString,
            userId: localUserId,
            documentId: documentId,
            title: "",
            isPinned: false,
            createdAt: now,
            updatedAt: now
        )
        try database.dbQueue.write { db in
            try record.insert(db)
        }

        // Create the empty .md file
        let notesDir = CatalogDatabase.documentNotesDirectory(storageKey: storageKey)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let url = noteFileURL(noteId: noteId, storageKey: storageKey)
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

    func deleteNote(id: UUID, storageKey: String) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id.uuidString])
        }
        // Remove the .md file
        let url = noteFileURL(noteId: id, storageKey: storageKey)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Image attachment

    /// Save image data to the notes attachments directory.
    /// Returns the relative path suitable for markdown insertion (e.g., "attachments/uuid.png").
    func saveImage(data: Data, storageKey: String, fileExtension: String = "png") throws -> String {
        let attachDir = CatalogDatabase.documentNotesAttachmentsDirectory(storageKey: storageKey)
        try FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)

        let fileName = "\(UUID().uuidString).\(fileExtension)"
        let url = attachDir.appendingPathComponent(fileName)
        try data.write(to: url)

        return "attachments/\(fileName)"
    }

    /// Absolute URL for the notes directory (for WKWebView base URL).
    func notesDirectoryURL(storageKey: String) -> URL {
        CatalogDatabase.documentNotesDirectory(storageKey: storageKey)
    }

    // MARK: - Private

    private func noteFileURL(noteId: UUID, storageKey: String) -> URL {
        CatalogDatabase.documentNotesDirectory(storageKey: storageKey)
            .appendingPathComponent("\(noteId.uuidString).md")
    }
}
