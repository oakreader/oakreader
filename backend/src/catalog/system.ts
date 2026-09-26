/**
 * The collections and properties the app assumes exist.
 *
 * Seeded on every open rather than once at creation, with INSERT OR IGNORE, so
 * a library that predates a new system collection gains it on the next launch
 * instead of showing an empty sidebar slot. Their ids are fixed constants —
 * the UI addresses them directly, so they cannot be generated.
 *
 * Only additions belong here. Removing a row is a one-off correction and is
 * written as one, scoped to an exact id and to `is_system` so a collection the
 * user made can never be caught by it.
 */
import type { Database } from "bun:sqlite";

export const LOCAL_USER = "local";

const COLLECTIONS: Array<{
  id: string; name: string; icon: string; order: number; rules: string | null;
}> = [
  { id: "00000000-0000-0000-0000-00000000000E", name: "Reading List", icon: "bookmark", order: -1, rules: null },
  {
    id: "00000000-0000-0000-0000-000000000002", name: "All Items",
    icon: "books.vertical", order: 0, rules: '{"match":"all","conditions":[]}',
  },
  {
    id: "00000000-0000-0000-0000-000000000008", name: "Recently Read", icon: "book", order: 1,
    rules: '{"match":"all","conditions":[{"field":"last_opened_at","op":"within_days","value":"14"}]}',
  },
  {
    id: "00000000-0000-0000-0000-000000000005", name: "PDFs", icon: "doc.fill", order: 2,
    rules: '{"match":"all","conditions":[{"field":"content_type","op":"eq","value":"pdf"}]}',
  },
  {
    id: "00000000-0000-0000-0000-000000000006", name: "Web", icon: "globe", order: 3,
    rules: '{"match":"any","conditions":[{"field":"content_type","op":"eq","value":"html"},'
      + '{"field":"content_type","op":"eq","value":"link"}]}',
  },
  { id: "00000000-0000-0000-0000-00000000000A", name: "Duplicates", icon: "square.on.square", order: 5, rules: null },
  { id: "00000000-0000-0000-0000-00000000000F", name: "Bin", icon: "trash", order: 7, rules: null },
];

/**
 * System collections that no longer exist. "Quiz Cards" was seeded before
 * quizzes moved into the per-item panel; libraries from those builds still
 * carry the row.
 */
const RETIRED_COLLECTIONS = ["00000000-0000-0000-0000-00000000000D"];

const PROPERTIES = [
  { id: "00000000-0000-0000-0001-000000000001", name: "Tags", type: "multi_select", icon: "tag", position: 0 },
  { id: "00000000-0000-0000-0001-000000000002", name: "Status", type: "single_select", icon: "circle.dotted", position: 1 },
  { id: "00000000-0000-0000-0001-000000000003", name: "Rating", type: "number", icon: "star", position: 2 },
];

const STATUS_OPTIONS = [
  { id: "00000000-0000-0000-0002-000000000001", name: "To Read", color: "2EA8E5", position: 0 },
  { id: "00000000-0000-0000-0002-000000000002", name: "Reading", color: "FF8C19", position: 1 },
  { id: "00000000-0000-0000-0002-000000000003", name: "Finished", color: "5FB236", position: 2 },
];

const STATUS_PROPERTY = PROPERTIES[1]!.id;

export function ensureSystemData(db: Database, at: string): void {
  db.transaction(() => {
    const collection = db.prepare(
      `INSERT OR IGNORE INTO collections
         (id, user_id, name, icon, sort_order, parent_id, is_smart, is_system,
          filter_rules, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, NULL, 1, 1, ?, ?, ?)`);
    for (const c of COLLECTIONS) {
      collection.run(c.id, LOCAL_USER, c.name, c.icon, c.order, c.rules, at, at);
    }

    const retire = db.prepare("DELETE FROM collections WHERE id = ? AND is_system = 1");
    for (const id of RETIRED_COLLECTIONS) retire.run(id);

    const property = db.prepare(
      `INSERT OR IGNORE INTO properties (id, name, type, icon, position, is_system)
       VALUES (?, ?, ?, ?, ?, 1)`);
    for (const p of PROPERTIES) property.run(p.id, p.name, p.type, p.icon, p.position);

    const option = db.prepare(
      `INSERT OR IGNORE INTO property_options (id, property_id, name, color_hex, position)
       VALUES (?, ?, ?, ?, ?)`);
    for (const o of STATUS_OPTIONS) {
      option.run(o.id, STATUS_PROPERTY, o.name, o.color, o.position);
    }
  })();
}
