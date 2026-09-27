/**
 * Collections — the folder tree, smart collections, and item membership.
 *
 * Three things that live together because they share a table: a hierarchy
 * (`parent_id` self-references), a saved query (`is_smart` plus
 * `filter_rules`), and a many-to-many join to items.
 *
 * `filterRules` is carried as an opaque JSON string. The rule language belongs
 * to whatever evaluates it, and the core neither parses nor validates it —
 * storing a blob the shell understands is honest, where a half-modelled schema
 * would invite the two to disagree about what a rule means.
 */
import type { Database } from "bun:sqlite";

export interface Collection {
  id: string;
  name: string;
  icon: string;
  sortOrder: number;
  /** Null at the top level; self-referencing, ON DELETE CASCADE. */
  parentId: string | null;
  /** A saved query rather than a folder: membership comes from filterRules. */
  isSmart: boolean;
  /** Built-in, not user-created. */
  isSystem: boolean;
  /** Opaque to the core; the shell owns the rule language. */
  filterRules: string | null;
  /** Provenance for imported trees, e.g. Zotero. */
  source: string | null;
  sourceKey: string | null;
  createdAt: string;
  updatedAt: string;
}

interface Row {
  id: string; name: string; icon: string; sort_order: number;
  parent_id: string | null; is_smart: number; is_system: number;
  filter_rules: string | null; source: string | null; source_key: string | null;
  created_at: string; updated_at: string;
}

const COLUMNS = `id, name, icon, sort_order, parent_id, is_smart, is_system,
  filter_rules, source, source_key, created_at, updated_at`;

function toDomain(r: Row): Collection {
  return {
    id: r.id, name: r.name, icon: r.icon, sortOrder: r.sort_order,
    parentId: r.parent_id,
    // SQLite has no boolean type; the column is INTEGER 0/1.
    isSmart: r.is_smart !== 0,
    isSystem: r.is_system !== 0,
    filterRules: r.filter_rules, source: r.source, sourceKey: r.source_key,
    createdAt: r.created_at, updatedAt: r.updated_at,
  };
}

export class CollectionStore {
  constructor(private readonly db: Database, private readonly userId: string) {}

  /** Every collection, ordered for display. */
  list(): Collection[] {
    return this.db.query<Row, []>(
      `SELECT ${COLUMNS} FROM collections ORDER BY sort_order, name`).all().map(toDomain);
  }

  /** Look one up by where it came from — used to make imports idempotent. */
  findBySource(source: string, sourceKey: string): Collection | null {
    const row = this.db.query<Row, [string, string]>(
      `SELECT ${COLUMNS} FROM collections WHERE source = ? AND source_key = ?`,
    ).get(source, sourceKey);
    return row ? toDomain(row) : null;
  }

  upsert(c: Collection): void {
    this.db.prepare(
      `INSERT INTO collections
         (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system,
          filter_rules, source, source_key, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name, icon = excluded.icon,
         sort_order = excluded.sort_order, parent_id = excluded.parent_id,
         is_smart = excluded.is_smart, is_system = excluded.is_system,
         filter_rules = excluded.filter_rules, source = excluded.source,
         source_key = excluded.source_key, updated_at = excluded.updated_at`,
    ).run(
      c.id, this.userId, c.name, c.icon, c.sortOrder, c.parentId,
      c.isSmart ? 1 : 0, c.isSystem ? 1 : 0,
      c.filterRules, c.source, c.sourceKey, c.createdAt, c.updatedAt,
    );
  }

  /** Removes the collection and, by cascade, its subtree and memberships. */
  delete(id: string): void {
    this.db.prepare("DELETE FROM collections WHERE id = ?").run(id);
  }

  // --- membership --------------------------------------------------------

  /**
   * Add an item. Idempotent: the primary key is (item_id, collection_id), so
   * adding twice is not an error and must not be treated as one.
   */
  addItem(itemId: string, collectionId: string, at: string): void {
    this.db.prepare(
      `INSERT INTO collection_items (item_id, collection_id, created_at)
       VALUES (?, ?, ?)
       ON CONFLICT(item_id, collection_id) DO NOTHING`,
    ).run(itemId, collectionId, at);
  }

  removeItem(itemId: string, collectionId: string): void {
    this.db.prepare(
      "DELETE FROM collection_items WHERE item_id = ? AND collection_id = ?",
    ).run(itemId, collectionId);
  }

  /** Item ids in a collection. Plain folders only — a smart one is a query. */
  itemCount(collectionId: string): number {
    return this.db.query<{ n: number }, [string]>(
      "SELECT count(*) AS n FROM collection_items WHERE collection_id = ?",
    ).get(collectionId)!.n;
  }
}
