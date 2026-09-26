/**
 * Opening the catalog, and the one rule that makes phase 1 safe.
 *
 * Exactly one process owns the schema. That process is this one — the Swift
 * shell stops running migrations entirely and asks over the protocol instead.
 * A period where both sides hold their own DDL against `library.sqlite` is not
 * a migration step, it is two writers racing on a user's library.
 *
 * Adoption, not conversion: a database written by the Swift app already has
 * the seven identifiers in `grdb_migrations`, so opening it applies nothing.
 * A fresh database gets SCHEMA_SQL and the same seven rows, which keeps a
 * downgrade to the Swift catalog working.
 */
import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { MIGRATIONS, SCHEMA_SQL } from "./schema.js";

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
    if (!options.readonly) catalog.migrate(log);
    return catalog;
  }

  /**
   * Apply anything missing. On an existing library this is a no-op that only
   * reads `grdb_migrations` — the schema is already exactly right, because
   * Swift wrote it with the same DDL.
   */
  private migrate(log: (message: string) => void): void {
    this.db.exec("CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)");
    const applied = new Set(
      this.db.query<{ identifier: string }, []>("SELECT identifier FROM grdb_migrations").all()
        .map((r) => r.identifier),
    );

    const missing = MIGRATIONS.filter((m) => !applied.has(m));
    if (missing.length === 0) {
      log(`catalog: adopted existing database (${applied.size} migrations already applied)`);
      return;
    }
    if (applied.size > 0) {
      // Partial state means a database from a build we do not know about.
      // Bailing is the only safe move: the alternative is running DDL over
      // tables whose shape we have not seen.
      throw new Error(
        `catalog: database has ${applied.size} of ${MIGRATIONS.length} migrations ` +
        `(missing: ${missing.join(", ")}). Refusing to modify a library from an unknown build.`,
      );
    }

    log(`catalog: fresh database, creating schema`);
    this.db.transaction(() => {
      this.db.exec(SCHEMA_SQL);
      const record = this.db.prepare("INSERT INTO grdb_migrations (identifier) VALUES (?)");
      for (const m of MIGRATIONS) record.run(m);
    })();
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
