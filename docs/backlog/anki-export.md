# Anki Export (replace self-built SRS)

**Status:** Implemented (v1, 2026-06-13) — pending a live Anki round-trip test
**Created:** 2026-06-13

## Deviations from plan (as built)
- **No separate `anki_enabled` pref.** The existing `.quizCards` app-extension toggle already gates the feature, so the master enable is that toggle — one switch, not two. Anki settings (URL, deck, tagging) live in the extension's settings pane.
- **Image occlusion → Basic note (image + labels), not Anki's Image Occlusion type.** True IO creation via `addNotes` is fragile/version-specific; v1 ships the robust Basic fallback and defers real IO.
- The right-panel and library quiz surfaces were **repurposed** (list + "Export to Anki"), and the review overlay / review-as-tab machinery deleted.

## TL;DR

OakReader stops being a spaced-repetition *app* and becomes a spaced-repetition *card factory*. We delete the home-grown FSRS scheduler and review UI, and instead push AI-generated cards straight into Anki via AnkiConnect. OakReader keeps the part it's uniquely good at — generating high-quality cloze / flashcard / image-occlusion cards from real document and chat context — and hands scheduling, review, and cross-device sync to Anki, which already does all of it better than we ever will.

## Why This Matters

Spaced repetition only works if you review **every day, everywhere**. A card trapped in a macOS document reader you only open at your desk is a dead card. That's not a hypothesis — it's already what happened here: the self-built review system is effectively abandoned. An audit of the codebase found:

- The entire annotation→card pending/approve flow (`approveCard`, `approveBatch`, `deletePendingCards`, `fetchPendingCards`) has **zero call sites** — dead code.
- `createCard` has exactly **one** live caller (the "save from chat deck" button).
- Of the 42 cards in the live DB, all 28 cards created since the annotation flow died have `reps = 0` — **never reviewed once**.

Two conclusions:

1. The review/scheduling half is commodity we can't win and users don't use in-app → delete it, export to Anki.
2. The "make a card from an annotation" feature is **already gone** (no live path creates one). The only way a card exists today is *AI generates a deck in chat → user clicks save*. So there is exactly **one kind of card: a chat-generated card.** The new design drops the annotation concept entirely instead of carrying its dead schema forward.

| | Self-built SRS | Anki export |
|--|---------------|-------------|
| Daily review | Desktop only, never opened | AnkiMobile / AnkiDroid / AnkiWeb, everywhere |
| Scheduler | We maintain FSRS + leech + review log | Anki owns it (newer FSRS than ours) |
| Sync | None | AnkiWeb, free |
| Our maintenance surface | Scheduler, review UI, due counts, FSRS dep | One HTTP client |
| Our differentiation | Buried under commodity | Front and center: card *generation* |

## Scope

### In scope (minimal v1)
- An `AnkiExportService` that pushes cards to a running Anki via **AnkiConnect** (`localhost:8765`).
- A thin hand-written `AnkiConnectClient` (URLSession + JSON). **No third-party SDK** — AnkiConnect is plain HTTP+JSON; an SDK would be pure dependency cost.
- Note mapping: `cloze → Cloze`, `flashcard → Basic`, `occlusion → Image Occlusion` (with media upload via `storeMediaFile`).
- A single target **deck**, default `OakReader`, set in Settings. Everything exports there; reorganize in Anki afterward.
- Rich **tags** carrying source document + collection membership (this is where organization lives — see below).
- Schema slim-down: `quiz_cards` collapses to a lightweight "generated cards" staging/history table with an `exported_at` marker.
- Delete the self-built scheduler, review UI, and the `swift-fsrs` dependency.

### Out of scope (defer)
- `.apkg` / `.txt` file export for users without AnkiConnect. (When Anki isn't reachable, v1 simply prompts the user to install/enable the AnkiConnect add-on.) `.apkg` generation has no good Swift library and the Anki package schema is fragile — not worth it for v1.
- Auto-mirroring OakReader collections as Anki decks. Anki deck taxonomy is orthogonal to reading collections and Anki has first-class reorg tools; if users ask, add a "mirror collections as decks" toggle later. For v1, collections live as **tags**, not decks.
- Two-way sync / reading review results back from Anki. Export is fire-and-forget.
- Duplicate detection beyond what AnkiConnect's `addNotes` already does.

### Never
- **Writing Anki's `collection.anki2` SQLite directly.** It's locked while Anki runs, version-fragile, and corrupting a user's collection is unacceptable. AnkiConnect *is* the supported "save directly into Anki" path.

## Deck & Tags — organization model

The earlier "each collection is a deck" idea is dropped. Reason: **Anki deck structure is orthogonal to OakReader collections** (users organize Anki by exam/subject/one-big-deck, not by reading library), Anki is *built* for reorganizing cards across decks (drag, Change Deck, filtered decks), and auto-mapping just spawns a sprawl of `OakReader::*` decks to clean up. Crucially, **collections are many-to-many (an item can be in several) while a deck is one-to-one** — so collection membership belongs in tags, which are multi-valued, not decks.

### Deck — one simple landing spot
- A single **default deck** set in Settings (`anki_deck`, default `OakReader`). Every export goes there — no per-export picker. Changing where cards go = change the setting, or just move them in Anki.
- `createDeck` is idempotent; create the deck on demand before adding notes.
- The user reorganizes freely in Anki after the fact — that's the whole point: we don't organize, Anki does.

### Tags — where the metadata lives (auto-attached, one toggle)
Gated by a single setting **Tag exported cards** (`anki_tagging`, default on). Every note gets:
- `oakreader` — all our cards, for one-click filtering / bulk ops in Anki.
- `oakreader::<source doc title>` — when the originating chat was about a document (from the card's nullable `item_id`). Lets the user filter "cards from this paper" in Anki.
- `oakreader::<collection name>` — one tag per collection the source document belongs to (the many-to-many that decks can't express).

Library-level chats (no document) just get the `oakreader` tag.

## Card → Anki Note Mapping

| OakReader `QuizContent` | Anki note type | Fields |
|--|--|--|
| `cloze(text, hint)` | `Cloze` | `Text` = cloze text (our `{{c1::…}}` syntax is already Anki-native), `Back Extra` = hint |
| `flashcard(front, back)` | `Basic` | `Front`, `Back` (Markdown → HTML) |
| `occlusion(imageURL, masks, labels)` | `Image Occlusion` | upload image via `storeMediaFile`, build occlusion fields |

## New Schema (migration v13)

One kind of card → one slim table. `quiz_cards` (logically "generated_cards" — keep the name to avoid churn, or rename):

```
id              PK
conversation_id TEXT NULL → conversations(id) ON DELETE SET NULL  -- which chat produced it (breadcrumb)
item_id         TEXT NULL → items(id)         ON DELETE SET NULL  -- document the chat was about; NULL for library chats. Provenance only — feeds the source/collection tags
type            TEXT NOT NULL
content_json    TEXT NOT NULL
source_text     TEXT NULL        -- the concept text, if captured
exported_at     TEXT NULL        -- ISO8601 when last pushed to Anki; NULL = not yet exported
created_at      TEXT NOT NULL
updated_at      TEXT NOT NULL
```

**Dropped columns:** `state`, `due_at`, `stability`, `difficulty`, `elapsed_days`, `scheduled_days`, `reps`, `lapses`, `last_review_at`, `is_suspended`, `is_pending` (FSRS/review), `group_id`, `collection_id` (dead/derived), `origin_kind`, `annotation_id`, `page_context` (annotation concept — feature already removed). **Dropped table:** `quiz_review_log`.

**Backfill:** straight column copy of the survivors. The 14 legacy "annotation" rows keep their content (`type`, `content_json`, `source_text`, `item_id`) and simply lose the dead `annotation_id` link — non-destructive. No `item_id` nulling needed; `item_id` is now pure provenance, harmless to keep on every row.

**Migration mechanics:** SQLite can't drop FK columns cleanly across versions, so rebuild the table — `CREATE TABLE quiz_cards_new (…)`, `INSERT … SELECT` the surviving columns, `DROP TABLE quiz_cards`, `ALTER TABLE quiz_cards_new RENAME TO quiz_cards`. Recreate indexes (`item_id`, `conversation_id`, `exported_at`). Then `DROP TABLE quiz_review_log`.

No `collections` change needed (no per-collection deck override in v1).

---

# Implementation Plan

### Phase 0 — Schema & data (one migration)
1. `CatalogMigrations.swift`: add `v13-anki-export` — rebuild `quiz_cards` to the slim chat-only schema with backfill; `DROP TABLE quiz_review_log`.
2. `DatabaseRecords.swift`: slim `QuizCardRecord` to the new columns; delete `QuizReviewLogRecord`. Add `exportedAt`.
3. `QuizModels.swift`: slim `QuizCard` (drop all FSRS fields, `isSuspended`, `isPending`, `groupId`, `collectionId`, `annotationId`, `pageContext`, `state`/`dueAt`/etc.); add `exportedAt`. Keep `QuizContent`, `QuizDeck`, `QuizType`.

### Phase 1 — Delete self-built SRS
4. Delete `QuizScheduler.swift`.
5. Delete review UI: `Views/RightPanel/QuizCards/QuizCardReviewView*.swift`, `QuizCardListView.swift`, `QuizCardsPanelView.swift`, `Views/Settings/QuizCardSettingsView.swift`, `Views/Library/CollectionQuizCardsView.swift`.
6. `QuizCardService.swift`: strip `recordReview`, `fetchDueCards`, `dueCount`, leech, suspend, the entire pending-flow, and the collection/annotation fetches. Keep `createCard` (slimmed — `conversationId` + `itemId` + content only), `fetchCards`, `deleteCard`, `copyOcclusionImage`. Add `markExported(ids:)`.
7. `QuizCardsViewModel.swift`: strip review-session state/methods; keep `loadCards`, `saveCard`, `deleteCard`. Add `exportToAnki()`.
8. Remove `swift-fsrs` from `Package.swift` + `project.yml`; remove FSRS imports.
9. Settings: drop the Quiz Card settings tab (`SettingsView.swift`, `Preferences.swift` keys `quizCard_*`). Add an "Anki" section — **master "Enable Anki export" toggle** (gates all export UI), AnkiConnect URL + **connection test**, **default deck** field, **Tag exported cards** toggle. New `Preferences` keys: `anki_enabled` (default false), `anki_url`, `anki_deck` (default `OakReader`), `anki_tagging` (default true).
10. Remove the "Quiz Cards" system collection plumbing that backed the review panel (keep generation/inline-deck rendering in chat).

### Phase 2 — AnkiConnect client
11. New `Services/AnkiConnect/AnkiConnectClient.swift`: `URLSession` POST to the configured URL; actions `version`, `deckNames`, `createDeck`, `addNotes`, `storeMediaFile`, `canAddNotes`. Typed request/response; `version` ping for reachability.
12. New `Services/AnkiConnect/AnkiNoteMapper.swift`: `QuizCard` → `AnkiNote` (note type, fields, tags, deck). Markdown→HTML for Basic; cloze passthrough; occlusion field builder + media filenames. Builds the tag set (`oakreader` + source-doc + collection tags) from the card's `item_id`.
13. New `Services/AnkiExportService.swift`: orchestrates — ensure the chosen deck exists, upload occlusion media, `addNotes`, then `markExported`. Returns a per-card result (added / duplicate / failed).

### Phase 3 — UI surface
14. Keep the inline chat deck (`InlineDeckView`) and its "save" action — saving now means "stage into generated_cards", unchanged.
15. Replace the document/library "review" entry points with an **"Export to Anki"** action (toolbar/menu on the card list), **shown only when `anki_enabled` is on**. One click pushes staged cards to the configured default deck (no picker). On no-connection: a sheet explaining how to install/enable AnkiConnect.
16. Show export status (e.g. badge "N cards · M exported") sourced from `exported_at`.

### Phase 4 — Verify
17. Build green (XcodeGen regen after `project.yml` change).
18. Manual: with Anki + AnkiConnect running, generate a deck in chat → save → Export → confirm cards land in the default deck with correct note types, the occlusion image present, and `oakreader` + source/collection tags applied. With Anki closed → confirm the friendly install prompt.

## Open Questions
- Rename `quiz_cards` → `generated_cards`? (Cosmetic; deferring keeps the migration smaller.)
- Re-export behavior for already-exported cards: skip, or allow re-push (Anki dedupes on first field)? Default: skip rows with `exported_at`, with a "force re-export" override.
