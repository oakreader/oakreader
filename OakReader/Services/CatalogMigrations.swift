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
                t.column("last_opened_at", .text)
                t.column("last_position", .double)
                t.column("sync_status", .text).notNull().defaults(to: "local")
                t.column("cite_key", .text)
                t.column("source", .text)
                t.column("source_key", .text)
                t.column("extra", .text)
                t.column("processing_status", .text).notNull().defaults(to: "none")
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
                (SystemCollectionID.readingList.uuidString, "Reading List", "bookmark", -1, nil),
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
                (SystemCollectionID.duplicates.uuidString, "Duplicates", "square.on.square", 5, nil),
            ]
            for sc in systemCollections {
                try db.execute(
                    // swiftlint:disable:next line_length
                    sql: "INSERT INTO collections (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, filter_rules, created_at, updated_at) VALUES (?, ?, ?, ?, ?, NULL, 1, 1, ?, ?, ?)",
                    arguments: [sc.id, localUserId, sc.name, sc.icon, sc.order, sc.rules, now, now]
                )
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

            let statusPropertyId = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO properties (id, name, type, icon, position, is_system)
                VALUES (?, 'Status', 'single_select', 'circle.dotted', 1, 1)
            """, arguments: [statusPropertyId])

            // swiftlint:disable:next large_tuple
            let statusOptions: [(name: String, color: String, pos: Int)] = [
                ("To Read", "2EA8E5", 0), ("Reading", "FF8C19", 1),
                ("Finished", "5FB236", 2),
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

        // MARK: v4 — Conversations & Notes

        migrator.registerMigration("v4-conversations-notes") { db in
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
                t.column("pmid", .text)
                t.column("arxiv_id", .text)
                t.column("isbn", .text)
                t.column("issn", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_citations_doi", on: "citations", columns: ["doi"], ifNotExists: true)
            try db.create(index: "idx_citations_year", on: "citations", columns: ["year"], ifNotExists: true)
            try db.create(index: "idx_citations_type", on: "citations", columns: ["csl_type"], ifNotExists: true)
            try db.create(index: "idx_citations_container_title", on: "citations", columns: ["container_title"], ifNotExists: true)
            try db.execute(sql: "CREATE INDEX idx_citations_pmid ON citations(pmid) WHERE pmid IS NOT NULL")
            try db.execute(sql: "CREATE INDEX idx_citations_arxiv_id ON citations(arxiv_id) WHERE arxiv_id IS NOT NULL")
            try db.execute(sql: "CREATE INDEX idx_citations_isbn ON citations(isbn) WHERE isbn IS NOT NULL")
            try db.execute(sql: "CREATE INDEX idx_citations_issn ON citations(issn) WHERE issn IS NOT NULL")
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

        // MARK: v7 — Full-Text Search & Storage

        migrator.registerMigration("v7-search-storage") { db in
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

        // MARK: v8 — Item Relations & Citation FTS

        migrator.registerMigration("v8-relations-citation-fts") { db in
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

            try db.create(virtualTable: "citations_fts", using: FTS5()) { t in
                t.synchronize(withTable: "citations")
                t.tokenizer = .unicode61()
                t.column("abstract")
                t.column("container_title")
            }
        }

        // MARK: v9 — Quiz Cards & Review Log

        migrator.registerMigration("v9-quiz-cards") { db in
            try db.create(table: "quiz_cards") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().references("items", onDelete: .cascade)
                t.column("conversation_id", .text)
                t.column("group_id", .text)
                t.column("type", .text).notNull()
                t.column("content_json", .text).notNull()
                // FSRS scheduling fields
                t.column("state", .text).notNull().defaults(to: "new")
                t.column("due_at", .text).notNull()
                t.column("stability", .double).notNull().defaults(to: 0)
                t.column("difficulty", .double).notNull().defaults(to: 0)
                t.column("elapsed_days", .integer).notNull().defaults(to: 0)
                t.column("scheduled_days", .integer).notNull().defaults(to: 0)
                t.column("reps", .integer).notNull().defaults(to: 0)
                t.column("lapses", .integer).notNull().defaults(to: 0)
                t.column("last_review_at", .text)
                t.column("is_suspended", .integer).notNull().defaults(to: false)
                t.column("annotation_id", .text)
                t.column("source_text", .text)
                t.column("page_context", .text)
                t.column("is_pending", .integer).notNull().defaults(to: 0)
                t.column("collection_id", .text).references("collections", onDelete: .cascade)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_quiz_cards_state_due", on: "quiz_cards", columns: ["state", "due_at"])
            try db.create(index: "idx_quiz_cards_item_id", on: "quiz_cards", columns: ["item_id"])
            try db.create(index: "idx_quiz_cards_group_id", on: "quiz_cards", columns: ["group_id"])
            try db.create(index: "idx_quiz_cards_annotation", on: "quiz_cards", columns: ["annotation_id"])
            try db.create(index: "idx_quiz_cards_pending", on: "quiz_cards", columns: ["is_pending", "item_id"])
            try db.create(index: "idx_quiz_cards_collection", on: "quiz_cards", columns: ["collection_id"])

            try db.create(table: "quiz_review_log") { t in
                t.column("id", .text).primaryKey()
                t.column("card_id", .text).notNull().references("quiz_cards", onDelete: .cascade)
                t.column("rating", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("scheduled_days", .integer).notNull()
                t.column("elapsed_days", .integer).notNull()
                t.column("reviewed_at", .text).notNull()
            }
            try db.create(index: "idx_quiz_review_log_card_id", on: "quiz_review_log", columns: ["card_id"])

            // Seed "Quiz Cards" system smart collection
            let now = Date().iso8601String
            try db.execute(sql: """
                INSERT INTO collections (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, filter_rules, created_at, updated_at)
                VALUES (?, ?, 'Quiz Cards', 'rectangle.on.rectangle.angled', 6, NULL, 1, 1, NULL, ?, ?)
            """, arguments: [SystemCollectionID.quizCards.uuidString, localUserId, now, now])
        }


        // MARK: v10 — Soft Delete (Bin)

        migrator.registerMigration("v10-soft-delete") { db in
            try db.execute(sql: "ALTER TABLE items ADD COLUMN deleted_at TEXT")
            try db.create(index: "idx_items_deleted_at", on: "items", columns: ["deleted_at"], ifNotExists: true)

            // Seed "Bin" system smart collection
            let now = Date().iso8601String
            try db.execute(sql: """
                INSERT INTO collections (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system, filter_rules, created_at, updated_at)
                VALUES (?, ?, 'Bin', 'trash', 7, NULL, 1, 1, NULL, ?, ?)
            """, arguments: [SystemCollectionID.bin.uuidString, localUserId, now, now])
        }

        return migrator
    }

}
