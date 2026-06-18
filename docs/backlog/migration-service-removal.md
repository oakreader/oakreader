# Remove the SwiftData → GRDB MigrationService

**Status:** Backlog — needs a product decision before doing (see "Why this needs your call")
**Created:** 2026-06-17

## Goal

Delete the one-time, upgrade-only back-compat code that migrates a user's library from
the **old SwiftData storage** into the current GRDB + filesystem model. In a greenfield
build (no users coming from a pre-GRDB version) this code is dead weight.

- `OakReader/Services/MigrationService.swift` (~110 lines) — opens the old SwiftData
  sqlite directly, copies items/files into the new model, sets
  `oakreader.migration.v1.done`.
- `OakReader/App/AppDelegate.swift:48-50` — the `migrateIfNeeded()` call on launch.
- The `OldLibraryItem` shim it decodes (lives inside / alongside `MigrationService`).

## Why this surfaced

It came out of the 2026-06-17 memory refactor + "this is a greenfield project, remove
back-compat" cleanup. In that pass we removed the clearly-dead back-compat:

- memory subsystem legacy import (`importLegacy`, `USER.md`, per-doc brief) — done;
- the `AgentPermissionLevel` migration cluster (`legacyRawValue` init,
  `migrateAgentPermissionLevel`, `agentRequireConfirmation`) — done.

`MigrationService` is the last back-compat item, but it was **held back** because it's
bigger and not as obviously safe to delete. Hence this note instead of just deleting it.

## Why this needs your call (don't just delete it)

The other items were safe because nothing real depended on them. This one is different:

- **OakReader has real open-source users.** If anyone is still on a build that used the
  old **SwiftData** storage and hasn't launched a GRDB build yet, deleting this is the
  difference between "library migrates automatically" and "library silently looks empty
  on first launch of the new version." That's a data-loss-shaped regret, not a cleanup.
- The "greenfield" assumption is true for **local dev data** (and we just wiped that),
  but is *not* automatically true for the shipped app. So the decision hinges on one
  question only.

## The decision (the single trigger)

**Delete it once you're confident no shipped/in-the-wild build still needs the
SwiftData→GRDB hop** — i.e. every real user has already launched at least one GRDB
version (the migration has run and `oakreader.migration.v1.done` is set), OR you accept
that the SwiftData era predates any real user.

- If **yes / don't care** → remove the three things listed under Goal, rebuild, done.
- If **unsure** → leave it. It's ~110 lines that run once, guarded by a UserDefaults
  flag, and cost nothing at steady state. Cheap insurance against a returning user.

## Notes

- `Log.migration` (the logger) is shared with `ZoteroMigrationService` — **keep it.**
- `ZoteroMigrationService` and the GRDB schema migrators (`CatalogMigrations.swift`,
  `FTSDatabase.swift`) are **not** back-compat — Zotero import is a feature, and the
  schema migrators are how the DB is *defined/created even on a fresh install*. Do not
  touch those.

## Related

- 2026-06-17 memory refactor → ChatGPT-style single-profile memory (dropped background
  reflection + per-doc brief). Same cleanup pass that produced this note.
- Prior cleanup context: project memory `dead-code-cleanup-2026-06`.
