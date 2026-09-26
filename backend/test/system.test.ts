/**
 * The seeded collections and properties the UI addresses by fixed id.
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Catalog } from "../src/catalog/db.ts";

function withCatalog<T>(body: (c: Catalog, path: string) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "oak-system-"));
  try {
    const path = join(dir, "library.sqlite");
    const catalog = Catalog.open(path);
    try {
      return body(catalog, path);
    } finally {
      catalog.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const READING_LIST = "00000000-0000-0000-0000-00000000000E";
const TAGS = "00000000-0000-0000-0001-000000000001";

describe("system data", () => {
  test("a fresh library comes with its system collections and properties", () => {
    withCatalog((catalog) => {
      const collections = catalog.db.query<{ name: string }, []>(
        "SELECT name FROM collections WHERE is_system = 1 ORDER BY sort_order").all();
      expect(collections.map((c) => c.name)).toEqual([
        "Reading List", "All Items", "Recently Read", "PDFs", "Web", "Duplicates", "Bin",
      ]);

      const properties = catalog.db.query<{ name: string; type: string }, []>(
        "SELECT name, type FROM properties WHERE is_system = 1 ORDER BY position").all();
      expect(properties).toEqual([
        { name: "Tags", type: "multi_select" },
        { name: "Status", type: "single_select" },
        { name: "Rating", type: "number" },
      ]);

      expect(catalog.db.query<{ name: string }, []>(
        "SELECT name FROM property_options ORDER BY position").all().map((o) => o.name))
        .toEqual(["To Read", "Reading", "Finished"]);
    });
  });

  test("the ids are fixed, because the UI addresses them directly", () => {
    withCatalog((catalog) => {
      expect(catalog.db.query<{ name: string }, [string]>(
        "SELECT name FROM collections WHERE id = ?").get(READING_LIST)?.name)
        .toBe("Reading List");
      expect(catalog.db.query<{ name: string }, [string]>(
        "SELECT name FROM properties WHERE id = ?").get(TAGS)?.name).toBe("Tags");
    });
  });

  test("reopening neither duplicates the seed nor overwrites an edit", () => {
    withCatalog((catalog, path) => {
      catalog.db.exec(
        `UPDATE collections SET name = 'Renamed' WHERE id = '${READING_LIST}'`);
      catalog.close();

      const reopened = Catalog.open(path);
      try {
        expect(reopened.db.query<{ n: number }, []>(
          "SELECT count(*) AS n FROM collections WHERE is_system = 1").get()!.n).toBe(7);
        expect(reopened.db.query<{ name: string }, [string]>(
          "SELECT name FROM collections WHERE id = ?").get(READING_LIST)?.name).toBe("Renamed");
      } finally {
        reopened.close();
      }
    });
  });

  test("a retired system collection is removed on open", () => {
    withCatalog((catalog, path) => {
      catalog.db.exec(
        `INSERT INTO collections (id, user_id, name, icon, sort_order, is_smart, is_system, created_at, updated_at)
         VALUES ('00000000-0000-0000-0000-00000000000D', 'local', 'Quiz Cards', 'square', 9, 1, 1, '', '')`);
      catalog.close();

      const reopened = Catalog.open(path);
      try {
        expect(reopened.db.query<{ n: number }, []>(
          "SELECT count(*) AS n FROM collections WHERE name = 'Quiz Cards'").get()!.n).toBe(0);
      } finally {
        reopened.close();
      }
    });
  });
});
