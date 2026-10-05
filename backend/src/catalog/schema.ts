/**
 * The catalog schema, transcribed from the DDL a shipped database actually
 * contains -- `sqlite3 library.sqlite .schema` -- rather than re-derived from
 * the Swift GRDB builders it used to come from. Re-deriving invites a subtle
 * mismatch; copying what is on disk cannot.
 *
 * This is why phase 1 is not a data migration. GRDB wrote plain SQLite, so the
 * same file opens here unchanged; only the process reading it moves. The one
 * GRDB artifact is `grdb_migrations`, a bookkeeping table of applied
 * identifiers, and MIGRATIONS below keeps its contract exactly.
 */
import { canonicalizeIdsSql } from "./ids.js";

/** Applied-migration identifiers, in order. The names are GRDB's and must not
 *  change: a database written by the Swift app already has these seven rows,
 *  and an app rolled back to the Swift catalog has to still recognise them. */
export const BASELINE_MIGRATIONS = [
  "v1-items-attachments",
  "v2-collections",
  "v3-properties",
  "v4-conversations",
  "v5-citations",
  "v6-annotations",
  "v7-word-lookups",
] as const;

/**
 * Migrations added after the catalog moved here, each carrying its own DDL.
 *
 * The baseline above deliberately has none: those seven identifiers describe a
 * schema `SCHEMA_SQL` already states in full, and a library written by the
 * Swift app arrives with all seven applied and the tables already right. That
 * is adoption, and it needs no DDL.
 *
 * Everything from here on is a real change to a schema that already exists, so
 * it has to say how to get there. `SCHEMA_SQL` states the destination for a
 * fresh database; `sql` moves an existing one. Keep the two saying the same
 * thing — the pair is checked by `conversation scope: fresh and migrated agree`
 * in catalog.test.ts.
 */
export interface Migration {
  readonly id: string;
  readonly sql: string;
}

export const POST_BASELINE_MIGRATIONS: readonly Migration[] = [
  {
    // `collection_id` is last in the conversations DDL above, not beside
    // `item_id` where it reads better, because ALTER TABLE ADD COLUMN can only
    // append — and a database that reached this schema by migrating has to end
    // up byte-identical to one created fresh. The suite compares the two.
    id: "v8-conversation-collection",
    sql: `
      ALTER TABLE "conversations" ADD COLUMN "collection_id" TEXT
        REFERENCES "collections"("id") ON DELETE SET NULL;
      CREATE INDEX "idx_conversations_collection_id" ON "conversations"("collection_id");
    `,
  },
  {
    // Data only, no DDL: the schema always allowed either case, and the app
    // only ever writes one. See ids.ts for why uppercase is the canonical
    // form and what the mismatch broke.
    id: "v9-canonical-id-case",
    sql: canonicalizeIdsSql(),
  },
];

/** Every identifier a database of this build should carry. */
export const MIGRATIONS = [
  ...BASELINE_MIGRATIONS,
  ...POST_BASELINE_MIGRATIONS.map((m) => m.id),
] as const;

/** Full schema for a fresh database, byte-compatible with what Swift created. */
export const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS "items" ("id" TEXT PRIMARY KEY, "user_id" TEXT NOT NULL, "storage_key" TEXT NOT NULL UNIQUE, "title" TEXT NOT NULL, "author" TEXT NOT NULL DEFAULT '', "last_opened_at" TEXT, "last_position" DOUBLE, "sync_status" TEXT NOT NULL DEFAULT 'local', "cite_key" TEXT, "source" TEXT, "source_key" TEXT, "extra" TEXT, "processing_status" TEXT NOT NULL DEFAULT 'none', "deleted_at" TEXT, "created_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL);
CREATE UNIQUE INDEX "idx_items_cite_key" ON "items"("cite_key");
CREATE UNIQUE INDEX idx_items_source ON items(source, source_key)
    WHERE source IS NOT NULL AND source_key IS NOT NULL;
CREATE INDEX "idx_items_deleted_at" ON "items"("deleted_at");
CREATE TABLE IF NOT EXISTS "attachments" ("id" TEXT PRIMARY KEY, "item_id" TEXT NOT NULL REFERENCES "items"("id") ON DELETE CASCADE, "storage_key" TEXT NOT NULL UNIQUE, "file_name" TEXT NOT NULL, "content_type" TEXT NOT NULL DEFAULT 'pdf', "link_mode" TEXT NOT NULL DEFAULT 'importedFile', "source_url" TEXT, "file_size" INTEGER NOT NULL DEFAULT 0, "page_count" INTEGER NOT NULL DEFAULT 0, "is_primary" INTEGER NOT NULL DEFAULT 1, "created_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL);
CREATE INDEX "idx_attachments_item_id" ON "attachments"("item_id");
CREATE INDEX idx_attachments_source_url ON attachments(source_url);
CREATE INDEX idx_attachments_file_name ON attachments(file_name);
CREATE TABLE IF NOT EXISTS "collections" ("id" TEXT PRIMARY KEY, "user_id" TEXT NOT NULL, "name" TEXT NOT NULL, "icon" TEXT NOT NULL DEFAULT 'folder', "sort_order" INTEGER NOT NULL DEFAULT 0, "parent_id" TEXT REFERENCES "collections"("id") ON DELETE CASCADE, "is_smart" INTEGER NOT NULL DEFAULT 0, "is_system" INTEGER NOT NULL DEFAULT 0, "filter_rules" TEXT, "source" TEXT, "source_key" TEXT, "created_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL);
CREATE UNIQUE INDEX idx_collections_source ON collections(source, source_key)
    WHERE source IS NOT NULL AND source_key IS NOT NULL;
CREATE TABLE IF NOT EXISTS "collection_items" ("item_id" TEXT NOT NULL REFERENCES "items"("id") ON DELETE CASCADE, "collection_id" TEXT NOT NULL REFERENCES "collections"("id") ON DELETE CASCADE, "created_at" TEXT NOT NULL, PRIMARY KEY ("item_id", "collection_id"));
CREATE INDEX "idx_collection_items_collection_id" ON "collection_items"("collection_id");
CREATE TABLE IF NOT EXISTS "properties" ("id" TEXT PRIMARY KEY, "name" TEXT NOT NULL, "type" TEXT NOT NULL, "icon" TEXT NOT NULL DEFAULT 'tag', "position" INTEGER NOT NULL DEFAULT 0, "is_system" INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS "property_options" ("id" TEXT PRIMARY KEY, "property_id" TEXT NOT NULL REFERENCES "properties"("id") ON DELETE CASCADE, "name" TEXT NOT NULL, "color_hex" TEXT NOT NULL DEFAULT '999999', "position" INTEGER NOT NULL DEFAULT 0);
CREATE INDEX "idx_property_options_property_id" ON "property_options"("property_id");
CREATE TABLE IF NOT EXISTS "item_property_values" ("id" TEXT PRIMARY KEY, "item_id" TEXT NOT NULL REFERENCES "items"("id") ON DELETE CASCADE, "property_id" TEXT NOT NULL REFERENCES "properties"("id") ON DELETE CASCADE, "option_id" TEXT REFERENCES "property_options"("id") ON DELETE CASCADE, "text_value" TEXT);
CREATE INDEX "idx_item_property_values_item" ON "item_property_values"("item_id");
CREATE INDEX "idx_item_property_values_property" ON "item_property_values"("property_id");
CREATE TABLE IF NOT EXISTS "conversations" ("id" TEXT PRIMARY KEY, "user_id" TEXT NOT NULL, "item_id" TEXT REFERENCES "items"("id") ON DELETE CASCADE, "title" TEXT NOT NULL, "message_count" INTEGER NOT NULL DEFAULT 0, "created_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL, "collection_id" TEXT REFERENCES "collections"("id") ON DELETE SET NULL);
CREATE INDEX "idx_conversations_collection_id" ON "conversations"("collection_id");
CREATE TABLE IF NOT EXISTS "citations" ("item_id" TEXT PRIMARY KEY REFERENCES "items"("id") ON DELETE CASCADE, "csl_json" TEXT NOT NULL, "csl_type" TEXT NOT NULL DEFAULT 'document', "doi" TEXT, "year" INTEGER, "container_title" TEXT, "abstract" TEXT, "pmid" TEXT, "arxiv_id" TEXT, "isbn" TEXT, "issn" TEXT, "created_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL);
CREATE INDEX "idx_citations_doi" ON "citations"("doi");
CREATE INDEX "idx_citations_year" ON "citations"("year");
CREATE INDEX "idx_citations_type" ON "citations"("csl_type");
CREATE INDEX "idx_citations_container_title" ON "citations"("container_title");
CREATE INDEX idx_citations_pmid ON citations(pmid) WHERE pmid IS NOT NULL;
CREATE INDEX idx_citations_arxiv_id ON citations(arxiv_id) WHERE arxiv_id IS NOT NULL;
CREATE INDEX idx_citations_isbn ON citations(isbn) WHERE isbn IS NOT NULL;
CREATE INDEX idx_citations_issn ON citations(issn) WHERE issn IS NOT NULL;
CREATE TABLE IF NOT EXISTS "annotations" ("id" TEXT PRIMARY KEY, "user_id" TEXT NOT NULL, "item_id" TEXT NOT NULL REFERENCES "items"("id") ON DELETE CASCADE, "attachment_id" TEXT NOT NULL REFERENCES "attachments"("id") ON DELETE CASCADE, "key" TEXT NOT NULL UNIQUE, "type" TEXT NOT NULL, "author_name" TEXT, "text" TEXT, "comment" TEXT, "color" TEXT NOT NULL DEFAULT '#ffd400', "page_label" TEXT, "sort_index" TEXT NOT NULL, "position_kind" TEXT NOT NULL, "position_json" TEXT NOT NULL, "style_json" TEXT, "source" TEXT NOT NULL DEFAULT 'oakreader', "source_key" TEXT, "created_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL, "deleted_at" TEXT);
CREATE INDEX "idx_annotations_attachment_sort" ON "annotations"("attachment_id", "deleted_at", "sort_index");
CREATE INDEX "idx_annotations_item_updated" ON "annotations"("item_id", "updated_at");
CREATE UNIQUE INDEX idx_annotations_source ON annotations(source, source_key) WHERE source_key IS NOT NULL;
CREATE TABLE IF NOT EXISTS "word_lookups" ("id" TEXT PRIMARY KEY, "user_id" TEXT NOT NULL, "item_id" TEXT REFERENCES "items"("id") ON DELETE SET NULL, "item_title" TEXT NOT NULL DEFAULT '', "word" TEXT NOT NULL, "sentence" TEXT NOT NULL DEFAULT '', "explanation" TEXT NOT NULL DEFAULT '', "dedupe_key" TEXT NOT NULL, "created_at" TEXT NOT NULL);
CREATE INDEX "idx_word_lookups_item_id" ON "word_lookups"("item_id");
CREATE INDEX "idx_word_lookups_created" ON "word_lookups"("created_at");
CREATE INDEX "idx_word_lookups_dedupe" ON "word_lookups"("dedupe_key");
`;
