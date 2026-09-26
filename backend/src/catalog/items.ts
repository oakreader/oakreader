/**
 * Items and their attachments — the centre of the catalog.
 *
 * `list()` reads the whole library as one object graph, which is what the
 * Swift store did and what the library view needs: every item with its
 * attachments, collection memberships, citation metadata and property values.
 * Five queries and a handful of maps beat 644 round trips, and the shell holds
 * the result for as long as the window is open.
 *
 * Covers are deliberately absent. At ten thousand items, loading them here
 * would pin hundreds of megabytes of image data and re-read all of it on every
 * invalidation; the views that show a cover load it lazily from the
 * attachment's storage key instead. That note was in the Swift original and is
 * worth carrying over, because the omission looks like a bug otherwise.
 */
import type { Database } from "bun:sqlite";

export interface Attachment {
  id: string;
  itemId: string;
  storageKey: string;
  fileName: string;
  contentType: string;
  linkMode: string;
  sourceUrl: string | null;
  fileSize: number;
  pageCount: number;
  isPrimary: boolean;
}

export interface PropertyValue {
  id: string;
  propertyId: string;
  propertyName: string;
  propertyType: string;
  /** Present for select-type properties; absent for free text. */
  optionId: string | null;
  optionName: string | null;
  optionColorHex: string | null;
  textValue: string | null;
}

export interface Item {
  id: string;
  storageKey: string;
  title: string;
  author: string;
  lastOpenedAt: string | null;
  lastPosition: number | null;
  citeKey: string | null;
  source: string | null;
  sourceKey: string | null;
  extra: string | null;
  processingStatus: string;
  /** Tombstone: set while in the trash, cleared on restore. */
  deletedAt: string | null;
  createdAt: string;
  updatedAt: string;

  attachments: Attachment[];
  /** Ids only; the collections themselves come from the collection store. */
  collectionIds: string[];
  /** CSL JSON, opaque here. */
  citationJson: string | null;
  propertyValues: PropertyValue[];
}

interface ItemRow {
  id: string; storage_key: string; title: string; author: string;
  last_opened_at: string | null; last_position: number | null;
  cite_key: string | null; source: string | null; source_key: string | null;
  extra: string | null; processing_status: string; deleted_at: string | null;
  created_at: string; updated_at: string;
}

const ITEM_COLUMNS = `id, storage_key, title, author, last_opened_at, last_position,
  cite_key, source, source_key, extra, processing_status, deleted_at,
  created_at, updated_at`;

export class ItemStore {
  constructor(private readonly db: Database, private readonly userId: string) {}

  /** Live items, newest first, fully populated. */
  list(): Item[] {
    return this.assemble(
      this.db.query<ItemRow, []>(
        `SELECT ${ITEM_COLUMNS} FROM items WHERE deleted_at IS NULL ORDER BY created_at DESC`,
      ).all(),
    );
  }

  /** Items in the trash, most recently deleted first. */
  listTrashed(): Item[] {
    return this.assemble(
      this.db.query<ItemRow, []>(
        `SELECT ${ITEM_COLUMNS} FROM items WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC`,
      ).all(),
    );
  }

  /**
   * Find one item by any of its unique-ish handles.
   *
   * One method rather than six, because they differ only in the column: the
   * Swift original had `findItem(byCiteKey:)`, `(byStorageKey:)`,
   * `(bySource:sourceKey:)` and so on, which is six near-identical bodies.
   */
  find(by: "id" | "citeKey" | "storageKey" | "fileName" | "sourceUrl",
       value: string, sourceKey?: string): Item | null {
    let sql: string;
    let args: string[];
    switch (by) {
      case "id":
        sql = `SELECT ${ITEM_COLUMNS} FROM items WHERE id = ?`;
        args = [value];
        break;
      case "citeKey":
        sql = `SELECT ${ITEM_COLUMNS} FROM items WHERE cite_key = ?`;
        args = [value];
        break;
      case "storageKey":
        sql = `SELECT ${ITEM_COLUMNS} FROM items WHERE storage_key = ?`;
        args = [value];
        break;
      // The last two live on attachments, so they join back to the item.
      case "fileName":
        sql = `SELECT ${ITEM_COLUMNS.split(", ").map((c) => `i.${c}`).join(", ")}
               FROM items i JOIN attachments a ON a.item_id = i.id
               WHERE a.file_name = ? LIMIT 1`;
        args = [value];
        break;
      case "sourceUrl":
        sql = `SELECT ${ITEM_COLUMNS.split(", ").map((c) => `i.${c}`).join(", ")}
               FROM items i JOIN attachments a ON a.item_id = i.id
               WHERE a.source_url = ? LIMIT 1`;
        args = [value];
        break;
    }
    const row = this.db.query<ItemRow, string[]>(sql).get(...args);
    return row ? this.assemble([row])[0]! : null;
  }

  /** Find by where it was imported from, so an import can run twice safely. */
  findBySource(source: string, sourceKey: string): Item | null {
    const row = this.db.query<ItemRow, [string, string]>(
      `SELECT ${ITEM_COLUMNS} FROM items WHERE source = ? AND source_key = ?`,
    ).get(source, sourceKey);
    return row ? this.assemble([row])[0]! : null;
  }

  // --- mutations ---------------------------------------------------------

  /** Insert an item together with its first attachment, atomically. */
  insert(item: Item): void {
    this.db.transaction(() => {
      this.db.prepare(
        `INSERT INTO items
           (id, user_id, storage_key, title, author, last_opened_at, last_position,
            sync_status, cite_key, source, source_key, extra, processing_status,
            deleted_at, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'local', ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).run(
        item.id, this.userId, item.storageKey, item.title, item.author,
        item.lastOpenedAt, item.lastPosition, item.citeKey, item.source,
        item.sourceKey, item.extra, item.processingStatus, item.deletedAt,
        item.createdAt, item.updatedAt,
      );
      for (const a of item.attachments) this.insertAttachment(a, item.updatedAt);
    })();
  }

  private insertAttachment(a: Attachment, at: string): void {
    this.db.prepare(
      `INSERT INTO attachments
         (id, item_id, storage_key, file_name, content_type, link_mode, source_url,
          file_size, page_count, is_primary, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      a.id, a.itemId, a.storageKey, a.fileName, a.contentType, a.linkMode,
      a.sourceUrl, a.fileSize, a.pageCount, a.isPrimary ? 1 : 0, at, at,
    );
  }

  /**
   * Update one scalar field.
   *
   * The Swift original had `updateTitle`, `updateProcessingStatus`,
   * `updateLastPosition` and `markOpened` as four near-identical methods. The
   * column is restricted to a fixed set here so the name can never come off
   * the wire into SQL.
   */
  updateField(
    id: string,
    field: "title" | "processingStatus" | "lastPosition" | "lastOpenedAt" | "citeKey",
    value: string | number | null,
    at: string,
  ): void {
    const column = {
      title: "title",
      processingStatus: "processing_status",
      lastPosition: "last_position",
      lastOpenedAt: "last_opened_at",
      citeKey: "cite_key",
    }[field];
    this.db.prepare(`UPDATE items SET ${column} = ?, updated_at = ? WHERE id = ?`)
      .run(value, at, id);
  }

  /** Move to the trash. The row stays; `deleted_at` hides it. */
  trash(ids: string[], at: string): void {
    const stmt = this.db.prepare("UPDATE items SET deleted_at = ?, updated_at = ? WHERE id = ?");
    this.db.transaction(() => { for (const id of ids) stmt.run(at, at, id); })();
  }

  restore(ids: string[], at: string): void {
    const stmt = this.db.prepare("UPDATE items SET deleted_at = NULL, updated_at = ? WHERE id = ?");
    this.db.transaction(() => { for (const id of ids) stmt.run(at, id); })();
  }

  /** Permanent. Cascades to attachments, annotations, memberships and citations. */
  remove(ids: string[]): void {
    const stmt = this.db.prepare("DELETE FROM items WHERE id = ?");
    this.db.transaction(() => { for (const id of ids) stmt.run(id); })();
  }

  /**
   * Fold duplicates into a keeper: one transaction, six tables.
   *
   * Everything the duplicates own is re-parented before they are deleted, so
   * the cascade only ever collects what was already moved. Two rules are not
   * symmetric and are the reason this is a method rather than a loop of
   * updates: a transferred attachment stops being primary (the keeper already
   * has one), and a citation moves only if the keeper lacks one, because the
   * keeper's own metadata is the one the user chose to keep.
   *
   * Files on disk are the shell's job and stay there — this moves rows only.
   */
  merge(keeperId: string, duplicateIds: string[], at: string): void {
    this.db.transaction(() => {
      for (const dupId of duplicateIds) {
        if (dupId === keeperId) continue;

        this.db.prepare(
          `UPDATE attachments SET item_id = ?, is_primary = 0, updated_at = ?
            WHERE item_id = ?`).run(keeperId, at, dupId);

        this.db.prepare(
          `INSERT OR IGNORE INTO collection_items (item_id, collection_id, created_at)
           SELECT ?, collection_id, ? FROM collection_items WHERE item_id = ?`,
        ).run(keeperId, at, dupId);

        this.transferPropertyValues(keeperId, dupId);

        this.db.prepare(
          "UPDATE conversations SET item_id = ?, updated_at = ? WHERE item_id = ?")
          .run(keeperId, at, dupId);
        this.db.prepare(
          "UPDATE annotations SET item_id = ?, updated_at = ? WHERE item_id = ?")
          .run(keeperId, at, dupId);

        const keeperHasCitation = this.db.query<{ n: number }, [string]>(
          "SELECT count(*) AS n FROM citations WHERE item_id = ?").get(keeperId)!.n;
        if (keeperHasCitation === 0) {
          this.db.prepare(
            "UPDATE citations SET item_id = ?, updated_at = ? WHERE item_id = ?")
            .run(keeperId, at, dupId);
        }

        this.db.prepare("DELETE FROM items WHERE id = ?").run(dupId);
      }
    })();
  }

  /**
   * Move a duplicate's property values across, skipping any the keeper already
   * holds — matched on the option, or on the text when there is no option.
   * A repeated tag would otherwise show up twice on the merged item.
   */
  private transferPropertyValues(keeperId: string, dupId: string): void {
    const rows = this.db.query<
      { property_id: string; option_id: string | null; text_value: string | null }, [string]
    >(`SELECT property_id, option_id, text_value FROM item_property_values
        WHERE item_id = ?`).all(dupId);

    for (const row of rows) {
      const already = row.option_id !== null
        ? this.db.query<{ n: number }, [string, string, string]>(
          `SELECT count(*) AS n FROM item_property_values
            WHERE item_id = ? AND property_id = ? AND option_id = ?`,
        ).get(keeperId, row.property_id, row.option_id)!.n
        : this.db.query<{ n: number }, [string, string, string | null]>(
          `SELECT count(*) AS n FROM item_property_values
            WHERE item_id = ? AND property_id = ? AND text_value IS ?`,
        ).get(keeperId, row.property_id, row.text_value)!.n;
      if (already > 0) continue;

      this.db.prepare(
        `INSERT INTO item_property_values (id, item_id, property_id, option_id, text_value)
         VALUES (?, ?, ?, ?, ?)`,
      ).run(crypto.randomUUID(), keeperId, row.property_id, row.option_id, row.text_value);
    }
  }

  // --- assembly ----------------------------------------------------------

  /**
   * Populate a set of item rows in five queries rather than per-item lookups.
   *
   * Everything is fetched unfiltered and grouped in memory. At this library's
   * size that is far cheaper than parameterised IN-clauses, and it keeps the
   * query count constant however many items came back.
   */
  private assemble(rows: ItemRow[]): Item[] {
    if (rows.length === 0) return [];

    const attachments = new Map<string, Attachment[]>();
    for (const a of this.db.query<any, []>(
      `SELECT id, item_id, storage_key, file_name, content_type, link_mode,
              source_url, file_size, page_count, is_primary
         FROM attachments`).all()) {
      const list = attachments.get(a.item_id) ?? [];
      list.push({
        id: a.id, itemId: a.item_id, storageKey: a.storage_key,
        fileName: a.file_name, contentType: a.content_type, linkMode: a.link_mode,
        sourceUrl: a.source_url, fileSize: a.file_size, pageCount: a.page_count,
        isPrimary: a.is_primary !== 0,
      });
      attachments.set(a.item_id, list);
    }

    const memberships = new Map<string, string[]>();
    for (const m of this.db.query<{ item_id: string; collection_id: string }, []>(
      "SELECT item_id, collection_id FROM collection_items").all()) {
      const list = memberships.get(m.item_id) ?? [];
      list.push(m.collection_id);
      memberships.set(m.item_id, list);
    }

    const citations = new Map<string, string>();
    for (const c of this.db.query<{ item_id: string; csl_json: string }, []>(
      "SELECT item_id, csl_json FROM citations").all()) {
      citations.set(c.item_id, c.csl_json);
    }

    const properties = new Map<string, PropertyValue[]>();
    for (const v of this.db.query<any, []>(
      `SELECT ipv.id AS value_id, ipv.item_id, ipv.property_id, ipv.option_id,
              ipv.text_value, p.name AS property_name, p.type AS property_type,
              po.name AS option_name, po.color_hex AS option_color_hex
         FROM item_property_values ipv
         JOIN properties p ON p.id = ipv.property_id
         LEFT JOIN property_options po ON po.id = ipv.option_id`).all()) {
      const list = properties.get(v.item_id) ?? [];
      list.push({
        id: v.value_id, propertyId: v.property_id, propertyName: v.property_name,
        propertyType: v.property_type, optionId: v.option_id,
        optionName: v.option_name, optionColorHex: v.option_color_hex,
        textValue: v.text_value,
      });
      properties.set(v.item_id, list);
    }

    return rows.map((r) => ({
      id: r.id, storageKey: r.storage_key, title: r.title, author: r.author,
      lastOpenedAt: r.last_opened_at, lastPosition: r.last_position,
      citeKey: r.cite_key, source: r.source, sourceKey: r.source_key,
      extra: r.extra, processingStatus: r.processing_status,
      deletedAt: r.deleted_at, createdAt: r.created_at, updatedAt: r.updated_at,
      attachments: attachments.get(r.id) ?? [],
      collectionIds: memberships.get(r.id) ?? [],
      citationJson: citations.get(r.id) ?? null,
      propertyValues: properties.get(r.id) ?? [],
    }));
  }
}
