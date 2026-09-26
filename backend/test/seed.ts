import type { Database } from "bun:sqlite";

/**
 * Run seed statements one at a time, so a broken one fails the test.
 *
 * `db.exec` accepts several statements separated by semicolons and, when one of
 * them violates a constraint, silently skips it and carries on — no throw, no
 * row. A seed that quietly disappears leaves the assertions testing an empty
 * table, which is how a test passes while proving nothing. Preparing each
 * statement separately turns that into the error it should have been.
 */
export function seed(db: Database, sql: string): void {
  for (const statement of sql.split(";")) {
    const trimmed = statement.trim();
    if (trimmed !== "") db.prepare(trimmed).run();
  }
}
