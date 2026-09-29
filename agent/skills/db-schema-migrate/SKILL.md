---
name: db-schema-migrate
description: "Audit and safely refactor OakReader's GRDB catalog schema — find dead tables/columns (created by a migration but never read/written), decide whether to collapse vs append migrations, and run a data-preserving backup → fresh-schema → reimport → verify migration. Invoke when the user says 'schema audit', 'clean up migrations', 'collapse migrations', 'dead tables', 'is this a good schema', 'migrate the database', 'reimport library data', '整理 schema', '清理 migration', '数据库迁移', or wants the catalog DB reorganized before release."
---

# DB Schema Audit & Safe Migration (GRDB catalog)

OakReader has **two** SQLite databases. Know which is which before touching anything:

| DB | File | Migrator | Holds | If schema changes |
|----|------|----------|-------|-------------------|
| **catalog** | `~/OakReader-Dev/library.sqlite` (Debug) · `~/OakReader/library.sqlite` (Release) | `CatalogMigrations.swift` (`DatabaseMigrator`, append-only `vN-…`) | the real library: items, attachments, collections, properties, conversations, citations, annotations, word_lookups | **write a migration** (this skill) |
| **search** | `…/search.sqlite` | `FTSDatabase.swift` (`eraseDatabaseOnSchemaChange = true`) | chunks + FTS5 — fully regenerable from source | just edit the DDL; it auto-erases & the indexer rebuilds. Never migrate it. |

Paths come from `CatalogStoragePaths.swift` (`dataDirectory`: `OakReader-Dev` in DEBUG, `OakReader` in Release). The Debug app you rebuild locally uses **`OakReader-Dev`**.

## Part 1 — Audit (read-only)

1. **Map the migrations**: read `app/Services/CatalogMigrations.swift`. Each `registerMigration("vN-…")` is one step. Flag churn: a table created in one step and dropped/rebuilt in a later one (e.g. `notes` added then dropped; quiz_cards rebuilt; data-only `UPDATE` steps).

2. **Find dead tables/columns** — created by a migration but never used by app code. A table is live only if it has a GRDB record type OR real SQL against it:
   ```bash
   # record types that map to tables:
   grep -rn --include="*.swift" "databaseTableName" OakReader Packages | grep -v CatalogMigrations
   # for each suspect table, look for real usage (record type or SQL):
   grep -rn --include="*.swift" '"TABLE"\|FROM TABLE\|INTO TABLE\|UPDATE TABLE' OakReader Packages | grep -v CatalogMigrations
   ```
   A suspect column: grep its camelCase name; if it's only ever **written a constant** and never read in a branch/`WHERE`, it's dead. (e.g. `is_external` was always written `false`, never read.)

3. **Confirm against the live DB** (quit the app first; it holds a WAL lock):
   ```bash
   sqlite3 ~/OakReader-Dev/library.sqlite "SELECT identifier FROM grdb_migrations ORDER BY identifier;"
   sqlite3 ~/OakReader-Dev/library.sqlite "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%';"
   # row counts per table; and check whether a 'dead' table actually has rows
   ```

4. **Report**: live tables, dead tables (with row counts), churn steps, and any redundant/denormalized columns. Recommend keep-vs-drop. Some "redundancy" is deliberate (e.g. `annotations.item_id` is denormalized from `attachment→item` for an index — keep it; `items↔attachments` is an intentional Zotero 1:N — keep it). Don't propose collapsing those.

## Part 2 — Decide: collapse or append

- **Unreleased / pre-release** → you MAY rewrite the migrator into a clean baseline: delete the churn steps and the dead tables, renumber to a tidy `v1..vN`. No shipped DB has the intermediate schema, so there's nothing to preserve on anyone else's disk. **But the developer's own dev DB still has the old `grdb_migrations` history** — collapsing changes identifiers, so reusing that DB will make GRDB try to re-run a renamed `CREATE TABLE` and crash. Hence Part 3.
- **Already shipped** → NEVER edit a past migration. Only append a new `vN-…` that `ALTER`/`DROP`s. Don't use this skill's collapse path.

Keep live-table DDL byte-identical when collapsing — that's what makes the reimport a trivial `SELECT *`.

## Part 3 — Data-preserving migration (the fiddly part)

After editing `CatalogMigrations.swift`, **rebuild the app** (`macos-rebuild-dev` skill / `xcodebuild -scheme OakReader -configuration Debug -allowProvisioningUpdates build`) so the new code compiles, then:

1. **Backup + clear** (quit app first):
   ```bash
   cd ~/OakReader-Dev
   cp library.sqlite "library.sqlite.import-source-$(date +%Y%m%d-%H%M%S)"
   mv library.sqlite "library.sqlite.preclean-$(date +%Y%m%d-%H%M%S)"
   rm -f library.sqlite-wal library.sqlite-shm
   ```
2. **Launch** the freshly-built app → `CatalogDatabase.init` creates the clean schema (`migrate`) + seeds system rows (`ensureSystemData`). Verify it has only the new migrations + live tables, then **quit**.
3. **Reimport** the old data. Both schemas share identical live-table DDL, so the data is already final-shaped — `INSERT OR IGNORE` in FK-parent order. Key rules:
   - Wrap in one transaction with `PRAGMA defer_foreign_keys = ON` (handles self-refs / insert order).
   - **Skip `is_system = 1` collections/properties** — the fresh launch already re-seeded the correct ones; importing the old ones would resurrect dead system collections (e.g. an old "Videos"/"Quiz Cards") with stale rules.
   - **Filter children to existing parents** (`WHERE item_id IN (SELECT id FROM items)` etc.) so rows pointing at dropped collections/items don't FK-fail.
   - If you dropped a column, use **explicit column lists** for that table (not `SELECT *`) so the counts match.
   - Order: items → attachments → collections(user) → collection_items → properties → property_options → item_property_values → conversations → citations → annotations → word_lookups.
   ```bash
   sqlite3 library.sqlite <<SQL
   ATTACH DATABASE '$HOME/OakReader-Dev/library.sqlite.import-source-XXXX' AS old;
   BEGIN; PRAGMA defer_foreign_keys = ON;
   INSERT OR IGNORE INTO items SELECT * FROM old.items;
   INSERT OR IGNORE INTO attachments SELECT * FROM old.attachments;
   INSERT OR IGNORE INTO collections SELECT * FROM old.collections WHERE is_system = 0;
   INSERT OR IGNORE INTO collection_items SELECT * FROM old.collection_items
     WHERE collection_id IN (SELECT id FROM collections) AND item_id IN (SELECT id FROM items);
   -- …properties / options / values / conversations / citations …
   -- dropped a column? list columns explicitly:
   -- INSERT OR IGNORE INTO annotations (col1,col2,…) SELECT col1,col2,… FROM old.annotations WHERE …;
   COMMIT; DETACH DATABASE old;
   SQL
   ```
4. **Verify** before relaunch:
   ```bash
   sqlite3 library.sqlite "PRAGMA foreign_key_check;"   # must be empty
   # row counts per live table must equal the import-source's counts
   ```
   Then relaunch the app and confirm migrations count + data are intact, and `search.sqlite` still works (it's keyed by item_id, which is unchanged).

## Notes
- Keep the `import-source-*` backup until the user confirms the app looks right; never delete backups unprompted.
- Don't touch `search.sqlite` — it self-rebuilds.
- Cross-refs: memory `schema-baseline-cleanup` (the 16→7 collapse that established this procedure) and `zotero-dirty-data-and-schema-mismatch` (grdb_migrations realignment gotcha). Use `dead-code-scan` (periphery) for code-level dead declarations after dropping a table's record type.
