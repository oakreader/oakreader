import Foundation
import GRDB

extension CatalogDatabase {
    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-greenfield") { db in
            // Items (bibliographic references)
            try db.create(table: "items") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("storage_key", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("author", .text).notNull().defaults(to: "")
                t.column("is_favorite", .integer).notNull().defaults(to: false)
                t.column("last_opened_at", .text)
                t.column("sync_status", .text).notNull().defaults(to: "local")
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("cite_key", .text)
            }
            try db.create(
                index: "idx_items_cite_key",
                on: "items",
                columns: ["cite_key"],
                unique: true,
                ifNotExists: true
            )

            // Attachments (files belonging to items)
            try db.create(table: "attachments") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("storage_key", .text).notNull().unique()
                t.column("file_name", .text).notNull()
                t.column("attachment_type", .text).notNull().defaults(to: "pdf")
                t.column("source_url", .text)
                t.column("file_size", .integer).notNull().defaults(to: 0)
                t.column("page_count", .integer).notNull().defaults(to: 0)
                t.column("is_primary", .integer).notNull().defaults(to: true)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_attachments_item_id", on: "attachments", columns: ["item_id"])

            // Collections (with smart collection support)
            try db.create(table: "collections") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull().defaults(to: "folder")
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("parent_id", .text).references("collections", onDelete: .cascade)
                t.column("is_smart", .integer).notNull().defaults(to: false)
                t.column("is_system", .integer).notNull().defaults(to: false)
                t.column("filter_rules", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            // Many-to-many: item <-> collection (was: document_collections)
            try db.create(table: "collection_items") { t in
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("collection_id", .text).notNull().references("collections", onDelete: .cascade)
                t.column("created_at", .text).notNull()
                t.primaryKey(["item_id", "collection_id"])
            }

            // Properties (NEW)
            try db.create(table: "properties") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()       // multi_select, single_select, number, text
                t.column("icon", .text).notNull().defaults(to: "tag")
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("is_system", .integer).notNull().defaults(to: false)
            }

            // Property options (for select-type properties)
            try db.create(table: "property_options") { t in
                t.column("id", .text).primaryKey()
                t.column("property_id", .text).notNull().references("properties", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("color_hex", .text).notNull().defaults(to: "999999")
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_property_options_property_id", on: "property_options", columns: ["property_id"])

            // Item property values (junction: item <-> property, replaces document_tags)
            try db.create(table: "item_property_values") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("property_id", .text).notNull().references("properties", onDelete: .cascade)
                t.column("option_id", .text).references("property_options", onDelete: .cascade)
                t.column("text_value", .text)
            }
            try db.create(index: "idx_item_property_values_item", on: "item_property_values", columns: ["item_id"])
            try db.create(index: "idx_item_property_values_property", on: "item_property_values", columns: ["property_id"])

            // Conversations (was: chat_sessions)
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("item_id", .text).references("items", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("message_count", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            // Notes (document_id → item_id)
            try db.create(table: "notes") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("is_pinned", .integer).notNull().defaults(to: false)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_notes_item_id", on: "notes", columns: ["item_id"])

            // Citations (was: reference_metadata)
            try db.create(table: "citations") { t in
                t.column("item_id", .text).primaryKey()
                    .references("items", onDelete: .cascade)
                t.column("csl_json", .text).notNull()
                t.column("csl_type", .text).notNull().defaults(to: "document")
                t.column("doi", .text)
                t.column("year", .integer)
                t.column("container_title", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_citations_doi", on: "citations", columns: ["doi"], ifNotExists: true)
            try db.create(index: "idx_citations_year", on: "citations", columns: ["year"], ifNotExists: true)
            try db.create(index: "idx_citations_type", on: "citations", columns: ["csl_type"], ifNotExists: true)

            // FTS5 full-text search
            try db.create(virtualTable: "items_fts", using: FTS5()) { t in
                t.synchronize(withTable: "items")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("author")
            }

            // MARK: - Seed System Properties

            // Tags property (multi_select)
            let tagsPropertyId = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO properties (id, name, type, icon, position, is_system)
                VALUES (?, 'Tags', 'multi_select', 'tag', 0, 1)
            """, arguments: [tagsPropertyId])

            // swiftlint:disable:next large_tuple
            let tagOptions: [(name: String, color: String, pos: Int)] = [
                ("Important", "FF6666", 0),
                ("To Read", "2EA8E5", 1),
                ("In Progress", "FF8C19", 2),
                ("Reviewed", "5FB236", 3),
            ]
            for opt in tagOptions {
                try db.execute(sql: """
                    INSERT INTO property_options (id, property_id, name, color_hex, position)
                    VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, tagsPropertyId, opt.name, opt.color, opt.pos])
            }

            // Status property (single_select)
            let statusPropertyId = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO properties (id, name, type, icon, position, is_system)
                VALUES (?, 'Status', 'single_select', 'circle.dotted', 1, 1)
            """, arguments: [statusPropertyId])

            // swiftlint:disable:next large_tuple
            let statusOptions: [(name: String, color: String, pos: Int)] = [
                ("Unread", "999999", 0),
                ("Reading", "2EA8E5", 1),
                ("Completed", "5FB236", 2),
                ("Archived", "A28AE5", 3),
            ]
            for opt in statusOptions {
                try db.execute(sql: """
                    INSERT INTO property_options (id, property_id, name, color_hex, position)
                    VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, statusPropertyId, opt.name, opt.color, opt.pos])
            }

            // Rating property (number, no options)
            let ratingPropertyId = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO properties (id, name, type, icon, position, is_system)
                VALUES (?, 'Rating', 'number', 'star', 2, 1)
            """, arguments: [ratingPropertyId])

            // MARK: - Seed System Smart Collections

            let now = Date().iso8601String
            // swiftlint:disable:next large_tuple
            let systemCollections: [(id: String, name: String, icon: String, order: Int, rules: String)] = [
                (SystemCollectionID.allItems.uuidString, "All Items", "books.vertical", 0,
                 #"{"match":"all","conditions":[]}"#),
                (SystemCollectionID.recentlyRead.uuidString, "Recently Read", "book", 1,
                 #"{"match":"all","conditions":[{"field":"last_opened_at","op":"within_days","value":"14"}]}"#),
                (SystemCollectionID.pdfs.uuidString, "PDFs", "doc.fill", 2,
                 #"{"match":"all","conditions":[{"field":"item_type","op":"eq","value":"pdf"}]}"#),
                (SystemCollectionID.webSnapshots.uuidString, "Web", "globe", 3,
                 #"{"match":"all","conditions":[{"field":"item_type","op":"eq","value":"webSnapshot"}]}"#),
                (SystemCollectionID.videos.uuidString, "Videos", "play.rectangle", 4,
                 #"{"match":"all","conditions":[{"field":"item_type","op":"eq","value":"embed"}]}"#),
            ]
            for sc in systemCollections {
                try db.execute(sql: """
                    INSERT INTO collections (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, filter_rules, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, NULL, 1, 1, ?, ?, ?)
                """, arguments: [sc.id, localUserId, sc.name, sc.icon, sc.order, sc.rules, now, now])
            }
        }

        migrator.registerMigration("v2-remove-inbox") { db in
            // Drop is_inbox column (SQLite requires table rebuild)
            if try db.columns(in: "items").contains(where: { $0.name == "is_inbox" }) {
                try db.alter(table: "items") { t in
                    t.drop(column: "is_inbox")
                }
            }

            // Delete the Inbox system collection
            let inboxId = "00000000-0000-0000-0000-000000000001"
            try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [inboxId])

            // Shift sort orders
            let reorder: [(id: String, order: Int)] = [
                ("00000000-0000-0000-0000-000000000002", 0), // All Items
                ("00000000-0000-0000-0000-000000000005", 1), // PDFs
                ("00000000-0000-0000-0000-000000000006", 2), // Web
                ("00000000-0000-0000-0000-000000000007", 3), // Videos
            ]
            for entry in reorder {
                try db.execute(
                    sql: "UPDATE collections SET sort_order = ? WHERE id = ?",
                    arguments: [entry.order, entry.id]
                )
            }
        }

        migrator.registerMigration("v3-recently-read") { db in
            let now = Date().iso8601String
            let rules = #"{"match":"all","conditions":[{"field":"last_opened_at","op":"within_days","value":"14"}]}"#
            try db.execute(sql: """
                INSERT OR IGNORE INTO collections (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, filter_rules, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, NULL, 1, 1, ?, ?, ?)
            """, arguments: [SystemCollectionID.recentlyRead.uuidString, localUserId, "Recently Read", "book", 2, rules, now, now])

            // Shift sort orders for collections after Recently Read
            let reorder: [(id: String, order: Int)] = [
                (SystemCollectionID.pdfs.uuidString, 3),
                (SystemCollectionID.webSnapshots.uuidString, 4),
                (SystemCollectionID.videos.uuidString, 5),
            ]
            for entry in reorder {
                try db.execute(
                    sql: "UPDATE collections SET sort_order = ? WHERE id = ?",
                    arguments: [entry.order, entry.id]
                )
            }
        }

        migrator.registerMigration("v3-last-position") { db in
            try db.alter(table: "items") { t in
                t.add(column: "last_position", .double)
            }
        }

        migrator.registerMigration("v4-annotations") { db in
            try db.create(table: "annotations") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("attachment_id", .text).notNull().references("attachments", onDelete: .cascade)
                t.column("key", .text).notNull().unique()
                t.column("type", .text).notNull()
                t.column("author_name", .text)
                t.column("text", .text)
                t.column("comment", .text)
                t.column("color", .text).notNull().defaults(to: "#ffd400")
                t.column("page_label", .text)
                t.column("sort_index", .text).notNull()
                t.column("position_kind", .text).notNull()
                t.column("position_json", .text).notNull()
                t.column("style_json", .text)
                t.column("source", .text).notNull().defaults(to: "oakreader")
                t.column("source_key", .text)
                t.column("is_external", .integer).notNull().defaults(to: false)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("deleted_at", .text)
            }
            try db.create(index: "idx_annotations_attachment_sort", on: "annotations", columns: ["attachment_id", "deleted_at", "sort_index"])
            try db.create(index: "idx_annotations_item_updated", on: "annotations", columns: ["item_id", "updated_at"])
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_annotations_source ON annotations(source, source_key) WHERE source_key IS NOT NULL
            """)
        }

        migrator.registerMigration("v5-characters") { db in
            try db.create(table: "characters") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            try db.create(table: "voice_calls") { t in
                t.column("id", .text).primaryKey()
                t.column("character_id", .text).notNull().references("characters", onDelete: .cascade)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("turn_count", .integer).notNull().defaults(to: 0)
                t.column("duration_seconds", .double).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_voice_calls_character_id", on: "voice_calls", columns: ["character_id"])

            // Seed default character (DB row + JSON config file)
            let characterId = UUID().uuidString
            let now = Date().iso8601String
            try db.execute(sql: """
                INSERT INTO characters (id, user_id, name, sort_order, created_at, updated_at)
                VALUES (?, ?, 'Oak', 0, ?, ?)
            """, arguments: [characterId, localUserId, now, now])

            // Write default config JSON
            if let uuid = UUID(uuidString: characterId) {
                let configURL = CatalogDatabase.characterConfigURL(characterId: uuid)
                let fm = FileManager.default
                try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let config = CharacterConfig.default
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(config)
                try data.write(to: configURL)
            }
        }

        migrator.registerMigration("v6-markdown-notes") { db in
            let now = Date().iso8601String
            let rules = #"{"match":"all","conditions":[{"field":"item_type","op":"eq","value":"markdown"}]}"#
            try db.execute(sql: """
                INSERT OR IGNORE INTO collections (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, filter_rules, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, NULL, 1, 1, ?, ?, ?)
            """, arguments: [SystemCollectionID.notes.uuidString, localUserId, "Notes", "doc.text", 6, rules, now, now])
        }

        migrator.registerMigration("v7-centralized-user-storage") { db in
            let fm = FileManager.default

            func ensureDirectory(_ url: URL) throws {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }

            func moveItemIfDestinationMissing(from source: URL, to destination: URL) throws {
                guard fm.fileExists(atPath: source.path) else { return }
                try ensureDirectory(destination.deletingLastPathComponent())
                guard !fm.fileExists(atPath: destination.path) else { return }
                try fm.moveItem(at: source, to: destination)
            }

            func availableURL(for url: URL) -> URL {
                guard fm.fileExists(atPath: url.path) else { return url }

                let parent = url.deletingLastPathComponent()
                let name = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                var index = 2
                while true {
                    let candidateName = ext.isEmpty ? "\(name)-\(index)" : "\(name)-\(index).\(ext)"
                    let candidate = parent.appendingPathComponent(candidateName)
                    if !fm.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                    index += 1
                }
            }

            func moveChildren(from source: URL, to destination: URL) throws {
                guard fm.fileExists(atPath: source.path) else { return }
                try ensureDirectory(destination)

                let children = try fm.contentsOfDirectory(
                    at: source,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for child in children {
                    let target = availableURL(for: destination.appendingPathComponent(child.lastPathComponent))
                    try fm.moveItem(at: child, to: target)
                }
            }

            func removeEmptyDirectory(_ url: URL) {
                guard fm.fileExists(atPath: url.path),
                      let children = try? fm.contentsOfDirectory(atPath: url.path),
                      children.isEmpty else { return }
                try? fm.removeItem(at: url)
            }

            try ensureDirectory(CatalogDatabase.storageDirectory)
            try ensureDirectory(CatalogDatabase.notesDirectory)
            try ensureDirectory(CatalogDatabase.notesAttachmentsDirectory)
            try ensureDirectory(CatalogDatabase.chatsDirectory)
            try ensureDirectory(CatalogDatabase.chatAttachmentsDirectory)
            try ensureDirectory(CatalogDatabase.callsDirectory)

            let itemRows = try Row.fetchAll(db, sql: "SELECT id, storage_key FROM items")
            for row in itemRows {
                let itemId: String = row["id"]
                let storageKey: String = row["storage_key"]
                let itemDirectory = CatalogDatabase.documentDirectory(storageKey: storageKey)

                // Older builds used storage/{itemKey}/files/{attachmentKey}/.
                let legacyFilesDirectory = itemDirectory.appendingPathComponent("files", isDirectory: true)
                let currentAttachmentsDirectory = itemDirectory.appendingPathComponent("attachments", isDirectory: true)
                try moveChildren(from: legacyFilesDirectory, to: currentAttachmentsDirectory)
                removeEmptyDirectory(legacyFilesDirectory)

                // Older builds kept markdown notes under each item.
                let legacyNotesDirectory = itemDirectory.appendingPathComponent("notes", isDirectory: true)
                let noteRows = try Row.fetchAll(
                    db,
                    sql: "SELECT id FROM notes WHERE item_id = ?",
                    arguments: [itemId]
                )
                for noteRow in noteRows {
                    let noteId: String = noteRow["id"]
                    let source = legacyNotesDirectory.appendingPathComponent("\(noteId).md")
                    let destination = CatalogDatabase.notesDirectory.appendingPathComponent("\(noteId).md")
                    try moveItemIfDestinationMissing(from: source, to: destination)
                }

                let legacyNoteAttachmentsDirectory = legacyNotesDirectory.appendingPathComponent("attachments", isDirectory: true)
                try moveChildren(from: legacyNoteAttachmentsDirectory, to: CatalogDatabase.notesAttachmentsDirectory)
                removeEmptyDirectory(legacyNoteAttachmentsDirectory)
                removeEmptyDirectory(legacyNotesDirectory)

                // Older builds kept chat JSONL files under storage/{itemKey}/sessions/.
                let legacySessionsDirectory = itemDirectory.appendingPathComponent("sessions", isDirectory: true)
                let conversationRows = try Row.fetchAll(
                    db,
                    sql: "SELECT id FROM conversations WHERE item_id = ?",
                    arguments: [itemId]
                )
                for conversationRow in conversationRows {
                    let sessionId: String = conversationRow["id"]
                    let source = legacySessionsDirectory.appendingPathComponent("\(sessionId).jsonl")
                    let destination = CatalogDatabase.chatsDirectory.appendingPathComponent("\(sessionId).jsonl")
                    try moveItemIfDestinationMissing(from: source, to: destination)

                    if let uuid = UUID(uuidString: sessionId) {
                        let legacyAttachmentDirectory = legacySessionsDirectory
                            .appendingPathComponent("\(sessionId)_attachments", isDirectory: true)
                        try moveChildren(
                            from: legacyAttachmentDirectory,
                            to: CatalogDatabase.chatAttachmentDirectory(sessionId: uuid)
                        )
                        removeEmptyDirectory(legacyAttachmentDirectory)
                    }
                }
                removeEmptyDirectory(legacySessionsDirectory)
            }

            // Earlier library-wide chat sessions lived under ~/OakReader/chat_sessions/.
            let legacyChatSessionsDirectory = CatalogDatabase.dataDirectory
                .appendingPathComponent("chat_sessions", isDirectory: true)
            let libraryConversationRows = try Row.fetchAll(
                db,
                sql: "SELECT id FROM conversations WHERE item_id IS NULL"
            )
            for conversationRow in libraryConversationRows {
                let sessionId: String = conversationRow["id"]
                let source = legacyChatSessionsDirectory.appendingPathComponent("\(sessionId).jsonl")
                let destination = CatalogDatabase.chatsDirectory.appendingPathComponent("\(sessionId).jsonl")
                try moveItemIfDestinationMissing(from: source, to: destination)

                if let uuid = UUID(uuidString: sessionId) {
                    let legacyAttachmentDirectory = legacyChatSessionsDirectory
                        .appendingPathComponent("\(sessionId)_attachments", isDirectory: true)
                    try moveChildren(
                        from: legacyAttachmentDirectory,
                        to: CatalogDatabase.chatAttachmentDirectory(sessionId: uuid)
                    )
                    removeEmptyDirectory(legacyAttachmentDirectory)
                }
            }
            removeEmptyDirectory(legacyChatSessionsDirectory)

            // Rename voice-calls to calls without assuming calls/ is empty.
            let legacyCallsDirectory = CatalogDatabase.dataDirectory
                .appendingPathComponent("voice-calls", isDirectory: true)
            try moveChildren(from: legacyCallsDirectory, to: CatalogDatabase.callsDirectory)
            removeEmptyDirectory(legacyCallsDirectory)
        }

        migrator.registerMigration("v8-scope-attachment-directories") { db in
            let fm = FileManager.default

            func ensureDirectory(_ url: URL) throws {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }

            func availableURL(for url: URL) -> URL {
                guard fm.fileExists(atPath: url.path) else { return url }

                let parent = url.deletingLastPathComponent()
                let name = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                var index = 2
                while true {
                    let candidateName = ext.isEmpty ? "\(name)-\(index)" : "\(name)-\(index).\(ext)"
                    let candidate = parent.appendingPathComponent(candidateName)
                    if !fm.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                    index += 1
                }
            }

            func moveChildren(from source: URL, to destination: URL) throws {
                guard fm.fileExists(atPath: source.path) else { return }
                try ensureDirectory(destination)

                let children = try fm.contentsOfDirectory(
                    at: source,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for child in children {
                    let target = availableURL(for: destination.appendingPathComponent(child.lastPathComponent))
                    try fm.moveItem(at: child, to: target)
                }
            }

            func removeEmptyDirectory(_ url: URL) {
                guard fm.fileExists(atPath: url.path),
                      let children = try? fm.contentsOfDirectory(atPath: url.path),
                      children.isEmpty else { return }
                try? fm.removeItem(at: url)
            }

            try ensureDirectory(CatalogDatabase.notesAttachmentsDirectory)
            try ensureDirectory(CatalogDatabase.chatAttachmentsDirectory)

            // Move old flat note attachment files to notes/attachments/{noteId}/ and
            // rewrite markdown links from attachments/file.png to attachments/{noteId}/file.png.
            let rootNoteAttachmentURLs = try fm.contentsOfDirectory(
                at: CatalogDatabase.notesAttachmentsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory != true
            }

            if !rootNoteAttachmentURLs.isEmpty {
                let noteRows = try Row.fetchAll(db, sql: "SELECT id FROM notes")
                for noteRow in noteRows {
                    let noteId: String = noteRow["id"]
                    guard let noteUUID = UUID(uuidString: noteId) else { continue }

                    let noteURL = CatalogDatabase.noteFileURL(noteId: noteUUID)
                    guard fm.fileExists(atPath: noteURL.path),
                          var content = try? String(contentsOf: noteURL, encoding: .utf8)
                    else { continue }

                    var didRewrite = false
                    let noteAttachmentDirectory = CatalogDatabase.noteAttachmentDirectory(noteId: noteUUID)
                    for attachmentURL in rootNoteAttachmentURLs {
                        let fileName = attachmentURL.lastPathComponent
                        let oldReference = "attachments/\(fileName)"
                        guard content.contains(oldReference) else { continue }

                        try ensureDirectory(noteAttachmentDirectory)
                        let destination = noteAttachmentDirectory.appendingPathComponent(fileName)
                        if !fm.fileExists(atPath: destination.path) {
                            try fm.copyItem(at: attachmentURL, to: destination)
                        }
                        content = content.replacingOccurrences(
                            of: oldReference,
                            with: "attachments/\(noteId)/\(fileName)"
                        )
                        didRewrite = true
                    }

                    if didRewrite {
                        try content.write(to: noteURL, atomically: true, encoding: .utf8)
                    }
                }

                let legacyDirectory = CatalogDatabase.notesAttachmentsDirectory
                    .appendingPathComponent("_legacy", isDirectory: true)
                for attachmentURL in rootNoteAttachmentURLs where fm.fileExists(atPath: attachmentURL.path) {
                    let destination = availableURL(for: legacyDirectory.appendingPathComponent(attachmentURL.lastPathComponent))
                    try ensureDirectory(legacyDirectory)
                    try fm.moveItem(at: attachmentURL, to: destination)
                }
            }

            // Move old chats/{sessionId}_attachments folders to chats/attachments/{sessionId}/.
            let chatRootChildren = try fm.contentsOfDirectory(
                at: CatalogDatabase.chatsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for child in chatRootChildren {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }

                let name = child.lastPathComponent
                guard name.hasSuffix("_attachments") else { continue }

                let sessionId = String(name.dropLast("_attachments".count))
                guard let uuid = UUID(uuidString: sessionId) else { continue }

                try moveChildren(from: child, to: CatalogDatabase.chatAttachmentDirectory(sessionId: uuid))
                removeEmptyDirectory(child)
            }
        }

        migrator.registerMigration("v9-import-source") { db in
            try db.alter(table: "items") { t in
                t.add(column: "source", .text)
                t.add(column: "source_key", .text)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_items_source ON items(source, source_key)
                WHERE source IS NOT NULL AND source_key IS NOT NULL
            """)

            try db.alter(table: "collections") { t in
                t.add(column: "source", .text)
                t.add(column: "source_key", .text)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_collections_source ON collections(source, source_key)
                WHERE source IS NOT NULL AND source_key IS NOT NULL
            """)
        }

        migrator.registerMigration("v10-collection-items-index") { db in
            try db.create(
                index: "idx_collection_items_collection_id",
                on: "collection_items",
                columns: ["collection_id"],
                ifNotExists: true
            )
        }

        // Regenerate all cite keys using the improved {auth}{TitleWords}{year} formula.
        migrator.registerMigration("v11-regenerate-cite-keys") { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.id, i.title, i.author, c.csl_json, c.year
                FROM items i
                LEFT JOIN citations c ON c.item_id = i.id
            """)

            // Collect all new keys first, then resolve collisions
            var usedKeys: [String: Int] = [:]  // base → count

            struct PendingKey {
                let itemId: String
                let base: String
            }
            var pending: [PendingKey] = []

            for row in rows {
                let itemId: String = row["id"]
                let title: String = row["title"]
                let author: String = row["author"]
                let cslJson: String? = row["csl_json"]
                let year: Int? = row["year"]

                let base: String
                if let json = cslJson,
                   let data = json.data(using: .utf8),
                   let csl = try? JSONDecoder().decode(CSLItem.self, from: data)
                {
                    let authorPart = CiteKeyService.extractAuthorKey(csl: csl)
                    let titlePart = CiteKeyService.extractTitleWords(csl: csl)
                    let yearPart = csl.issued?.year.map { "\($0)" } ?? ""
                    if authorPart.isEmpty, !titlePart.isEmpty {
                        base = CiteKeyService.lowercaseFirstWord(titlePart) + yearPart
                    } else {
                        base = authorPart + titlePart + yearPart
                    }
                } else {
                    let authorPart = CiteKeyService.processAuthorName(author)
                    let titlePart = title.isEmpty ? "" : CiteKeyService.extractTitleWordsFromString(title)
                    let yearPart = year.map { "\($0)" } ?? ""
                    if authorPart.isEmpty, !titlePart.isEmpty {
                        base = CiteKeyService.lowercaseFirstWord(titlePart) + yearPart
                    } else {
                        base = authorPart + titlePart + yearPart
                    }
                }

                guard !base.isEmpty else { continue }
                pending.append(PendingKey(itemId: itemId, base: base))
                usedKeys[base, default: 0] += 1
            }

            // Track suffix counters per base for collision resolution
            var suffixCounters: [String: Int] = [:]
            let now = Date().iso8601String

            for entry in pending {
                let candidate: String
                if usedKeys[entry.base, default: 0] <= 1 {
                    candidate = entry.base
                } else {
                    let idx = suffixCounters[entry.base, default: 0]
                    if idx == 0 {
                        candidate = entry.base
                    } else {
                        candidate = entry.base + String(UnicodeScalar(UInt8(96 + idx)))
                    }
                    suffixCounters[entry.base] = idx + 1
                }

                try db.execute(
                    sql: "UPDATE items SET cite_key = ?, updated_at = ? WHERE id = ?",
                    arguments: [candidate, now, entry.itemId]
                )
            }
        }

        migrator.registerMigration("v12-duplicates-collection") { db in
            let now = Date().iso8601String
            try db.execute(sql: """
                INSERT OR IGNORE INTO collections (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, filter_rules, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, NULL, 1, 1, NULL, ?, ?)
            """, arguments: [SystemCollectionID.duplicates.uuidString, localUserId, "Duplicates", "square.on.square", 7, now, now])
        }

        migrator.registerMigration("v13-search-index") { db in
            // Add abstract column to citations for direct search (avoids JSON parsing)
            try db.alter(table: "citations") { t in
                t.add(column: "abstract", .text)
            }

            // Populate abstract from existing csl_json
            try db.execute(sql: """
                UPDATE citations
                SET abstract = json_extract(csl_json, '$.abstract')
                WHERE json_valid(csl_json) AND json_extract(csl_json, '$.abstract') IS NOT NULL
            """)

            // Index on container_title for journal searches
            try db.create(
                index: "idx_citations_container_title",
                on: "citations",
                columns: ["container_title"],
                ifNotExists: true
            )
        }

        migrator.registerMigration("v14-semantic-chunks") { db in
            try db.create(table: "semantic_chunks") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("chunk_type", .text).notNull()    // "abstract" or "page"
                t.column("page_start", .integer)
                t.column("page_end", .integer)
                t.column("token_count", .integer)
                t.column("created_at", .text).notNull()
                t.column("embedding", .blob)               // raw Float32 bytes
                t.column("embedding_dim", .integer)         // e.g. 1024
                t.column("chunk_text", .text)               // original text for excerpts
                t.column("embedding_model", .text)          // e.g. "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
                t.column("embedding_provider", .text)       // "local" or future cloud providers
            }
            try db.create(index: "idx_semantic_chunks_item_id", on: "semantic_chunks", columns: ["item_id"])
        }

        return migrator
    }

}
