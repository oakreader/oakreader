/**
 * The id-case fix, tested on the shape that broke.
 *
 * A lowercase item id is unreachable from the Swift shell, which spells every
 * id as `UUID.uuidString` — always uppercase. The citation insert then fails
 * on the foreign key and the app shows "Extracting metadata…" with no end.
 */
import { test, expect, describe } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Catalog } from "../src/catalog/db.ts";
import { MIGRATIONS, SCHEMA_SQL } from "../src/catalog/schema.ts";
import { newId } from "../src/catalog/ids.ts";
import { ReferenceStore } from "../src/catalog/references.ts";

const LOWER = "bc4d2a71-cb98-4d98-a10f-cfa19b6275e6";
const AT = "2026-10-05T00:00:00.000Z";

function scratch(): string {
  return mkdtempSync(join(tmpdir(), "oak-ids-"));
}

/** A database at the pre-v9 schema, carrying one lowercase-id item. */
function legacy(path: string): void {
  const db = new Database(path, { create: true });
  db.exec("PRAGMA foreign_keys = ON");
  db.exec(SCHEMA_SQL);
  db.exec("CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)");
  const record = db.prepare("INSERT INTO grdb_migrations (identifier) VALUES (?)");
  for (const m of MIGRATIONS) {
    if (m === "v9-canonical-id-case") continue;
    record.run(m);
  }
  db.prepare(
    `INSERT INTO items (id, user_id, storage_key, title, created_at, updated_at)
     VALUES (?, 'local', 'AZPMXBRT', 'UnderstandingDeepLearning', ?, ?)`,
  ).run(LOWER, AT, AT);
  db.prepare(
    `INSERT INTO attachments (id, item_id, storage_key, file_name, created_at, updated_at)
     VALUES (?, ?, '5UUEQKVI', 'udl.pdf', ?, ?)`,
  ).run("5a1e2f30-0000-4000-8000-000000000001", LOWER, AT, AT);
  db.close();
}

describe("newId", () => {
  test("mints the case Foundation's UUID.uuidString produces", () => {
    for (let i = 0; i < 50; i++) {
      const id = newId();
      expect(id).toBe(id.toUpperCase());
      expect(id).toMatch(/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/);
    }
  });
});

describe("v9-canonical-id-case", () => {
  test("a lowercase id is unreachable before the migration", () => {
    const dir = scratch();
    try {
      const path = join(dir, "library.sqlite");
      legacy(path);
      const db = new Database(path);
      db.exec("PRAGMA foreign_keys = ON");
      expect(() => {
        db.prepare(
          `INSERT INTO citations (item_id, csl_json, csl_type, created_at, updated_at)
           VALUES (?, '{}', 'document', ?, ?)`,
        ).run(LOWER.toUpperCase(), AT, AT);
      }).toThrow(/FOREIGN KEY/i);
      db.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("opening the catalog canonicalises ids and keeps the rows joined", () => {
    const dir = scratch();
    try {
      const path = join(dir, "library.sqlite");
      legacy(path);

      const catalog = Catalog.open(path);
      const upper = LOWER.toUpperCase();

      const item = catalog.db.query<{ id: string }, []>("SELECT id FROM items").get()!;
      expect(item.id).toBe(upper);

      const att = catalog.db.query<{ id: string; item_id: string }, []>(
        "SELECT id, item_id FROM attachments").get()!;
      expect(att.item_id).toBe(upper);
      expect(att.id).toBe("5A1E2F30-0000-4000-8000-000000000001");

      // The whole point: the app's spelling of the id now saves.
      new ReferenceStore(catalog.db).save(
        upper, JSON.stringify({ type: "book", title: "Understanding Deep Learning" }), null, AT);
      expect(new ReferenceStore(catalog.db).get(upper)).toContain("Understanding Deep Learning");

      catalog.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("leaves values that are not UUIDs alone", () => {
    const dir = scratch();
    try {
      const path = join(dir, "library.sqlite");
      legacy(path);
      const db = new Database(path);
      db.exec("PRAGMA foreign_keys = ON");
      db.prepare(
        `INSERT INTO items (id, user_id, storage_key, title, created_at, updated_at)
         VALUES ('legacy-swift-key', 'local', 'ZZZZZZZZ', 'Older', ?, ?)`,
      ).run(AT, AT);
      db.close();

      const catalog = Catalog.open(path);
      const ids = catalog.db.query<{ id: string }, []>("SELECT id FROM items ORDER BY id").all()
        .map((r) => r.id);
      expect(ids).toContain("legacy-swift-key");
      catalog.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
