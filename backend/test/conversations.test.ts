/**
 * Conversation metadata. The table indexes JSONL transcripts the shell owns,
 * so what matters here is ordering, the document/collection/library split, and
 * what happens to a chat when the thing it is about is deleted.
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Catalog } from "../src/catalog/db.ts";
import { ConversationStore, type Conversation } from "../src/catalog/conversations.ts";
import { seed } from "./seed.ts";

function withCatalog<T>(
  items: string[], body: (store: ConversationStore, c: Catalog) => T, collections: string[] = [],
): T {
  const dir = mkdtempSync(join(tmpdir(), "oak-conversations-"));
  try {
    const catalog = Catalog.open(join(dir, "library.sqlite"));
    try {
      const insert = catalog.db.prepare(
        `INSERT INTO items (id, user_id, storage_key, title, created_at, updated_at)
         VALUES (?, 'local', ?, ?, '', '')`);
      for (const id of items) insert.run(id, `storage-${id}`, id);
      const insertCollection = catalog.db.prepare(
        `INSERT INTO collections (id, user_id, name, created_at, updated_at)
         VALUES (?, 'local', ?, '', '')`);
      for (const id of collections) insertCollection.run(id, id);
      return body(new ConversationStore(catalog.db, "local"), catalog);
    } finally {
      catalog.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const conversation = (over: Partial<Conversation> = {}): Conversation => ({
  id: crypto.randomUUID(),
  itemId: null,
  collectionId: null,
  title: "Untitled",
  messageCount: 0,
  createdAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T00:00:00Z",
  ...over,
});

describe("conversations", () => {
  test("round-trips every field", () => {
    withCatalog(["doc-1"], (store) => {
      const one = conversation({ itemId: "doc-1", title: "On attention", messageCount: 7 });
      store.create(one);
      expect(store.list({ kind: "item", itemId: "doc-1" })).toEqual([one]);
    });
  });

  test("document, collection and library chats are three separate lists", () => {
    // `item_id = NULL` never matches in SQL, so the unscoped case needs IS NULL.
    // Getting this wrong returns an empty list rather than an error, which is
    // exactly the kind of bug that ships. The library list also has to exclude
    // collection chats, or every collection's history shows up in it.
    withCatalog(["doc-1"], (store) => {
      store.create(conversation({ itemId: "doc-1", title: "about the doc" }));
      store.create(conversation({ collectionId: "col-1", title: "about the collection" }));
      store.create(conversation({ title: "about the library" }));

      expect(store.list({ kind: "item", itemId: "doc-1" }).map((c) => c.title))
        .toEqual(["about the doc"]);
      expect(store.list({ kind: "collection", collectionId: "col-1" }).map((c) => c.title))
        .toEqual(["about the collection"]);
      expect(store.list({ kind: "library" }).map((c) => c.title))
        .toEqual(["about the library"]);
    }, ["col-1"]);
  });

  test("collection chats are kept apart from each other", () => {
    withCatalog([], (store) => {
      store.create(conversation({ collectionId: "col-1", title: "diffusion" }));
      store.create(conversation({ collectionId: "col-2", title: "rag" }));

      expect(store.list({ kind: "collection", collectionId: "col-2" }).map((c) => c.title))
        .toEqual(["rag"]);
    }, ["col-1", "col-2"]);
  });

  test("lists most recently updated first", () => {
    withCatalog([], (store) => {
      store.create(conversation({ title: "stale", updatedAt: "2026-01-01T00:00:00Z" }));
      store.create(conversation({ title: "fresh", updatedAt: "2026-06-01T00:00:00Z" }));
      expect(store.list({ kind: "library" }).map((c) => c.title)).toEqual(["fresh", "stale"]);
    });
  });

  test("update moves it to the top of the list", () => {
    withCatalog([], (store) => {
      const older = conversation({ title: "first", updatedAt: "2026-01-01T00:00:00Z" });
      const newer = conversation({ title: "second", updatedAt: "2026-02-01T00:00:00Z" });
      store.create(older);
      store.create(newer);

      store.update(older.id, "first, renamed", 12, "2026-09-01T00:00:00Z");

      const all = store.list({ kind: "library" });
      expect(all.map((c) => c.title)).toEqual(["first, renamed", "second"]);
      expect(all[0]!.messageCount).toBe(12);
    });
  });

  test("delete removes only that session", () => {
    withCatalog([], (store) => {
      const one = conversation({ title: "doomed" });
      store.create(one);
      store.create(conversation({ title: "kept" }));

      store.delete(one.id);
      expect(store.list({ kind: "library" }).map((c) => c.title)).toEqual(["kept"]);
    });
  });

  test("deleting the document takes its chats, per ON DELETE CASCADE", () => {
    withCatalog(["doc-1"], (store, catalog) => {
      store.create(conversation({ itemId: "doc-1" }));
      store.create(conversation({ title: "library chat" }));

      seed(catalog.db, "DELETE FROM items WHERE id = 'doc-1'");

      expect(store.list({ kind: "item", itemId: "doc-1" })).toHaveLength(0);
      expect(store.list({ kind: "library" })).toHaveLength(1);   // library chat survives
    });
  });

  test("deleting a collection keeps its chats, unscoped", () => {
    // SET NULL rather than CASCADE, unlike items: the transcripts are files on
    // disk that this table only indexes, and cascading would drop the index
    // rows while leaving the files behind, unreachable. Falling back to the
    // library list keeps them findable.
    withCatalog([], (store, catalog) => {
      store.create(conversation({ collectionId: "col-1", title: "kept" }));

      seed(catalog.db, "DELETE FROM collections WHERE id = 'col-1'");

      expect(store.list({ kind: "collection", collectionId: "col-1" })).toHaveLength(0);
      expect(store.list({ kind: "library" }).map((c) => c.title)).toEqual(["kept"]);
    }, ["col-1"]);
  });
});
