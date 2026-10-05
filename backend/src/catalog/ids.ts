/**
 * One canonical spelling for an id.
 *
 * The Swift shell reads every id into a Foundation `UUID` and writes it back
 * as `UUID.uuidString`, which is always uppercase. An id stored in any other
 * case therefore comes back from the app as a *different string*, and every
 * write keyed on it misses: `citations.item_id` has a foreign key to
 * `items(id)`, so saving reference metadata for a lowercase-id item failed
 * with FOREIGN KEY constraint failed and the item sat on "Extracting
 * metadata…" forever.
 *
 * Node's `randomUUID()` is lowercase, so the `oak` CLI minted ids the app
 * could never address. Uppercase is the canonical form here because it is the
 * one Foundation produces, and the app is the writer that cannot be changed
 * without rewriting every id it holds.
 */
import { randomUUID } from "node:crypto";

/** A new id, in the only case the catalog stores. */
export function newId(): string {
  return randomUUID().toUpperCase();
}

/**
 * Every column holding an id, as `table: [columns]`.
 *
 * Used by the v9 migration to repair rows written before `newId` existed.
 * `user_id` is absent on purpose: it holds `local`, not a UUID.
 */
export const ID_COLUMNS: Readonly<Record<string, readonly string[]>> = {
  items: ["id"],
  attachments: ["id", "item_id"],
  collections: ["id", "parent_id"],
  collection_items: ["item_id", "collection_id"],
  properties: ["id"],
  property_options: ["id", "property_id"],
  item_property_values: ["id", "item_id", "property_id", "option_id"],
  conversations: ["id", "item_id", "collection_id"],
  citations: ["item_id"],
  annotations: ["id", "item_id", "attachment_id"],
  word_lookups: ["id", "item_id"],
};

/** The dashed 8-4-4-4-12 hex shape, as a GLOB over the lowercased value. */
const UUID_GLOB = [8, 4, 4, 4, 12].map((n) => "[0-9a-f]".repeat(n)).join("-");

/**
 * `upper(col)`, but only where the value really is a UUID.
 *
 * A blanket `upper()` would mangle anything else that shares the column, and
 * these columns are plain TEXT with no shape enforced by the schema.
 */
function canonical(column: string): string {
  const c = `"${column}"`;
  return `CASE WHEN ${c} IS NOT NULL AND length(${c}) = 36 `
    + `AND lower(${c}) GLOB '${UUID_GLOB}' THEN upper(${c}) ELSE ${c} END`;
}

/**
 * SQL that rewrites every stored id to its canonical case.
 *
 * `defer_foreign_keys` holds the checks to COMMIT: an UPDATE on a parent key
 * leaves its children pointing at the old value until their own UPDATE runs,
 * and that intermediate state is a violation under immediate enforcement.
 */
export function canonicalizeIdsSql(): string {
  const statements = ["PRAGMA defer_foreign_keys = ON;"];
  for (const [table, columns] of Object.entries(ID_COLUMNS)) {
    const assignments = columns.map((c) => `"${c}" = ${canonical(c)}`).join(", ");
    const guard = columns.map((c) => `"${c}" <> upper("${c}")`).join(" OR ");
    statements.push(`UPDATE "${table}" SET ${assignments} WHERE ${guard};`);
  }
  return statements.join("\n");
}
