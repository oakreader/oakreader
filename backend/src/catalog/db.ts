/**
 * Opening the catalog, and the one rule that makes phase 1 safe.
 *
 * Exactly one process owns the schema. That process is this one — the Swift
 * shell stops running migrations entirely and asks over the protocol instead.
 * A period where both sides hold their own DDL against `library.sqlite` is not
 * a migration step, it is two writers racing on a user's library.
 *
 * Adoption, not conversion: a database written by the Swift app already has
 * the seven baseline identifiers in `grdb_migrations`, so opening it applies
 * none of them. A fresh database gets SCHEMA_SQL and the same seven rows,
 * which keeps a downgrade to the Swift catalog working.
 *
 * Schema changes made *since* that move are a different thing and carry their
 * own DDL — see POST_BASELINE_MIGRATIONS. Adoption is what happens once; those
 * are ordinary migrations.
 */
import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { BASELINE_MIGRATIONS, MIGRATIONS, POST_BASELINE_MIGRATIONS, SCHEMA_SQL } from "./schema.js";
import { ensureSystemData } from "./system.js";

export interface OpenOptions {
  /** Refuse to write. Used by the verification harness. */
  readonly?: boolean;
  /** Where to report what adoption decided. */
  log?: (message: string) => void;
}

export class Catalog {
  readonly db: Database;

  private constructor(db: Database) {
    this.db = db;
  }

  static open(path: string, options: OpenOptions = {}): Catalog {
    const log = options.log ?? (() => {});
    if (!options.readonly) mkdirSync(dirname(path), { recursive: true });

    const db = new Database(path, options.readonly ? { readonly: true } : { create: true });

    // Match what GRDB configured, so behaviour does not shift under the app:
    // foreign keys enforced, WAL for concurrent readers.
    db.exec("PRAGMA foreign_keys = ON");
    if (!options.readonly) db.exec("PRAGMA journal_mode = WAL");

    const catalog = new Catalog(db);
    if (!options.readonly) {
      catalog.migrate(log);
      // Every open, not just creation: a library from an older build gains a
      // system collection added since, rather than showing an empty slot.
      ensureSystemData(db, new Date().toISOString());
    }
    return catalog;
  }

  /**
   * Bring the database to this build's schema.
   *
   * Three cases, and the middle one is the reason this is not a loop over a
   * single list. An empty database gets SCHEMA_SQL, which already states the
   * destination, so every identifier is recorded without running any step. A
   * database carrying the whole baseline is one the Swift app (or an earlier
   * build of this one) wrote, and only needs the steps added since. A database
   * carrying *part* of the baseline is from a build we do not know, and the
   * only safe move is to refuse: the alternative is running DDL over tables
   * whose shape we have not seen.
   */
  private migrate(log: (message: string) => void): void {
    this.db.exec("CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)");
    const applied = new Set(
      this.db.query<{ identifier: string }, []>("SELECT identifier FROM grdb_migrations").all()
        .map((r) => r.identifier),
    );
    const record = this.db.prepare("INSERT INTO grdb_migrations (identifier) VALUES (?)");

    if (applied.size === 0) {
      log(`catalog: fresh database, creating schema`);
      this.db.transaction(() => {
        this.db.exec(SCHEMA_SQL);
        for (const m of MIGRATIONS) record.run(m);
      })();
      return;
    }

    const missingBaseline = BASELINE_MIGRATIONS.filter((m) => !applied.has(m));
    if (missingBaseline.length > 0) {
      throw new Error(
        `catalog: database has ${applied.size} of ${MIGRATIONS.length} migrations ` +
        `(missing: ${missingBaseline.join(", ")}). Refusing to modify a library from an unknown build.`,
      );
    }

    const pending = POST_BASELINE_MIGRATIONS.filter((m) => !applied.has(m.id));
    if (pending.length === 0) {
      log(`catalog: adopted existing database (${applied.size} migrations already applied)`);
      return;
    }

    // One transaction per step, so a failure leaves the steps before it
    // applied and recorded rather than replaying them on the next open.
    for (const migration of pending) {
      this.db.transaction(() => {
        this.db.exec(migration.sql);
        record.run(migration.id);
      })();
      log(`catalog: applied ${migration.id}`);
    }
  }

  /** Row counts for every table, for reconciling against a known baseline. */
  tableCounts(): Record<string, number> {
    const tables = this.db.query<{ name: string }, []>(
      `SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`,
    ).all();
    const out: Record<string, number> = {};
    for (const { name } of tables) {
      out[name] = this.db.query<{ n: number }, []>(`SELECT count(*) AS n FROM "${name}"`).get()!.n;
    }
    return out;
  }

  close(): void {
    this.db.close();
  }
}
