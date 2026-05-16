import Foundation
import GRDB

extension CatalogDatabase {
    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // MARK: v1 — Items & Attachments

        migrator.registerMigration("v1-items-attachments") { db in
            try db.create(table: "items") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("storage_key", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("author", .text).notNull().defaults(to: "")
                t.column("is_favorite", .integer).notNull().defaults(to: false)
                t.column("last_opened_at", .text)
                t.column("last_position", .double)
                t.column("sync_status", .text).notNull().defaults(to: "local")
                t.column("cite_key", .text)
                t.column("source", .text)
                t.column("source_key", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_items_cite_key", on: "items", columns: ["cite_key"], unique: true, ifNotExists: true)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_items_source ON items(source, source_key)
                WHERE source IS NOT NULL AND source_key IS NOT NULL
            """)

            try db.create(table: "attachments") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("storage_key", .text).notNull().unique()
                t.column("file_name", .text).notNull()
                t.column("content_type", .text).notNull().defaults(to: "pdf")
                t.column("link_mode", .text).notNull().defaults(to: "importedFile")
                t.column("source_url", .text)
                t.column("file_size", .integer).notNull().defaults(to: 0)
                t.column("page_count", .integer).notNull().defaults(to: 0)
                t.column("is_primary", .integer).notNull().defaults(to: true)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_attachments_item_id", on: "attachments", columns: ["item_id"])
        }

        // MARK: v2 — Collections

        migrator.registerMigration("v2-collections") { db in
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
                t.column("source", .text)
                t.column("source_key", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_collections_source ON collections(source, source_key)
                WHERE source IS NOT NULL AND source_key IS NOT NULL
            """)

            try db.create(table: "collection_items") { t in
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("collection_id", .text).notNull().references("collections", onDelete: .cascade)
                t.column("created_at", .text).notNull()
                t.primaryKey(["item_id", "collection_id"])
            }
            try db.create(index: "idx_collection_items_collection_id", on: "collection_items", columns: ["collection_id"], ifNotExists: true)

            // Seed system smart collections
            let now = Date().iso8601String
            // swiftlint:disable:next large_tuple
            let systemCollections: [(id: String, name: String, icon: String, order: Int, rules: String?)] = [
                (SystemCollectionID.allItems.uuidString, "All Items", "books.vertical", 0,
                 #"{"match":"all","conditions":[]}"#),
                (SystemCollectionID.recentlyRead.uuidString, "Recently Read", "book", 1,
                 #"{"match":"all","conditions":[{"field":"last_opened_at","op":"within_days","value":"14"}]}"#),
                (SystemCollectionID.pdfs.uuidString, "PDFs", "doc.fill", 2,
                 #"{"match":"all","conditions":[{"field":"content_type","op":"eq","value":"pdf"}]}"#),
                (SystemCollectionID.html.uuidString, "Web", "globe", 3,
                 #"{"match":"all","conditions":[{"field":"content_type","op":"eq","value":"html"}]}"#),
                (SystemCollectionID.videos.uuidString, "Videos", "play.rectangle", 4,
                 #"{"match":"all","conditions":[{"field":"content_type","op":"eq","value":"video"}]}"#),
                (SystemCollectionID.notes.uuidString, "Notes", "doc.text", 5,
                 #"{"match":"all","conditions":[{"field":"content_type","op":"eq","value":"markdown"}]}"#),
                (SystemCollectionID.duplicates.uuidString, "Duplicates", "square.on.square", 6, nil),
                (SystemCollectionID.xBookmarks.uuidString, "X Bookmarks", "icon-x", 7,
                 #"{"match":"all","conditions":[{"field":"source","op":"eq","value":"x_bookmarks"}]}"#),
                (SystemCollectionID.githubStars.uuidString, "GitHub Stars", "icon-github", 8,
                 #"{"match":"all","conditions":[{"field":"source","op":"eq","value":"github_stars"}]}"#),
            ]
            for sc in systemCollections {
                try db.execute(sql: """
                    INSERT INTO collections (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, filter_rules, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, NULL, 1, 1, ?, ?, ?)
                """, arguments: [sc.id, localUserId, sc.name, sc.icon, sc.order, sc.rules, now, now])
            }
        }

        // MARK: v3 — Properties

        migrator.registerMigration("v3-properties") { db in
            try db.create(table: "properties") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("icon", .text).notNull().defaults(to: "tag")
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("is_system", .integer).notNull().defaults(to: false)
            }

            try db.create(table: "property_options") { t in
                t.column("id", .text).primaryKey()
                t.column("property_id", .text).notNull().references("properties", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("color_hex", .text).notNull().defaults(to: "999999")
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_property_options_property_id", on: "property_options", columns: ["property_id"])

            try db.create(table: "item_property_values") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("property_id", .text).notNull().references("properties", onDelete: .cascade)
                t.column("option_id", .text).references("property_options", onDelete: .cascade)
                t.column("text_value", .text)
            }
            try db.create(index: "idx_item_property_values_item", on: "item_property_values", columns: ["item_id"])
            try db.create(index: "idx_item_property_values_property", on: "item_property_values", columns: ["property_id"])

            // Seed system properties
            let tagsPropertyId = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO properties (id, name, type, icon, position, is_system)
                VALUES (?, 'Tags', 'multi_select', 'tag', 0, 1)
            """, arguments: [tagsPropertyId])

            // swiftlint:disable:next large_tuple
            let tagOptions: [(name: String, color: String, pos: Int)] = [
                ("Important", "FF6666", 0), ("To Read", "2EA8E5", 1),
                ("In Progress", "FF8C19", 2), ("Reviewed", "5FB236", 3),
            ]
            for opt in tagOptions {
                try db.execute(sql: """
                    INSERT INTO property_options (id, property_id, name, color_hex, position)
                    VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, tagsPropertyId, opt.name, opt.color, opt.pos])
            }

            let statusPropertyId = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO properties (id, name, type, icon, position, is_system)
                VALUES (?, 'Status', 'single_select', 'circle.dotted', 1, 1)
            """, arguments: [statusPropertyId])

            // swiftlint:disable:next large_tuple
            let statusOptions: [(name: String, color: String, pos: Int)] = [
                ("Unread", "999999", 0), ("Reading", "2EA8E5", 1),
                ("Completed", "5FB236", 2), ("Archived", "A28AE5", 3),
            ]
            for opt in statusOptions {
                try db.execute(sql: """
                    INSERT INTO property_options (id, property_id, name, color_hex, position)
                    VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, statusPropertyId, opt.name, opt.color, opt.pos])
            }

            try db.execute(sql: """
                INSERT INTO properties (id, name, type, icon, position, is_system)
                VALUES (?, 'Rating', 'number', 'star', 2, 1)
            """, arguments: [UUID().uuidString])
        }

        // MARK: v4 — Notes & Conversations

        migrator.registerMigration("v4-notes-conversations") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("user_id", .text).notNull()
                t.column("item_id", .text).references("items", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("message_count", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

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
        }

        // MARK: v5 — Citations

        migrator.registerMigration("v5-citations") { db in
            try db.create(table: "citations") { t in
                t.column("item_id", .text).primaryKey()
                    .references("items", onDelete: .cascade)
                t.column("csl_json", .text).notNull()
                t.column("csl_type", .text).notNull().defaults(to: "document")
                t.column("doi", .text)
                t.column("year", .integer)
                t.column("container_title", .text)
                t.column("abstract", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_citations_doi", on: "citations", columns: ["doi"], ifNotExists: true)
            try db.create(index: "idx_citations_year", on: "citations", columns: ["year"], ifNotExists: true)
            try db.create(index: "idx_citations_type", on: "citations", columns: ["csl_type"], ifNotExists: true)
            try db.create(index: "idx_citations_container_title", on: "citations", columns: ["container_title"], ifNotExists: true)
        }

        // MARK: v6 — Annotations

        migrator.registerMigration("v6-annotations") { db in
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

        // MARK: v7 — Characters & Voice Calls

        migrator.registerMigration("v7-characters") { db in
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

            // Seed default character (v10 migration drops this table)
            let characterId = UUID().uuidString
            let now = Date().iso8601String
            try db.execute(sql: """
                INSERT INTO characters (id, user_id, name, sort_order, created_at, updated_at)
                VALUES (?, ?, 'Oak', 0, ?, ?)
            """, arguments: [characterId, localUserId, now, now])

            // swiftlint:disable:next line_length
            let configJSON = ##"{"avatar":{"colorHex":"#5FB236","type":"color"},"language":"en","llmModel":"","referenceAudio":{"path":"","text":""},"systemPrompt":"","ttsVoice":{"modelId":"","provider":"","voiceId":""}}"##
            let charsDir = CatalogDatabase.dataDirectory.appendingPathComponent("characters", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: charsDir, withIntermediateDirectories: true)
            let configURL = charsDir.appendingPathComponent("\(characterId).json")
            try configJSON.data(using: .utf8)?.write(to: configURL)
        }

        // MARK: v8 — Full-Text Search & Storage

        migrator.registerMigration("v8-search-storage") { db in
            try db.create(virtualTable: "items_fts", using: FTS5()) { t in
                t.synchronize(withTable: "items")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("author")
            }

            // Ensure storage directories exist
            let fm = FileManager.default
            for dir in [storageDirectory, notesDirectory, notesAttachmentsDirectory, chatsDirectory, chatAttachmentsDirectory] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }

        // MARK: v9 — Citation Enhancements

        migrator.registerMigration("v9-citation-enhancements") { db in
            // Add extra column to items
            try db.alter(table: "items") { t in
                t.add(column: "extra", .text)
            }

            // Add identifier columns to citations
            try db.alter(table: "citations") { t in
                t.add(column: "pmid", .text)
                t.add(column: "arxiv_id", .text)
                t.add(column: "isbn", .text)
                t.add(column: "issn", .text)
            }

            // Partial indexes on identifier columns
            try db.execute(sql: """
                CREATE INDEX idx_citations_pmid ON citations(pmid) WHERE pmid IS NOT NULL
            """)
            try db.execute(sql: """
                CREATE INDEX idx_citations_arxiv_id ON citations(arxiv_id) WHERE arxiv_id IS NOT NULL
            """)
            try db.execute(sql: """
                CREATE INDEX idx_citations_isbn ON citations(isbn) WHERE isbn IS NOT NULL
            """)
            try db.execute(sql: """
                CREATE INDEX idx_citations_issn ON citations(issn) WHERE issn IS NOT NULL
            """)

            // Item relations table
            try db.create(table: "item_relations") { t in
                t.column("id", .text).primaryKey()
                t.column("source_item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("target_item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("relation_type", .text).notNull()
                t.column("created_at", .text).notNull()
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_item_relations_unique
                ON item_relations(source_item_id, target_item_id, relation_type)
            """)
            try db.create(index: "idx_item_relations_target", on: "item_relations", columns: ["target_item_id"])

            // FTS5 on citations (abstract + container_title)
            try db.create(virtualTable: "citations_fts", using: FTS5()) { t in
                t.synchronize(withTable: "citations")
                t.tokenizer = .unicode61()
                t.column("abstract")
                t.column("container_title")
            }
        }

        // MARK: v10 — Remove Characters & Voice Calls

        migrator.registerMigration("v10-voice-agent") { db in
            try db.drop(table: "voice_calls")
            try db.drop(table: "characters")
        }

        // MARK: v11 — Quiz Cards & Review Log (Flashcards / Spaced Repetition)

        migrator.registerMigration("v11-quiz-cards") { db in
            try db.create(table: "quiz_cards") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("conversation_id", .text)
                t.column("group_id", .text)
                t.column("type", .text).notNull()             // cloze, choice, flashcard, occlusion, matching, ordering
                t.column("content_json", .text).notNull()     // JSON-encoded quiz content
                // FSRS scheduling fields
                t.column("state", .text).notNull().defaults(to: "new")  // new, learning, review, relearning
                t.column("due_at", .text).notNull()
                t.column("stability", .double).notNull().defaults(to: 0)
                t.column("difficulty", .double).notNull().defaults(to: 0)
                t.column("elapsed_days", .integer).notNull().defaults(to: 0)
                t.column("scheduled_days", .integer).notNull().defaults(to: 0)
                t.column("reps", .integer).notNull().defaults(to: 0)
                t.column("lapses", .integer).notNull().defaults(to: 0)
                t.column("last_review_at", .text)
                t.column("is_suspended", .integer).notNull().defaults(to: false)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_quiz_cards_state_due", on: "quiz_cards", columns: ["state", "due_at"])
            try db.create(index: "idx_quiz_cards_item_id", on: "quiz_cards", columns: ["item_id"])
            try db.create(index: "idx_quiz_cards_group_id", on: "quiz_cards", columns: ["group_id"])

            try db.create(table: "quiz_review_log") { t in
                t.column("id", .text).primaryKey()
                t.column("card_id", .text).notNull().references("quiz_cards", onDelete: .cascade)
                t.column("rating", .integer).notNull()        // 1=Again, 2=Hard, 3=Good, 4=Easy
                t.column("state", .text).notNull()            // state before review
                t.column("scheduled_days", .integer).notNull()
                t.column("elapsed_days", .integer).notNull()
                t.column("reviewed_at", .text).notNull()
            }
            try db.create(index: "idx_quiz_review_log_card_id", on: "quiz_review_log", columns: ["card_id"])

            // Seed "Flashcards" system smart collection
            let now = Date().iso8601String
            try db.execute(sql: """
                INSERT INTO collections (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, filter_rules, created_at, updated_at)
                VALUES (?, ?, 'Flashcards', 'rectangle.on.rectangle.angled', 9, NULL, 1, 1, NULL, ?, ?)
            """, arguments: [SystemCollectionID.flashcards.uuidString, localUserId, now, now])
        }

        // MARK: v12 — Processing Status

        migrator.registerMigration("v12-processing-status") { db in
            try db.execute(sql: """
                ALTER TABLE items ADD COLUMN processing_status TEXT NOT NULL DEFAULT 'none'
            """)

            // Backfill: mark audio items that already have a transcript file as 'transcribed'
            let rows = try Row.fetchAll(db, sql: """
                SELECT i.id, i.storage_key, a.storage_key AS att_storage_key
                FROM items i
                JOIN attachments a ON a.item_id = i.id AND a.content_type = 'audio' AND a.is_primary = 1
            """)
            let fm = FileManager.default
            for row in rows {
                let itemStorageKey: String = row["storage_key"]
                let attStorageKey: String = row["att_storage_key"]
                let transcriptURL = CatalogDatabase.attachmentTranscriptURL(
                    itemStorageKey: itemStorageKey,
                    attachmentStorageKey: attStorageKey
                )
                if fm.fileExists(atPath: transcriptURL.path) {
                    let itemId: String = row["id"]
                    try db.execute(
                        sql: "UPDATE items SET processing_status = 'transcribed' WHERE id = ?",
                        arguments: [itemId]
                    )
                }
            }
        }

        // MARK: v13 — Quiz Annotation Link

        migrator.registerMigration("v13-quiz-annotation-link") { db in
            try db.alter(table: "quiz_cards") { t in
                t.add(column: "annotation_id", .text)
                t.add(column: "source_text", .text)
                t.add(column: "page_context", .text)
                t.add(column: "is_pending", .integer).defaults(to: 0)
            }
            try db.create(index: "idx_quiz_cards_annotation", on: "quiz_cards", columns: ["annotation_id"])
            try db.create(index: "idx_quiz_cards_pending", on: "quiz_cards", columns: ["is_pending", "item_id"])
        }

        return migrator
    }

}
