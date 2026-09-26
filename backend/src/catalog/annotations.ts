/**
 * Annotation CRUD — highlights, underlines and notes on a document.
 *
 * The second store across, and the one that shows the boundary is not
 * store-by-store. `AnnotationStore` in Swift did two unrelated things:
 * database access, and encoding a sort index from a `CGRect` in PDF
 * coordinate space. The first moves here; the second stays in Swift, because
 * it is geometry and geometry is PDFKit's.
 *
 * So `sortIndex` arrives already computed. The core stores and orders by it
 * and never learns what the string means, which is exactly right — the page
 * layout is not its business.
 */
import type { Database } from "bun:sqlite";

export interface Annotation {
  id: string;
  itemId: string;
  attachmentId: string;
  /** Short random key, unique per annotation. Generated shell-side. */
  key: string;
  /** highlight | underline | note | … */
  type: string;
  authorName: string | null;
  /** The highlighted passage, when there is one. */
  text: string | null;
  /** The user's own note attached to it. */
  comment: string | null;
  color: string;
  pageLabel: string | null;
  /**
   * Opaque ordering key, `PPPPP|YYYYYY|XXXXXX`, computed in the shell from
   * PDF geometry. Sorted as a string here; never parsed.
   */
  sortIndex: string;
  /** How positionJson should be read: a PDF rect, a web text quote, … */
  positionKind: string;
  positionJson: string;
  styleJson: string | null;
  source: string;
  sourceKey: string | null;
  createdAt: string;
  updatedAt: string;
  /** Set on soft delete; rows stay for sync reconciliation. */
  deletedAt: string | null;
}

interface Row {
  id: string; item_id: string; attachment_id: string; key: string; type: string;
  author_name: string | null; text: string | null; comment: string | null;
  color: string; page_label: string | null; sort_index: string;
  position_kind: string; position_json: string; style_json: string | null;
  source: string; source_key: string | null;
  created_at: string; updated_at: string; deleted_at: string | null;
}

const COLUMNS = `id, item_id, attachment_id, key, type, author_name, text, comment,
  color, page_label, sort_index, position_kind, position_json, style_json,
  source, source_key, created_at, updated_at, deleted_at`;

function toDomain(r: Row): Annotation {
  return {
    id: r.id, itemId: r.item_id, attachmentId: r.attachment_id, key: r.key,
    type: r.type, authorName: r.author_name, text: r.text, comment: r.comment,
    color: r.color, pageLabel: r.page_label, sortIndex: r.sort_index,
    positionKind: r.position_kind, positionJson: r.position_json,
    styleJson: r.style_json, source: r.source, sourceKey: r.source_key,
    createdAt: r.created_at, updatedAt: r.updated_at, deletedAt: r.deleted_at,
  };
}

export class AnnotationStore {
  constructor(private readonly db: Database, private readonly userId: string) {}

  /**
   * Live annotations on one attachment, in reading order.
   *
   * Soft-deleted rows are excluded but not removed: `deleted_at` is a
   * tombstone so a later sync can tell "deleted" from "never existed".
   */
  listForAttachment(attachmentId: string): Annotation[] {
    return this.db.query<Row, [string]>(
      `SELECT ${COLUMNS} FROM annotations
        WHERE attachment_id = ? AND deleted_at IS NULL
        ORDER BY sort_index`,
    ).all(attachmentId).map(toDomain);
  }

  get(id: string): Annotation | null {
    const row = this.db.query<Row, [string]>(
      `SELECT ${COLUMNS} FROM annotations WHERE id = ?`).get(id);
    return row ? toDomain(row) : null;
  }

  /** Insert or replace wholesale, keyed by id. */
  upsert(a: Annotation): void {
    this.db.prepare(
      `INSERT INTO annotations
         (id, user_id, item_id, attachment_id, key, type, author_name, text, comment,
          color, page_label, sort_index, position_kind, position_json, style_json,
          source, source_key, created_at, updated_at, deleted_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         type = excluded.type, author_name = excluded.author_name,
         text = excluded.text, comment = excluded.comment, color = excluded.color,
         page_label = excluded.page_label, sort_index = excluded.sort_index,
         position_kind = excluded.position_kind, position_json = excluded.position_json,
         style_json = excluded.style_json, source = excluded.source,
         source_key = excluded.source_key, updated_at = excluded.updated_at,
         deleted_at = excluded.deleted_at`,
    ).run(
      a.id, this.userId, a.itemId, a.attachmentId, a.key, a.type, a.authorName,
      a.text, a.comment, a.color, a.pageLabel, a.sortIndex, a.positionKind,
      a.positionJson, a.styleJson, a.source, a.sourceKey,
      a.createdAt, a.updatedAt, a.deletedAt,
    );
  }

  /** Tombstone it: hidden from reads, still present for sync. */
  softDelete(id: string, at: string): void {
    this.db.prepare("UPDATE annotations SET deleted_at = ?, updated_at = ? WHERE id = ?")
      .run(at, at, id);
  }

  /** Actually remove the row. Used when the user empties the trash. */
  hardDelete(id: string): void {
    this.db.prepare("DELETE FROM annotations WHERE id = ?").run(id);
  }
}
