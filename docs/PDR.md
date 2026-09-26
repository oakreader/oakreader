# PDR: Remove Inbox, Make "All Items" the Default View

**Date:** 2026-05-03
**Status:** Implemented

## Context

The library had an "Inbox" concept: items imported from the browser extension were flagged `isInbox = true` and appeared in a dedicated Inbox smart collection. Users had to manually "archive" items by adding them to a collection (which cleared the flag). This added friction without clear value — "All Items" already shows everything and serves as a better default index.

## Decision

Remove the Inbox concept entirely and make "All Items" the default (and first) sidebar entry.

## Changes

- **Schema:** Removed `is_inbox` column from the `items` table and the Inbox entry from system smart collections. Shifted sort orders so All Items is first (0).
- **Data models:** Removed `isInbox` from `ItemRecord`, `LibraryItem`, `SystemCollectionID`, and `FilterField`.
- **Services:** Removed inbox-related logic from `LibraryStore` (inbox count, filter evaluation, archive-on-organize SQL), `ImportService` (inbox flag on import), and `MigrationService`.
- **Views:** Removed the Inbox badge from the sidebar, the Inbox empty state from the table view, the "Inbox" field option from the smart collection editor, and the Inbox toggle from Library settings.
- **Browser extension:** Replaced "Inbox" with "All Items" as the default save target in the popup UI (`CollectionPicker` and `App` components).

## Consequences

- Imported items (PDF, web snapshot, embed) appear directly in "All Items" without requiring manual organization.
- Users can still organize items into collections; items without a collection simply live in "All Items".
- The `collectionId` field on the snapshot payload remains optional — `nil` means unsorted (appears in All Items only).
- Existing `UserDefaults` for `hiddenSystemCollectionIds` may contain the old Inbox UUID; this is harmless and requires no cleanup.
- This is a greenfield schema change — existing databases must be recreated (no migration path from the previous schema).
