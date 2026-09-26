/**
 * Collections: a hierarchy, a saved query, and a join table sharing one store.
 * The cascade behaviour and the idempotent membership insert are the parts
 * that would fail quietly if they were wrong.
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Catalog } from "../src/catalog/db.ts";
import { CollectionStore, type Collection } from "../src/catalog/collections.ts";

function withCatalog<T>(items: string[], body: (s: CollectionStore, c: Catalog) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "oak-collections-"));
  try {
    const catalog = Catalog.open(join(dir, "library.sqlite"));
    try {
      const insert = catalog.db.prepare(
        `INSERT INTO items (id, user_id, storage_key, title, created_at, updated_at)
         VALUES (?, 'local', ?, ?, '', '')`);
      for (const id of items) insert.run(id, `storage-${id}`, id);
      return body(new CollectionStore(catalog.db, "local"), catalog);
    } finally {
      catalog.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const collection = (over: Partial<Collection> = {}): Collection => ({
  id: crypto.randomUUID(),
  name: "Papers",
  icon: "folder.fill",
  sortOrder: 0,
  parentId: null,
  isSmart: false,
  isSystem: false,
  filterRules: null,
  source: null,
  sourceKey: null,
  createdAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T00:00:00Z",
  ...over,
});

describe("collections", () => {
  test("round-trips every field, booleans included", () => {
    // SQLite has no boolean type, so is_smart/is_system are INTEGER 0/1 and
    // have to survive the trip as actual booleans.
    withCatalog([], (store) => {
      const smart = collection({
        name: "Unread", isSmart: true, isSystem: true,
        filterRules: '{"all":[{"field":"read","is":false}]}',
      });
      store.upsert(smart);
      const [back] = store.list();
      expect(back).toEqual(smart);
      expect(back!.isSmart).toBe(true);
      expect(back!.isSystem).toBe(true);
    });
  });

  test("filter rules are carried opaquely, not parsed", () => {
    withCatalog([], (store) => {
      const nonsense = "{{ not json at all";
      store.upsert(collection({ isSmart: true, filterRules: nonsense }));
      expect(store.list()[0]!.filterRules).toBe(nonsense);
    });
  });

  test("upsert updates in place", () => {
    withCatalog([], (store) => {
      const one = collection({ name: "Before" });
      store.upsert(one);
      store.upsert({ ...one, name: "After", updatedAt: "2026-06-01T00:00:00Z" });

      const all = store.list();
      expect(all).toHaveLength(1);
      expect(all[0]!.name).toBe("After");
    });
  });

  test("findBySource makes an import idempotent", () => {
    withCatalog([], (store) => {
      store.upsert(collection({ source: "zotero", sourceKey: "ABCD1234" }));
      expect(store.findBySource("zotero", "ABCD1234")).not.toBeNull();
      expect(store.findBySource("zotero", "NOPE")).toBeNull();
    });
  });

  test("deleting a parent takes its subtree", () => {
    withCatalog([], (store) => {
      const parent = collection({ name: "Root" });
      const child = collection({ name: "Child", parentId: parent.id });
      const grandchild = collection({ name: "Grandchild", parentId: child.id });
      store.upsert(parent);
      store.upsert(child);
      store.upsert(grandchild);
      expect(store.list()).toHaveLength(3);

      store.delete(parent.id);
      expect(store.list()).toHaveLength(0);
    });
  });

  test("adding the same item twice is not an error", () => {
    // The primary key is (item_id, collection_id). Dragging a document onto a
    // folder it is already in should be a no-op, not a failure.
    withCatalog(["doc-1"], (store) => {
      const c = collection();
      store.upsert(c);
      store.addItem("doc-1", c.id, "2026-01-01T00:00:00Z");
      store.addItem("doc-1", c.id, "2026-02-01T00:00:00Z");

      expect(store.itemCount(c.id)).toBe(1);
      expect(store.itemIds(c.id)).toEqual(["doc-1"]);
    });
  });

  test("membership survives removal from one collection only", () => {
    withCatalog(["doc-1"], (store) => {
      const a = collection({ name: "A" });
      const b = collection({ name: "B" });
      store.upsert(a);
      store.upsert(b);
      store.addItem("doc-1", a.id, "");
      store.addItem("doc-1", b.id, "");

      store.removeItem("doc-1", a.id);
      expect(store.itemCount(a.id)).toBe(0);
      expect(store.itemCount(b.id)).toBe(1);
    });
  });

  test("deleting a collection drops its memberships, not the documents", () => {
    withCatalog(["doc-1"], (store, catalog) => {
      const c = collection();
      store.upsert(c);
      store.addItem("doc-1", c.id, "");

      store.delete(c.id);

      const items = catalog.db.query<{ n: number }, []>(
        "SELECT count(*) AS n FROM items").get()!.n;
      expect(items).toBe(1);            // the document survives
      expect(store.itemCount(c.id)).toBe(0);
    });
  });

  test("deleting a document drops it from every collection", () => {
    withCatalog(["doc-1"], (store, catalog) => {
      const c = collection();
      store.upsert(c);
      store.addItem("doc-1", c.id, "");

      catalog.db.exec("DELETE FROM items WHERE id = 'doc-1'");
      expect(store.itemCount(c.id)).toBe(0);
      expect(store.list()).toHaveLength(1);   // the collection survives
    });
  });
});
