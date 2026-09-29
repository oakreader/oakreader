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
import {
  BASELINE_MIGRATIONS, MIGRATIONS, POST_BASELINE_MIGRATIONS, SCHEMA_SQL,
} from "../src/catalog/schema.ts";
import { WordLookupStore, type WordLookup } from "../src/catalog/wordLookups.ts";
import { seed } from "./seed.ts";

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
    seed(db, `VACUUM INTO '${destination.replace(/'/g, "''")}'`);
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
        seed(catalog.db, 
          `INSERT INTO attachments (id, item_id, storage_key, file_name, created_at, updated_at)
           VALUES ('a', 'no-such-item', 'k', 'f.pdf', '', '')`),
      ).toThrow();
      catalog.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

/**
 * A schema change applied to a database that already exists.
 *
 * The real-library tests above only run on a machine that has one, so the
 * behaviour is pinned here too, against a database built to the shape this
 * build inherited.
 */
describe("migrating an existing database", () => {
  /** SCHEMA_SQL as it stood before the conversation scope was added. */
  const LEGACY_SCHEMA = SCHEMA_SQL
    .replace(`, "collection_id" TEXT REFERENCES "collections"("id") ON DELETE SET NULL`, "")
    .replace(`CREATE INDEX "idx_conversations_collection_id" ON "conversations"("collection_id");\n`, "");

  /** A database carrying the baseline and nothing after it. */
  function legacy(path: string): void {
    const db = new Database(path, { create: true });
    try {
      db.exec("PRAGMA foreign_keys = ON");
      db.exec("CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)");
      db.exec(LEGACY_SCHEMA);
      const record = db.prepare("INSERT INTO grdb_migrations (identifier) VALUES (?)");
      for (const m of BASELINE_MIGRATIONS) record.run(m);
      seed(db,
        `INSERT INTO conversations (id, user_id, item_id, title, message_count, created_at, updated_at)
         VALUES ('c1', 'local', NULL, 'an old chat', 3, '2026-01-01', '2026-01-01')`);
    } finally {
      db.close();
    }
  }

  /** The conversations line of a schema, which is the only one that differs. */
  const conversationsDDL = (sql: string) =>
    sql.split("\n").find((line) => line.startsWith(`CREATE TABLE IF NOT EXISTS "conversations"`))!;

  test("the legacy shape really is the old one", () => {
    // If the DDL is edited without updating the two replacements above, this
    // test stops testing anything — so it checks itself first. Scoped to the
    // conversations line because `collection_items` has a `collection_id` of
    // its own, which a whole-file search would find either way.
    expect(conversationsDDL(LEGACY_SCHEMA)).not.toContain("collection_id");
    expect(conversationsDDL(SCHEMA_SQL)).toContain("collection_id");
    expect(LEGACY_SCHEMA).not.toContain("idx_conversations_collection_id");
  });

  test("conversation scope: fresh and migrated agree", () => {
    const dir = scratch();
    try {
      const old = join(dir, "old.sqlite");
      legacy(old);
      Catalog.open(old).close();

      const fresh = join(dir, "fresh.sqlite");
      Catalog.open(fresh).close();

      expect(schemaOf(old)).toEqual(schemaOf(fresh));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("keeps the rows it already had", () => {
    const dir = scratch();
    try {
      const path = join(dir, "old.sqlite");
      legacy(path);

      const catalog = Catalog.open(path);
      const row = catalog.db.query<{ title: string; collection_id: string | null }, []>(
        "SELECT title, collection_id FROM conversations").get()!;
      expect(row.title).toBe("an old chat");
      expect(row.collection_id).toBeNull();   // an existing chat is scoped to nothing
      catalog.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("records the identifier, so the step runs once", () => {
    const dir = scratch();
    try {
      const path = join(dir, "old.sqlite");
      legacy(path);

      Catalog.open(path).close();
      const messages: string[] = [];
      Catalog.open(path, { log: (m) => messages.push(m) }).close();   // would throw on a re-run ALTER

      expect(messages.join(" ")).toContain("adopted existing database");
      const db = new Database(path, { readonly: true });
      const applied = db.query<{ identifier: string }, []>(
        "SELECT identifier FROM grdb_migrations").all().map((r) => r.identifier);
      db.close();
      expect(applied.sort()).toEqual([...MIGRATIONS].sort());
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a partly-applied baseline is still refused", () => {
    // The guard that predates this: a database from a build we do not know
    // must not be touched. Adding incremental steps must not weaken it.
    const dir = scratch();
    try {
      const path = join(dir, "unknown.sqlite");
      const db = new Database(path, { create: true });
      db.exec("CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)");
      db.exec(`INSERT INTO grdb_migrations (identifier) VALUES ('${BASELINE_MIGRATIONS[0]}')`);
      db.close();

      expect(() => Catalog.open(path)).toThrow(/unknown build/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("every post-baseline migration carries DDL", () => {
    for (const migration of POST_BASELINE_MIGRATIONS) {
      expect(migration.sql.trim()).not.toBe("");
    }
  });
});

describe.if(hasReal)("a real library", () => {
  test("gains the pending migrations and nothing else", () => {
    // Adoption is still what happens to the baseline — a real library's seven
    // identifiers run no DDL. What may change is the steps added since, and
    // this pins that the open touches only those: the schema afterwards has to
    // equal the schema a fresh database of this build gets.
    const dir = scratch();
    try {
      const copy = join(dir, "library.sqlite");
      snapshot(REAL_LIBRARY, copy);

      const messages: string[] = [];
      Catalog.open(copy, { log: (m) => messages.push(m) }).close();

      const fresh = join(dir, "fresh.sqlite");
      Catalog.open(fresh).close();
      expect(schemaOf(copy)).toEqual(schemaOf(fresh));

      // And the second open has nothing left to do.
      const second: string[] = [];
      Catalog.open(copy, { log: (m) => second.push(m) }).close();
      expect(second.join(" ")).toContain("adopted existing database");
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
      const counts = catalog.tableCounts();
      catalog.close();

      // Opening applies the migrations added since the library was written, so
      // the bookkeeping table gains a row per step. Everything else — the data —
      // has to be untouched.
      expect(counts.grdb_migrations).toBe(MIGRATIONS.length);
      delete counts.grdb_migrations;
      delete expected.grdb_migrations;
      expect(counts).toEqual(expected);
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
      // must be identical once it has been brought up to this build. Compared
      // against a migrated copy rather than the file itself: the difference
      // between them is exactly POST_BASELINE_MIGRATIONS, which is the point
      // of the test above, not of this one.
      const migrated = join(dir, "migrated.sqlite");
      snapshot(REAL_LIBRARY, migrated);
      Catalog.open(migrated).close();

      expect(schemaOf(fresh)).toEqual(schemaOf(migrated));
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
      seed(c.db, 
        `INSERT INTO items (id, user_id, storage_key, title, created_at, updated_at)
         VALUES ('doomed', 'local', 'k1', 'Doomed', '', '')`);
      const store = new WordLookupStore(c.db, "local");
      store.save(lookup({ itemId: "doomed", itemTitle: "Doomed" }));

      seed(c.db, "DELETE FROM items WHERE id = 'doomed'");

      const all = store.listAll();
      expect(all).toHaveLength(1);
      expect(all[0]!.itemId).toBeNull();
      expect(all[0]!.itemTitle).toBe("Doomed");   // denormalised title survives
    });
  });
});

describe("validation", () => {
  test("a library this build wrote is accepted", () => {
    const dir = mkdtempSync(join(tmpdir(), "oak-validate-"));
    try {
      const path = join(dir, "library.sqlite");
      Catalog.open(path).close();
      expect(() => Catalog.open(path).close()).not.toThrow();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a library from a build we do not know is refused, not modified", () => {
    // Partial migration state is the shape a backup from an unknown version
    // takes. Running DDL over tables we have not seen is the one thing worse
    // than refusing to open it.
    //
    // A *baseline* identifier is what has to be missing. A missing
    // post-baseline one is not an unknown build — it is an ordinary pending
    // migration, and gets applied (see "migrating an existing database").
    const dir = mkdtempSync(join(tmpdir(), "oak-validate-"));
    try {
      const path = join(dir, "library.sqlite");
      const catalog = Catalog.open(path);
      catalog.db.exec(
        `DELETE FROM grdb_migrations WHERE identifier = '${BASELINE_MIGRATIONS[0]}'`);
      catalog.close();

      expect(() => Catalog.open(path)).toThrow(/unknown build/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
