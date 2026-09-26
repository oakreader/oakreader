/**
 * Merging duplicates. The interesting part is not that rows move — it is what
 * deliberately does not move the same way: a transferred attachment stops being
 * primary, a citation only fills a gap, and a tag the keeper already wears is
 * not added twice.
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Catalog } from "../src/catalog/db.ts";
import { ItemStore } from "../src/catalog/items.ts";
import { PropertyStore } from "../src/catalog/properties.ts";
import { seed } from "./seed.ts";

const NOW = "2026-09-26T00:00:00Z";

function withCatalog<T>(body: (s: ItemStore, c: Catalog) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "oak-merge-"));
  try {
    const catalog = Catalog.open(join(dir, "library.sqlite"));
    try {
      seed(catalog.db, 
        `INSERT INTO items (id, user_id, storage_key, title, created_at, updated_at)
         VALUES ('keeper', 'local', 'sk-k', 'A Paper', '', ''),
                ('dup', 'local', 'sk-d', 'A Paper (1)', '', '')`);
      return body(new ItemStore(catalog.db, "local"), catalog);
    } finally {
      catalog.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function addAttachment(c: Catalog, id: string, itemId: string, isPrimary: boolean) {
  c.db.prepare(
    `INSERT INTO attachments
       (id, item_id, storage_key, file_name, content_type, link_mode, file_size,
        page_count, is_primary, created_at, updated_at)
     VALUES (?, ?, ?, ?, 'pdf', 'imported_file', 0, 0, ?, '', '')`,
  ).run(id, itemId, `sk-${id}`, `${id}.pdf`, isPrimary ? 1 : 0);
}

describe("merge", () => {
  test("a transferred attachment stops being primary", () => {
    withCatalog((store, catalog) => {
      addAttachment(catalog, "a-keep", "keeper", true);
      addAttachment(catalog, "a-dup", "dup", true);

      store.merge("keeper", ["dup"], NOW);

      const rows = catalog.db.query<{ id: string; is_primary: number }, []>(
        "SELECT id, is_primary FROM attachments ORDER BY id").all();
      expect(rows).toEqual([
        { id: "a-dup", is_primary: 0 },
        { id: "a-keep", is_primary: 1 },
      ]);
    });
  });

  test("the duplicate is gone and the keeper survives", () => {
    withCatalog((store, catalog) => {
      store.merge("keeper", ["dup"], NOW);
      expect(catalog.db.query<{ id: string }, []>("SELECT id FROM items").all())
        .toEqual([{ id: "keeper" }]);
    });
  });

  test("merging an item into itself is refused, not destructive", () => {
    withCatalog((store, catalog) => {
      store.merge("keeper", ["keeper"], NOW);
      expect(catalog.db.query<{ n: number }, []>(
        "SELECT count(*) AS n FROM items WHERE id = 'keeper'").get()!.n).toBe(1);
    });
  });

  test("collection memberships combine without duplicating a shared one", () => {
    withCatalog((store, catalog) => {
      seed(catalog.db, 
        `INSERT INTO collections (id, user_id, name, icon, sort_order, created_at, updated_at)
         VALUES ('c-shared', 'local', 'Shared', 'folder', 0, '', ''),
                ('c-only', 'local', 'Only', 'folder', 1, '', '');
         INSERT INTO collection_items (item_id, collection_id, created_at)
         VALUES ('keeper', 'c-shared', ''), ('dup', 'c-shared', ''), ('dup', 'c-only', '')`);

      store.merge("keeper", ["dup"], NOW);

      expect(catalog.db.query<{ collection_id: string }, []>(
        "SELECT collection_id FROM collection_items ORDER BY collection_id").all())
        .toEqual([{ collection_id: "c-only" }, { collection_id: "c-shared" }]);
    });
  });

  test("a tag the keeper already wears is not added twice", () => {
    withCatalog((store, catalog) => {
      const props = new PropertyStore(catalog.db);
      props.upsertProperty({
        id: "p-tags", name: "Tags", type: "multi_select", icon: "tag",
        position: 0, isSystem: true,
      });
      props.upsertOption({
        id: "o-shared", propertyId: "p-tags", name: "Shared", colorHex: "ff0000", position: 0,
      });
      props.upsertOption({
        id: "o-extra", propertyId: "p-tags", name: "Extra", colorHex: "00ff00", position: 1,
      });
      props.addSelectValue("v1", "keeper", "p-tags", "o-shared");
      props.addSelectValue("v2", "dup", "p-tags", "o-shared");
      props.addSelectValue("v3", "dup", "p-tags", "o-extra");

      store.merge("keeper", ["dup"], NOW);

      expect(catalog.db.query<{ option_id: string }, []>(
        "SELECT option_id FROM item_property_values ORDER BY option_id").all())
        .toEqual([{ option_id: "o-extra" }, { option_id: "o-shared" }]);
    });
  });

  test("a citation moves only when the keeper lacks one", () => {
    withCatalog((store, catalog) => {
      seed(catalog.db, 
        `INSERT INTO citations (item_id, csl_json, created_at, updated_at)
         VALUES ('keeper', '{"title":"kept"}', '', ''),
                ('dup', '{"title":"discarded"}', '', '')`);

      store.merge("keeper", ["dup"], NOW);

      const rows = catalog.db.query<{ item_id: string; csl_json: string }, []>(
        "SELECT item_id, csl_json FROM citations").all();
      expect(rows).toEqual([{ item_id: "keeper", csl_json: '{"title":"kept"}' }]);
    });
  });

  test("a keeper with no citation adopts the duplicate's", () => {
    withCatalog((store, catalog) => {
      seed(catalog.db, 
        `INSERT INTO citations (item_id, csl_json, created_at, updated_at)
         VALUES ('dup', '{"title":"adopted"}', '', '')`);

      store.merge("keeper", ["dup"], NOW);

      expect(catalog.db.query<{ item_id: string; csl_json: string }, []>(
        "SELECT item_id, csl_json FROM citations").all())
        .toEqual([{ item_id: "keeper", csl_json: '{"title":"adopted"}' }]);
    });
  });

  test("annotations and conversations follow the item", () => {
    withCatalog((store, catalog) => {
      addAttachment(catalog, "a-dup", "dup", true);
      seed(catalog.db, 
        `INSERT INTO annotations
           (id, user_id, item_id, attachment_id, key, type, sort_index,
            position_kind, position_json, created_at, updated_at)
         VALUES ('an-1', 'local', 'dup', 'a-dup', 'k-1', 'highlight', '00001',
                 'pdf', '{}', '', '');
         INSERT INTO conversations (id, user_id, item_id, title, created_at, updated_at)
         VALUES ('cv-1', 'local', 'dup', 'Chat', '', '')`);

      store.merge("keeper", ["dup"], NOW);

      expect(catalog.db.query<{ item_id: string }, []>(
        "SELECT item_id FROM annotations").all()).toEqual([{ item_id: "keeper" }]);
      expect(catalog.db.query<{ item_id: string }, []>(
        "SELECT item_id FROM conversations").all()).toEqual([{ item_id: "keeper" }]);
    });
  });
});
