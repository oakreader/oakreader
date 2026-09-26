/**
 * Conversation metadata. The table indexes JSONL transcripts the shell owns,
 * so what matters here is ordering, the document/library split, and that
 * deleting a document takes its chats with it.
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Catalog } from "../src/catalog/db.ts";
import { ConversationStore, type Conversation } from "../src/catalog/conversations.ts";

function withCatalog<T>(items: string[], body: (store: ConversationStore, c: Catalog) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "oak-conversations-"));
  try {
    const catalog = Catalog.open(join(dir, "library.sqlite"));
    try {
      const insert = catalog.db.prepare(
        `INSERT INTO items (id, user_id, storage_key, title, created_at, updated_at)
         VALUES (?, 'local', ?, ?, '', '')`);
      for (const id of items) insert.run(id, `storage-${id}`, id);
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
      expect(store.list("doc-1")).toEqual([one]);
    });
  });

  test("document chats and library chats are separate lists", () => {
    // `item_id = NULL` never matches in SQL, so the library case needs IS NULL.
    // Getting this wrong returns an empty list rather than an error, which is
    // exactly the kind of bug that ships.
    withCatalog(["doc-1"], (store) => {
      store.create(conversation({ itemId: "doc-1", title: "about the doc" }));
      store.create(conversation({ itemId: null, title: "about the library" }));

      expect(store.list("doc-1").map((c) => c.title)).toEqual(["about the doc"]);
      expect(store.list(null).map((c) => c.title)).toEqual(["about the library"]);
    });
  });

  test("lists most recently updated first", () => {
    withCatalog([], (store) => {
      store.create(conversation({ title: "stale", updatedAt: "2026-01-01T00:00:00Z" }));
      store.create(conversation({ title: "fresh", updatedAt: "2026-06-01T00:00:00Z" }));
      expect(store.list(null).map((c) => c.title)).toEqual(["fresh", "stale"]);
    });
  });

  test("update moves it to the top of the list", () => {
    withCatalog([], (store) => {
      const older = conversation({ title: "first", updatedAt: "2026-01-01T00:00:00Z" });
      const newer = conversation({ title: "second", updatedAt: "2026-02-01T00:00:00Z" });
      store.create(older);
      store.create(newer);

      store.update(older.id, "first, renamed", 12, "2026-09-01T00:00:00Z");

      const all = store.list(null);
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
      expect(store.list(null).map((c) => c.title)).toEqual(["kept"]);
    });
  });

  test("deleting the document takes its chats, per ON DELETE CASCADE", () => {
    withCatalog(["doc-1"], (store, catalog) => {
      store.create(conversation({ itemId: "doc-1" }));
      store.create(conversation({ itemId: null, title: "library chat" }));

      catalog.db.exec("DELETE FROM items WHERE id = 'doc-1'");

      expect(store.list("doc-1")).toHaveLength(0);
      expect(store.list(null)).toHaveLength(1);   // library chat survives
    });
  });
});
