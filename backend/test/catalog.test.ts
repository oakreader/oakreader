/**
 * The premise of phase 1, tested against a real library rather than a fixture.
 *
 * Two things have to hold before any store is worth writing:
 *   1. An existing database opens unchanged — adopted, not converted.
 *   2. A database this code creates is indistinguishable from one Swift
 *      created, so a rollback to the Swift catalog still works.
 *
 * Point 2 is the one that would be easy to get subtly wrong and impossible to
 * notice until a user downgraded, so it is compared at the DDL level, not by
 * poking at a few columns.
 *
 * Pass OAK_LIBRARY to run against a specific library; otherwise the real one
 * is used when present, and the suite skips the real-database checks when not.
 */
import { test, expect, describe } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { Catalog } from "../src/catalog/db.ts";
import { MIGRATIONS } from "../src/catalog/schema.ts";
import { WordLookupStore, type WordLookup } from "../src/catalog/wordLookups.ts";

const REAL_LIBRARY = process.env.OAK_LIBRARY ?? join(homedir(), "OakReader", "library.sqlite");
const hasReal = existsSync(REAL_LIBRARY);

/** Normalised DDL for every object, so two databases can be compared as sets. */
function schemaOf(path: string): string[] {
  const db = new Database(path, { readonly: true });
  try {
    return db.query<{ sql: string | null }, []>(
      `SELECT sql FROM sqlite_master
        WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
        ORDER BY type, name`,
    ).all()
      .map((r) => r.sql!.replace(/"/g, "").replace(/\s+/g, " ").trim())
      .sort();
  } finally {
    db.close();
  }
}

function scratch(): string {
  return mkdtempSync(join(tmpdir(), "oak-catalog-"));
}

/**
 * Take a consistent copy of a live database.
 *
 * NOT `cp`: the catalog runs in WAL mode, so recent commits live in the
 * sidecar `-wal` file and a plain file copy silently loses them. This caught a
 * real bug in the phase-1 backup procedure -- the app was running, and 680 KB
 * of committed rows sat in the WAL while the copy showed two fewer items and
 * five fewer word lookups. VACUUM INTO goes through SQLite, which sees the
 * whole database.
 */
function snapshot(source: string, destination: string): void {
  const db = new Database(source, { readonly: true });
  try {
    db.exec(`VACUUM INTO '${destination.replace(/'/g, "''")}'`);
  } finally {
    db.close();
  }
}

describe("fresh database", () => {
  test("records every migration identifier, in GRDB's names", () => {
    const dir = scratch();
    try {
      const catalog = Catalog.open(join(dir, "library.sqlite"));
      const applied = catalog.db
        .query<{ identifier: string }, []>("SELECT identifier FROM grdb_migrations ORDER BY identifier")
        .all().map((r) => r.identifier);
      expect(applied.sort()).toEqual([...MIGRATIONS].sort());
      catalog.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("opening twice is a no-op, not a second schema run", () => {
    const dir = scratch();
    try {
      const path = join(dir, "library.sqlite");
      Catalog.open(path).close();
      const before = schemaOf(path);
      Catalog.open(path).close();           // would throw on duplicate DDL
      expect(schemaOf(path)).toEqual(before);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("enforces foreign keys, as GRDB did", () => {
    const dir = scratch();
    try {
      const catalog = Catalog.open(join(dir, "library.sqlite"));
      expect(() =>
        catalog.db.exec(
          `INSERT INTO attachments (id, item_id, storage_key, file_name, created_at, updated_at)
           VALUES ('a', 'no-such-item', 'k', 'f.pdf', '', '')`),
      ).toThrow();
      catalog.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe.if(hasReal)("a real library", () => {
  test("is adopted, not modified", () => {
    const dir = scratch();
    try {
      const copy = join(dir, "library.sqlite");
      snapshot(REAL_LIBRARY, copy);
      const before = schemaOf(copy);

      const messages: string[] = [];
      const catalog = Catalog.open(copy, { log: (m) => messages.push(m) });
      catalog.close();

      expect(messages.join(" ")).toContain("adopted existing database");
      expect(schemaOf(copy)).toEqual(before);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("reads every row the file contains", () => {
    const dir = scratch();
    try {
      const copy = join(dir, "library.sqlite");
      snapshot(REAL_LIBRARY, copy);

      const reference = new Database(REAL_LIBRARY, { readonly: true });
      const expected: Record<string, number> = {};
      for (const { name } of reference.query<{ name: string }, []>(
        `SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'`).all()) {
        expected[name] = reference.query<{ n: number }, []>(`SELECT count(*) AS n FROM "${name}"`).get()!.n;
      }
      reference.close();

      const catalog = Catalog.open(copy);
      expect(catalog.tableCounts()).toEqual(expected);
      catalog.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a database we create matches one Swift created, object for object", () => {
    const dir = scratch();
    try {
      const fresh = join(dir, "fresh.sqlite");
      Catalog.open(fresh).close();
      // The real library carries data, not extra structure, so the DDL sets
      // must be identical. A difference here is a downgrade that breaks.
      expect(schemaOf(fresh)).toEqual(schemaOf(REAL_LIBRARY));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

/**
 * The store itself. Behaviour is pinned against what WordLookupStore.swift did,
 * because a shipped library already contains rows written under those rules.
 */
describe("word lookups", () => {
  /**
   * Foreign keys are enforced here exactly as CatalogDatabase.swift enforced
   * them (`config.foreignKeysEnabled = true`), so a lookup cannot name a
   * document that does not exist. Tests create the documents they reference
   * rather than working around the constraint.
   */
  function withCatalog<T>(items: string[], body: (c: Catalog) => T): T {
    const dir = scratch();
    try {
      const catalog = Catalog.open(join(dir, "library.sqlite"));
      try {
        const insert = catalog.db.prepare(
          `INSERT INTO items (id, user_id, storage_key, title, created_at, updated_at)
           VALUES (?, 'local', ?, ?, '', '')`);
        for (const id of items) insert.run(id, `storage-${id}`, id);
        return body(catalog);
      } finally { catalog.close(); }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  const lookup = (over: Partial<WordLookup> = {}): WordLookup => ({
    id: crypto.randomUUID(),
    itemId: null,
    itemTitle: "",
    word: "ephemeral",
    sentence: "An ephemeral thing.",
    explanation: "Lasting a short time.",
    createdAt: new Date(2026, 0, 1).toISOString(),
    ...over,
  });

  test("round-trips every field", () => {
    withCatalog([], (c) => {
      const store = new WordLookupStore(c.db, "local");
      const one = lookup({ itemTitle: "Some Paper" });
      store.save(one);
      expect(store.listAll()).toEqual([one]);
    });
  });

  test("re-looking up the same word in the same document replaces the card", () => {
    withCatalog(["item-1"], (c) => {
      const store = new WordLookupStore(c.db, "local");
      store.save(lookup({ itemId: "item-1", explanation: "first" }));
      store.save(lookup({ itemId: "item-1", explanation: "second" }));
      const all = store.listAll();
      expect(all).toHaveLength(1);
      expect(all[0]!.explanation).toBe("second");
    });
  });

  test("the same word in two documents keeps two cards", () => {
    withCatalog(["item-1", "item-2"], (c) => {
      const store = new WordLookupStore(c.db, "local");
      store.save(lookup({ itemId: "item-1" }));
      store.save(lookup({ itemId: "item-2" }));
      expect(store.listAll()).toHaveLength(2);
    });
  });

  test("dedupe ignores case, as the Swift key did", () => {
    withCatalog([], (c) => {
      const store = new WordLookupStore(c.db, "local");
      store.save(lookup({ word: "Ephemeral" }));
      store.save(lookup({ word: "ephemeral" }));
      expect(store.listAll()).toHaveLength(1);
    });
  });

  test("lists newest first, and scopes by document", () => {
    withCatalog(["a", "b"], (c) => {
      const store = new WordLookupStore(c.db, "local");
      store.save(lookup({ itemId: "a", word: "older", createdAt: new Date(2026, 0, 1).toISOString() }));
      store.save(lookup({ itemId: "a", word: "newer", createdAt: new Date(2026, 5, 1).toISOString() }));
      store.save(lookup({ itemId: "b", word: "elsewhere" }));

      expect(store.list("a").map((l) => l.word)).toEqual(["newer", "older"]);
      expect(store.listAll()).toHaveLength(3);
    });
  });

  test("clear takes one document or everything", () => {
    withCatalog(["a", "b"], (c) => {
      const store = new WordLookupStore(c.db, "local");
      store.save(lookup({ itemId: "a" }));
      store.save(lookup({ itemId: "b" }));

      store.clear("a");
      expect(store.listAll()).toHaveLength(1);
      store.clear(null);
      expect(store.listAll()).toHaveLength(0);
    });
  });

  test("deleting the document keeps the card, per ON DELETE SET NULL", () => {
    withCatalog([], (c) => {
      c.db.exec(
        `INSERT INTO items (id, user_id, storage_key, title, created_at, updated_at)
         VALUES ('doomed', 'local', 'k1', 'Doomed', '', '')`);
      const store = new WordLookupStore(c.db, "local");
      store.save(lookup({ itemId: "doomed", itemTitle: "Doomed" }));

      c.db.exec("DELETE FROM items WHERE id = 'doomed'");

      const all = store.listAll();
      expect(all).toHaveLength(1);
      expect(all[0]!.itemId).toBeNull();
      expect(all[0]!.itemTitle).toBe("Doomed");   // denormalised title survives
    });
  });
});
