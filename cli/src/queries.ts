/**
 * The reads the CLI needs, in the shapes it prints.
 *
 * Writes are deliberately absent: those go through the core's stores
 * (`backend/src/catalog/*`), which is the whole point of this rewrite — the
 * Swift CLI carried its own 850-line copy of the catalog, so a rule like
 * "Tags is multi-select but Status is single-select" was implemented twice and
 * could disagree with itself. Reads are different: they are projections for
 * display, and giving the CLI its own is not duplication, it is its job.
 */
import type { Database } from "bun:sqlite";

export interface Item {
  id: string;
  title: string;
  author: string;
  citeKey: string | null;
  storageKey: string;
  createdAt: string;
  updatedAt: string;
  lastOpenedAt: string | null;
}

export interface Attachment {
  id: string;
  itemId: string;
  fileName: string;
  contentType: string;
  sourceURL: string | null;
  fileSize: number;
  pageCount: number;
  isPrimary: boolean;
  storageKey: string;
}

export interface Collection {
  id: string;
  name: string;
  icon: string;
  sortOrder: number;
  parentId: string | null;
  isSmart: boolean;
  isSystem: boolean;
  createdAt: string;
}

export interface PropertyOption {
  id: string;
  propertyId: string;
  name: string;
  colorHex: string;
  position: number;
}

export interface WordLookup {
  id: string;
  word: string;
  sentence: string;
  explanation: string;
  itemTitle: string;
  createdAt: string;
}

export interface Note {
  id: string;
  itemId: string;
  itemTitle: string;
  positionKind: string;
  text: string | null;
  comment: string;
  createdAt: string;
}

export interface SearchResult {
  itemId: string;
  title: string;
  author: string;
  citeKey: string | null;
  contentType: string | null;
  pageCount: number | null;
  year: number | null;
  doi: string | null;
  journal: string | null;
  abstract: string | null;
  tags: string | null;
}

export interface ItemFilePath {
  itemStorageKey: string;
  attachmentStorageKey: string;
  fileName: string;
  contentType: string;
  pageCount: number;
}

const ITEM_COLUMNS =
  "id, title, author, cite_key, storage_key, created_at, updated_at, last_opened_at";

function toItem(r: any): Item {
  return {
    id: r.id, title: r.title, author: r.author, citeKey: r.cite_key,
    storageKey: r.storage_key, createdAt: r.created_at,
    updatedAt: r.updated_at, lastOpenedAt: r.last_opened_at,
  };
}

function toAttachment(r: any): Attachment {
  return {
    id: r.id, itemId: r.item_id, fileName: r.file_name,
    contentType: r.content_type, sourceURL: r.source_url,
    fileSize: r.file_size, pageCount: r.page_count,
    isPrimary: r.is_primary !== 0, storageKey: r.storage_key,
  };
}

function toCollection(r: any): Collection {
  return {
    id: r.id, name: r.name, icon: r.icon, sortOrder: r.sort_order,
    parentId: r.parent_id, isSmart: r.is_smart !== 0,
    isSystem: r.is_system !== 0, createdAt: r.created_at,
  };
}

function toOption(r: any): PropertyOption {
  return {
    id: r.id, propertyId: r.property_id, name: r.name,
    colorHex: r.color_hex, position: r.position,
  };
}

/** "video" and "web" are how people say it; the column stores something else. */
export function mapItemType(input: string): string {
  switch (input.toLowerCase()) {
    case "pdf": return "pdf";
    case "web": case "websnapshot": case "html": return "html";
    case "video": case "embed": return "video";
    case "link": case "bookmark": return "link";
    case "note": case "markdown": return "markdown";
    default: return input;
  }
}

export interface ItemFilters {
  collectionName?: string;
  tagName?: string;
  type?: string;
  search?: string;
  sort?: string;
  limit?: number;
}

export class Queries {
  constructor(private readonly db: Database) {}

  // --- items -------------------------------------------------------------

  listItems(f: ItemFilters = {}): Array<{ item: Item; attachments: Attachment[] }> {
    const joins: string[] = [];
    const conditions: string[] = [];
    const args: Array<string | number> = [];

    if (f.collectionName !== undefined) {
      joins.push(`JOIN collection_items ci ON ci.item_id = i.id
                  JOIN collections c ON c.id = ci.collection_id`);
      conditions.push("LOWER(c.name) = LOWER(?)");
      args.push(f.collectionName);
    }
    if (f.tagName !== undefined) {
      joins.push(`JOIN item_property_values ipv ON ipv.item_id = i.id
                  JOIN property_options po ON po.id = ipv.option_id
                  JOIN properties p ON p.id = ipv.property_id AND p.name = 'Tags'`);
      conditions.push("LOWER(po.name) = LOWER(?)");
      args.push(f.tagName);
    }
    if (f.type !== undefined) {
      joins.push("JOIN attachments a_type ON a_type.item_id = i.id AND a_type.is_primary = 1");
      conditions.push("a_type.content_type = ?");
      args.push(mapItemType(f.type));
    }
    if (f.search !== undefined) {
      // Case-insensitive substring over title / author / filename, matching
      // what the app's own search means. instr() rather than LIKE, so a % or _
      // the user types stays a literal.
      conditions.push(`(instr(LOWER(i.title), ?) > 0
        OR instr(LOWER(i.author), ?) > 0
        OR EXISTS (SELECT 1 FROM attachments a_search
                   WHERE a_search.item_id = i.id
                     AND instr(LOWER(a_search.file_name), ?) > 0))`);
      const needle = f.search.toLowerCase();
      args.push(needle, needle, needle);
    }

    const order = {
      title: "ORDER BY LOWER(i.title) ASC",
      author: "ORDER BY LOWER(i.author) ASC, LOWER(i.title) ASC",
      date: "ORDER BY i.created_at DESC",
    }[f.sort?.toLowerCase() ?? ""] ?? "ORDER BY i.created_at DESC";

    let sql = `SELECT DISTINCT ${ITEM_COLUMNS.split(", ").map((c) => `i.${c}`).join(", ")}
               FROM items i ${joins.join(" ")}`;
    if (conditions.length > 0) sql += ` WHERE ${conditions.join(" AND ")}`;
    sql += ` ${order}`;
    if (f.limit !== undefined) {
      sql += " LIMIT ?";
      args.push(f.limit);
    }

    return this.db.query<any, any>(sql).all(...args).map((r) => {
      const item = toItem(r);
      return { item, attachments: this.attachmentsOf(item.id) };
    });
  }

  /**
   * The item already imported from this URL, if there is one.
   *
   * Matched on the attachment, which is where the origin is recorded. The
   * app's own duplicate test (`findItem(bySourceURL:)`), so the terminal and
   * the app agree on what "already in the library" means.
   */
  findItemBySourceURL(url: string): Item | null {
    const row = this.db.query<any, [string]>(
      `SELECT ${ITEM_COLUMNS.split(", ").map((c) => `i.${c}`).join(", ")}
         FROM items i JOIN attachments a ON a.item_id = i.id
        WHERE a.source_url = ? AND i.deleted_at IS NULL
        LIMIT 1`).get(url);
    return row === null ? null : toItem(row);
  }

  findItem(id: string): { item: Item; attachments: Attachment[] } | null {
    const row = this.db.query<any, [string]>(
      `SELECT ${ITEM_COLUMNS} FROM items WHERE id = ?`).get(id);
    if (row === null) return null;
    return { item: toItem(row), attachments: this.attachmentsOf(id) };
  }

  private attachmentsOf(itemId: string): Attachment[] {
    return this.db.query<any, [string]>(
      `SELECT id, item_id, file_name, content_type, source_url, file_size,
              page_count, is_primary, storage_key
         FROM attachments WHERE item_id = ? ORDER BY is_primary DESC`,
    ).all(itemId).map(toAttachment);
  }

  itemTags(itemId: string): PropertyOption[] {
    return this.db.query<any, [string]>(
      `SELECT po.* FROM property_options po
         JOIN item_property_values ipv ON ipv.option_id = po.id
         JOIN properties p ON p.id = ipv.property_id AND p.name = 'Tags'
        WHERE ipv.item_id = ? ORDER BY po.position`).all(itemId).map(toOption);
  }

  itemStatus(itemId: string): PropertyOption | null {
    const row = this.db.query<any, [string]>(
      `SELECT po.* FROM property_options po
         JOIN item_property_values ipv ON ipv.option_id = po.id
         JOIN properties p ON p.id = ipv.property_id AND p.name = 'Status'
        WHERE ipv.item_id = ?`).get(itemId);
    return row === null ? null : toOption(row);
  }

  itemCollections(itemId: string): Collection[] {
    return this.db.query<any, [string]>(
      `SELECT c.* FROM collections c
         JOIN collection_items ci ON ci.collection_id = c.id
        WHERE ci.item_id = ? AND c.is_system = 0
        ORDER BY c.name`).all(itemId).map(toCollection);
  }

  /** The primary attachment's location and type, for reading its text. */
  itemFilePath(itemId: string): ItemFilePath | null {
    const row = this.db.query<any, [string]>(
      `SELECT i.storage_key, a.storage_key AS att_key, a.file_name,
              a.content_type, a.page_count
         FROM items i JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
        WHERE i.id = ?`).get(itemId);
    if (row === null) return null;
    return {
      itemStorageKey: row.storage_key, attachmentStorageKey: row.att_key,
      fileName: row.file_name, contentType: row.content_type,
      pageCount: row.page_count,
    };
  }

  /** Every primary attachment's location, for hash-based duplicate detection. */
  attachmentPaths(): Array<{ itemStorageKey: string; attachmentStorageKey: string; fileName: string }> {
    return this.db.query<any, []>(
      `SELECT i.storage_key AS item_key, a.storage_key AS att_key, a.file_name
         FROM attachments a JOIN items i ON i.id = a.item_id
        WHERE a.is_primary = 1`).all().map((r) => ({
      itemStorageKey: r.item_key, attachmentStorageKey: r.att_key, fileName: r.file_name,
    }));
  }

  itemByStorageKey(storageKey: string): Item | null {
    const row = this.db.query<any, [string]>(
      `SELECT ${ITEM_COLUMNS} FROM items WHERE storage_key = ?`).get(storageKey);
    return row === null ? null : toItem(row);
  }

  // --- collections and tags ----------------------------------------------

  /** User collections only: the smart and system ones are not yours to edit. */
  listCollections(): Collection[] {
    return this.db.query<any, []>(
      `SELECT * FROM collections WHERE is_smart = 0 AND is_system = 0
        ORDER BY sort_order, LOWER(name)`).all().map(toCollection);
  }

  collectionItemCount(collectionId: string): number {
    return this.db.query<{ n: number }, [string]>(
      "SELECT count(*) AS n FROM collection_items WHERE collection_id = ?",
    ).get(collectionId)!.n;
  }

  nextCollectionOrder(): number {
    return this.db.query<{ n: number }, []>(
      "SELECT COALESCE(MAX(sort_order), 0) AS n FROM collections WHERE is_system = 0",
    ).get()!.n + 1;
  }

  propertyId(name: string): string | null {
    return this.db.query<{ id: string }, [string]>(
      "SELECT id FROM properties WHERE name = ?").get(name)?.id ?? null;
  }

  listTags(): Array<{ tag: PropertyOption; count: number }> {
    return this.db.query<any, []>(
      `SELECT po.*, COUNT(ipv.id) AS item_count
         FROM property_options po
         JOIN properties p ON p.id = po.property_id AND p.name = 'Tags'
         LEFT JOIN item_property_values ipv ON ipv.option_id = po.id
        GROUP BY po.id ORDER BY po.position`).all().map((r) => ({
      tag: toOption(r), count: r.item_count,
    }));
  }

  listOptions(propertyName: string): PropertyOption[] {
    return this.db.query<any, [string]>(
      `SELECT po.* FROM property_options po
         JOIN properties p ON p.id = po.property_id AND p.name = ?
        ORDER BY po.position`).all(propertyName).map(toOption);
  }

  nextOptionPosition(propertyId: string): number {
    return this.db.query<{ n: number }, [string]>(
      "SELECT COALESCE(MAX(position), -1) AS n FROM property_options WHERE property_id = ?",
    ).get(propertyId)!.n + 1;
  }

  // --- words and notes ---------------------------------------------------

  wordLookups(since: string | null, limit: number | null): WordLookup[] {
    let sql = `SELECT id, word, sentence, explanation, item_title, created_at
                 FROM word_lookups`;
    const args: string[] = [];
    if (since !== null) {
      sql += " WHERE created_at >= ?";
      args.push(since);
    }
    sql += " ORDER BY created_at DESC";
    if (limit !== null) sql += ` LIMIT ${limit}`;
    return this.db.query<any, any>(sql).all(...args).map((r) => ({
      id: r.id, word: r.word, sentence: r.sentence, explanation: r.explanation,
      itemTitle: r.item_title, createdAt: r.created_at,
    }));
  }

  /**
   * The Notes panel's stream: annotations that carry a comment, newest first.
   * Soft-deleted notes and notes on trashed items are left out, because the
   * panel leaves them out.
   */
  notes(itemId: string | null, since: string | null, limit: number | null): Note[] {
    let sql = `SELECT a.id, a.item_id, i.title AS item_title, a.position_kind,
                      a.text, a.comment, a.created_at
                 FROM annotations a JOIN items i ON i.id = a.item_id
                WHERE a.deleted_at IS NULL AND i.deleted_at IS NULL
                  AND a.comment IS NOT NULL AND TRIM(a.comment) <> ''`;
    const args: string[] = [];
    if (itemId !== null) {
      sql += " AND a.item_id = ?";
      args.push(itemId);
    }
    if (since !== null) {
      sql += " AND a.created_at >= ?";
      args.push(since);
    }
    sql += " ORDER BY a.created_at DESC";
    if (limit !== null) sql += ` LIMIT ${limit}`;
    return this.db.query<any, any>(sql).all(...args).map((r) => ({
      id: r.id, itemId: r.item_id, itemTitle: r.item_title,
      positionKind: r.position_kind, text: r.text, comment: r.comment,
      createdAt: r.created_at,
    }));
  }

  stats(): { items: number; collections: number; tags: number } {
    const one = (sql: string) => this.db.query<{ n: number }, []>(sql).get()!.n;
    return {
      items: one("SELECT count(*) AS n FROM items"),
      collections: one(
        "SELECT count(*) AS n FROM collections WHERE is_smart = 0 AND is_system = 0"),
      tags: one(`SELECT count(*) AS n FROM property_options po
                   JOIN properties p ON p.id = po.property_id AND p.name = 'Tags'`),
    };
  }

  // --- search ------------------------------------------------------------

  /**
   * Keyword search across title, author, abstract, DOI, journal and tags.
   *
   * A union of facets: an item matches if any one of them does. Within title
   * and author every word must appear, which is what the FTS5 MATCH this
   * replaced did with space-separated terms.
   */
  search(query: string, limit: number): SearchResult[] {
    const words = query.toLowerCase().split(/\s+/).filter((w) => w !== "");
    if (words.length === 0) return [];

    const ids = new Set<string>();
    const collect = (sql: string, args: string[], column: string) => {
      for (const row of this.db.query<any, any>(sql).all(...args)) ids.add(row[column]);
    };

    collect(
      `SELECT i.id FROM items i
        WHERE ${words.map(() => "instr(LOWER(i.title || ' ' || i.author), ?) > 0").join(" AND ")}`,
      words, "id");

    if (words.length <= 5) {
      collect(
        `SELECT c.item_id FROM citations c
          WHERE c.abstract IS NOT NULL
            AND (${words.map(() => "c.abstract LIKE ?").join(" AND ")})`,
        words.map((w) => `%${w}%`), "item_id");
    }

    const full = `%${query}%`;
    collect("SELECT item_id FROM citations WHERE doi LIKE ?", [full], "item_id");
    collect("SELECT item_id FROM citations WHERE container_title LIKE ?", [full], "item_id");
    collect(
      `SELECT DISTINCT ipv.item_id FROM item_property_values ipv
         JOIN property_options po ON po.id = ipv.option_id
        WHERE ${words.map(() => "po.name LIKE ?").join(" OR ")}`,
      words.map((w) => `%${w}%`), "item_id");

    if (ids.size === 0) return [];
    return this.searchDetails([...ids], limit);
  }

  private searchDetails(ids: string[], limit: number): SearchResult[] {
    const rows = this.db.query<any, any>(
      `SELECT i.id, i.title, i.author, i.cite_key,
              a.content_type, a.page_count,
              c.year, c.doi, c.container_title, c.abstract,
              (SELECT GROUP_CONCAT(po.name, ', ')
                 FROM item_property_values ipv
                 JOIN property_options po ON po.id = ipv.option_id
                 JOIN properties p ON p.id = ipv.property_id AND p.name = 'Tags'
                WHERE ipv.item_id = i.id) AS tag_names
         FROM items i
         LEFT JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
         LEFT JOIN citations c ON c.item_id = i.id
        WHERE i.id IN (${ids.map(() => "?").join(",")})
        ORDER BY CASE WHEN i.last_opened_at IS NOT NULL THEN 0 ELSE 1 END,
                 i.last_opened_at DESC, i.created_at DESC
        LIMIT ?`).all(...ids, limit);

    return rows.map((r) => ({
      itemId: r.id, title: r.title, author: r.author, citeKey: r.cite_key,
      contentType: r.content_type, pageCount: r.page_count, year: r.year,
      doi: r.doi, journal: r.container_title, abstract: r.abstract,
      tags: r.tag_names,
    }));
  }

  // --- resolution --------------------------------------------------------

  /**
   * Every item matching an identifier, in narrowing order: id, exact title,
   * exact cite key, then prefixes of each. The first rung that matches wins,
   * so a title that is also another item's prefix does not turn into an
   * ambiguity.
   */
  findItems(input: string): Item[] {
    const rungs: Array<[string, string]> = [
      [`SELECT ${ITEM_COLUMNS} FROM items WHERE LOWER(id) = LOWER(?)`, input],
      [`SELECT ${ITEM_COLUMNS} FROM items WHERE LOWER(title) = LOWER(?)`, input],
      [`SELECT ${ITEM_COLUMNS} FROM items WHERE LOWER(cite_key) = LOWER(?)`, input],
      [`SELECT ${ITEM_COLUMNS} FROM items WHERE LOWER(title) LIKE LOWER(?) || '%'`, input],
      [`SELECT ${ITEM_COLUMNS} FROM items WHERE LOWER(cite_key) LIKE LOWER(?) || '%'`, input],
    ];
    for (const [sql, arg] of rungs) {
      const rows = this.db.query<any, [string]>(sql).all(arg);
      if (rows.length > 0) return rows.map(toItem);
    }
    return [];
  }

  findCollections(input: string): Collection[] {
    const rungs: string[] = [
      "SELECT * FROM collections WHERE id = ?",
      "SELECT * FROM collections WHERE LOWER(name) = LOWER(?) AND is_system = 0",
      "SELECT * FROM collections WHERE LOWER(name) LIKE LOWER(?) || '%' AND is_system = 0",
    ];
    for (const sql of rungs) {
      const rows = this.db.query<any, [string]>(sql).all(input);
      if (rows.length > 0) return rows.map(toCollection);
    }
    return [];
  }

  findTags(input: string): PropertyOption[] {
    const base = `SELECT po.* FROM property_options po
                    JOIN properties p ON p.id = po.property_id AND p.name = 'Tags'`;
    const rungs: string[] = [
      `${base} WHERE po.id = ?`,
      `${base} WHERE LOWER(po.name) = LOWER(?)`,
      `${base} WHERE LOWER(po.name) LIKE LOWER(?) || '%'`,
    ];
    for (const sql of rungs) {
      const rows = this.db.query<any, [string]>(sql).all(input);
      if (rows.length > 0) return rows.map(toOption);
    }
    return [];
  }
}
