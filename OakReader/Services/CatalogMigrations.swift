import Foundation
import GRDB

extension CatalogDatabase {
    // MARK: - Migrations

    /// Database schema migrator.
    ///
    /// The schema is defined as a sequence of grouped migrations, each owning one
    /// cohesive area of the model. Never edit a migration once it has shipped — add a
    /// new `vN-…` step instead.
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
                t.column("deleted_at", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_items_cite_key", on: "items", columns: ["cite_key"], unique: true, ifNotExists: true)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_items_source ON items(source, source_key)
                WHERE source IS NOT NULL AND source_key IS NOT NULL
            """)
            try db.create(index: "idx_items_deleted_at", on: "items", columns: ["deleted_at"], ifNotExists: true)

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
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_attachments_source_url ON attachments(source_url)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_attachments_file_name ON attachments(file_name)")
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
        }

        // MARK: v3 — Properties (tags, status, rating)

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

        // MARK: v7 — Item Relations

        migrator.registerMigration("v7-item-relations") { db in
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
        }

        // MARK: v8 — Quiz Cards & Review Log

        migrator.registerMigration("v8-quiz-cards") { db in
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
        }

        // MARK: v9 — Full-Text Search (created last, after synchronized base tables exist)

        migrator.registerMigration("v9-full-text-search") { db in
            try db.create(virtualTable: "items_fts", using: FTS5()) { t in
                t.synchronize(withTable: "items")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("author")
            }

            try db.create(virtualTable: "citations_fts", using: FTS5()) { t in
                t.synchronize(withTable: "citations")
                t.tokenizer = .unicode61()
                t.column("abstract")
                t.column("container_title")
            }
        }

        // MARK: v10 — Split `embed` content type into `video` + `link`

        migrator.registerMigration("v10-split-embed-content-type") { db in
            let now = Date().iso8601String

            // Reclassify legacy `embed` attachments: YouTube → `video`, everything else → `link`.
            try db.execute(sql: """
                UPDATE attachments SET content_type = 'video', updated_at = ?
                WHERE content_type = 'embed'
                  AND (source_url LIKE '%youtube.com%' OR source_url LIKE '%youtu.be%')
            """, arguments: [now])
            try db.execute(sql: """
                UPDATE attachments SET content_type = 'link', updated_at = ?
                WHERE content_type = 'embed'
            """, arguments: [now])

            // Repoint the former "Embeds" system collection at videos only.
            let videoRule = #"{"match":"all","conditions":[{"field":"content_type","op":"eq","value":"video"}]}"#
            try db.execute(sql: """
                UPDATE collections SET name = 'Videos', icon = 'play.rectangle', filter_rules = ?, updated_at = ?
                WHERE id = ?
            """, arguments: [videoRule, now, SystemCollectionID.embeds.uuidString])

            // "Web" now covers saved HTML snapshots *and* link bookmarks.
            let webRule = #"{"match":"any","conditions":[{"field":"content_type","op":"eq","value":"html"},{"field":"content_type","op":"eq","value":"link"}]}"#
            try db.execute(sql: """
                UPDATE collections SET filter_rules = ?, updated_at = ?
                WHERE id = ?
            """, arguments: [webRule, now, SystemCollectionID.html.uuidString])
        }

        // MARK: v11 — Remove the `video` content type (folded into `link`)

        migrator.registerMigration("v11-remove-video-content-type") { db in
            let now = Date().iso8601String

            // YouTube playback was removed; former `video` embeds are now plain
            // link bookmarks rendered as cards. Reclassify them.
            try db.execute(sql: """
                UPDATE attachments SET content_type = 'link', updated_at = ?
                WHERE content_type = 'video'
            """, arguments: [now])

            // Drop the now-redundant "Videos" system collection (smart collection,
            // no collection_items rows to clean up).
            try db.execute(
                sql: "DELETE FROM collections WHERE id = ?",
                arguments: [SystemCollectionID.embeds.uuidString]
            )
        }

        // MARK: v12 — Remove the Notes feature

        migrator.registerMigration("v12-remove-notes") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_notes_item_id")
            try db.execute(sql: "DROP TABLE  IF EXISTS notes")
        }

        // MARK: v13 — Anki export: collapse quiz_cards to a slim staging table
        //
        // The self-built FSRS scheduler/review UI is removed; cards are now generated
        // in chat and exported to Anki. Only one kind of card remains (chat-generated),
        // so the table sheds all FSRS columns, the dead annotation/origin columns, and
        // the review log. `item_id`/`conversation_id` survive as provenance only.

        migrator.registerMigration("v13-anki-export") { db in
            // Rebuild the table (SQLite can't drop FK columns in place).
            try db.execute(sql: """
                CREATE TABLE quiz_cards_new (
                    id              TEXT PRIMARY KEY,
                    conversation_id TEXT REFERENCES conversations(id) ON DELETE SET NULL,
                    item_id         TEXT REFERENCES items(id) ON DELETE SET NULL,
                    type            TEXT NOT NULL,
                    content_json    TEXT NOT NULL,
                    source_text     TEXT,
                    exported_at     TEXT,
                    created_at      TEXT NOT NULL,
                    updated_at      TEXT NOT NULL
                )
            """)
            // Carry over the surviving columns. Legacy "annotation" rows keep their
            // content and item_id; only the dead annotation link is dropped.
            try db.execute(sql: """
                INSERT INTO quiz_cards_new
                    (id, conversation_id, item_id, type, content_json, source_text, exported_at, created_at, updated_at)
                SELECT id, conversation_id, item_id, type, content_json, source_text, NULL, created_at, updated_at
                FROM quiz_cards
            """)
            try db.execute(sql: "DROP TABLE quiz_cards")
            try db.execute(sql: "ALTER TABLE quiz_cards_new RENAME TO quiz_cards")

            try db.create(index: "idx_quiz_cards_item_id", on: "quiz_cards", columns: ["item_id"])
            try db.create(index: "idx_quiz_cards_conversation", on: "quiz_cards", columns: ["conversation_id"])
            try db.create(index: "idx_quiz_cards_exported", on: "quiz_cards", columns: ["exported_at"])

            try db.execute(sql: "DROP TABLE IF EXISTS quiz_review_log")
        }

        return migrator
    }

}
