/**
 * Annotation CRUD, pinned against what AnnotationStore.swift did — a shipped
 * library already holds rows written under those rules, including 200 in the
 * author's own.
 */
import { test, expect, describe } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Catalog } from "../src/catalog/db.ts";
import { AnnotationStore, type Annotation } from "../src/catalog/annotations.ts";

/** A catalog with one item and one attachment to hang annotations off. */
function withAttachment<T>(body: (store: AnnotationStore, db: Catalog) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "oak-annotations-"));
  try {
    const catalog = Catalog.open(join(dir, "library.sqlite"));
    try {
      catalog.db.exec(`
        INSERT INTO items (id, user_id, storage_key, title, created_at, updated_at)
        VALUES ('item-1', 'local', 'sk-1', 'A Paper', '2026-01-01', '2026-01-01');
        INSERT INTO attachments (id, item_id, storage_key, file_name, created_at, updated_at)
        VALUES ('att-1', 'item-1', 'sk-2', 'paper.pdf', '2026-01-01', '2026-01-01');
      `);
      return body(new AnnotationStore(catalog.db, "local"), catalog);
    } finally {
      catalog.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

let keySeed = 0;
const annotation = (over: Partial<Annotation> = {}): Annotation => ({
  id: crypto.randomUUID(),
  itemId: "item-1",
  attachmentId: "att-1",
  key: `K${(++keySeed).toString().padStart(7, "0")}`,
  type: "highlight",
  authorName: null,
  text: "a passage",
  comment: null,
  color: "#ffd400",
  pageLabel: "1",
  sortIndex: "00000|000100|000050",
  positionKind: "pdf",
  positionJson: '{"page":0,"rects":[[10,20,30,40]]}',
  styleJson: null,
  source: "oakreader",
  sourceKey: null,
  createdAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T00:00:00Z",
  deletedAt: null,
  ...over,
});

describe("annotations", () => {
  test("round-trips every column", () => {
    withAttachment((store) => {
      const one = annotation({ comment: "worth revisiting", authorName: "Jiwei" });
      store.upsert(one);
      expect(store.get(one.id)).toEqual(one);
    });
  });

  test("reads in sort-index order, not insertion order", () => {
    withAttachment((store) => {
      // The index is computed shell-side from PDF geometry; the core only
      // sorts the string, which is the whole point of keeping it opaque.
      store.upsert(annotation({ sortIndex: "00002|000100|000050", text: "page three" }));
      store.upsert(annotation({ sortIndex: "00000|000300|000050", text: "page one, lower" }));
      store.upsert(annotation({ sortIndex: "00000|000100|000050", text: "page one, upper" }));

      expect(store.listForAttachment("att-1").map((a) => a.text))
        .toEqual(["page one, upper", "page one, lower", "page three"]);
    });
  });

  test("upsert replaces in place rather than duplicating", () => {
    withAttachment((store) => {
      const one = annotation({ comment: "first" });
      store.upsert(one);
      store.upsert({ ...one, comment: "second", updatedAt: "2026-06-01T00:00:00Z" });

      const all = store.listForAttachment("att-1");
      expect(all).toHaveLength(1);
      expect(all[0]!.comment).toBe("second");
      expect(all[0]!.updatedAt).toBe("2026-06-01T00:00:00Z");
    });
  });

  test("soft delete hides the row but keeps it for sync", () => {
    withAttachment((store) => {
      const one = annotation();
      store.upsert(one);
      store.softDelete(one.id, "2026-06-01T00:00:00Z");

      expect(store.listForAttachment("att-1")).toHaveLength(0);
      const tombstone = store.get(one.id);
      expect(tombstone).not.toBeNull();
      expect(tombstone!.deletedAt).toBe("2026-06-01T00:00:00Z");
    });
  });

  test("hard delete actually removes it", () => {
    withAttachment((store) => {
      const one = annotation();
      store.upsert(one);
      store.hardDelete(one.id);
      expect(store.get(one.id)).toBeNull();
    });
  });

  test("scopes to the attachment asked for", () => {
    withAttachment((store, catalog) => {
      catalog.db.exec(
        `INSERT INTO attachments (id, item_id, storage_key, file_name, created_at, updated_at)
         VALUES ('att-2', 'item-1', 'sk-3', 'other.pdf', '2026-01-01', '2026-01-01')`);
      store.upsert(annotation({ attachmentId: "att-1" }));
      store.upsert(annotation({ attachmentId: "att-2" }));

      expect(store.listForAttachment("att-1")).toHaveLength(1);
      expect(store.listForAttachment("att-2")).toHaveLength(1);
    });
  });

  test("deleting the attachment cascades, as the schema says", () => {
    withAttachment((store, catalog) => {
      store.upsert(annotation());
      catalog.db.exec("DELETE FROM attachments WHERE id = 'att-1'");
      expect(store.listForAttachment("att-1")).toHaveLength(0);
    });
  });

  test("the unique key is enforced", () => {
    withAttachment((store) => {
      store.upsert(annotation({ key: "DUPLICATE" }));
      expect(() => store.upsert(annotation({ key: "DUPLICATE" }))).toThrow();
    });
  });
});
