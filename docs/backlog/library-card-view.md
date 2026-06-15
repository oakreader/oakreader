# Library Card / Waterfall View — Finder-style view switcher

**Status:** Card grid already shipped (`LibraryCardGridView`). 2026-06-15 corrections **implemented & build-green**: (1) PDF covers now real first-page renders, (2) neutral grey/material placeholder (no per-item color), (3) 16pt gaps. Remaining (designed, not built): the unified web-preview `preview.json` + OG-first chain + text-fallback card for `.html`/`.link`.
**Created:** 2026-06-15
**Reference app:** GatherOS (`gatheros.co`, internal name *moodmark*) — see skill `gatheros-source-analysis`
**Related code:** `OakReader/Views/Library/LibraryCardGridView.swift` (grid + neutral placeholder), `LibraryCoverSweeper.swift` (backfill + `.render` marker), `OakReader/Services/LibraryCoverService.swift` (`generateCover` first-page / `generateHTMLCover` / `generateLinkCover`), `ImportService+PDF.swift`, `ImportService+HTML.swift`, `ImportService+Embed.swift`, `OakReader/Utilities/HTMLMetaParse.swift`; `browser-extension/src/lib/translators/link.ts` (`extractLinkMetadata`)

## Implemented 2026-06-15 (the "empty state" fix)

The card grid (`LibraryCardGridView`), the background `LibraryCoverSweeper`, and the
synthetic fallback already existed — the "wall of pastel rectangles" was a *cover-pipeline*
problem, not a layout one. Changes made:

- **PDFs render the real first page.** `ImportService+PDF` and the sweeper now call
  `generateCover` (PDFKit first-page) instead of `generatePaperCover` (synthetic typographic
  card). `generatePaperCover` is kept only as a fallback when a page can't be rendered
  (encrypted/corrupt).
- **One-time backfill via a positive `.render` marker.** Old synthetic covers came from the
  *import* path and had **no** marker (verified on disk: 0 `.paper` markers, 602 PDFs), so the
  prior `.paper`-marker scheme upgraded none of them. `needsCover(pdf)` is now `!hasCover ||
  !hasRenderMarker`; a real render writes `cover.webp.render` (and clears any legacy `.paper`),
  so every legacy synthetic cover upgrades exactly once, lazily per collection viewed.
- **Neutral placeholder.** `LibraryCardView.placeholderCover` is now `.regularMaterial` + a
  faint grey wash + monochrome glyph/label — no per-item hue (the `stableHue` palette was
  removed). Real thumbnails are the only color in the grid. (True Liquid Glass `glassEffect` is
  macOS 26; we deploy to 15.4, so Material is the approximation.)
- **Spacing.** Column/card gutters 10 → 16pt, outer padding 12 → 16pt.

Card anatomy (thumbnail-on-top + title/source label below) was already present, so no change.

## Goal

Give the Library / Collections middle pane a **Finder-style view switcher** with two modes:

1. **List view** — the current `LibraryTableView` (already done; it *is* the Finder list view).
2. **Card / waterfall (瀑布流) view** — a masonry grid of rich per-type thumbnails:
   PDF → first-page render, web/HTML → OG image or page snapshot, YouTube → poster,
   X/tweet → OG/first-media image, with an icon+title fallback for note/audio.

A segmented `list | grid` toggle plus a **column-count slider** lives in the toolbar
(mirrors GatherOS's `▦ ──●── ▢` control — the slider sets column count, *not* zoom).

## How the reference (GatherOS) does it

Read from its renderer (`dist/renderer/assets/main-*.js`). Three findings drive this design:

1. **Two layouts behind one toggle**, persisted (`localStorage["moodmark.gridLayout"]`).
   The list layout is a row of `thumb + title + source + dimensions + date`. The slider
   sets `columns` (an integer), so fewer columns ⇒ bigger cards.

2. **The masonry is "dumb columns," not a packing solver.** Items are round-robined into
   N independent vertical stacks (`columns[i % N].push(item)`), rendered as
   `grid-template-columns: repeat(N, minmax(0,1fr))`. Each card declares its **intrinsic
   aspect ratio** (`style={{aspectRatio: naturalW/naturalH}}`) and the browser stacks them.
   No per-card height measurement, no `ResizeObserver` on cards → no layout thrash. The
   waterfall look is simply *N columns of aspect-ratio-correct cards*. (A shortest-column
   `q[0]<=q[1]` packer exists but is used only on the board canvas, not the grid.)

3. **Cards render polymorphically, but the previews are STATIC images, not live embeds:**
   ```js
   t.kind==="video" ? <video poster=…>          // poster image, not a live player
   : t.isTweet      ? <TweetCard variant="grid"> // a pre-rendered card
   :                  <img aspectRatio=W/H>      // one stored preview image
   ```
   GatherOS never mounts a live X iframe or live web page in a grid cell — it stores **one
   preview image per save plus its width/height**, and aspect ratio drives the masonry.
   This is the single most important decision (see "Key decision" below).

## Key decision: static thumbnails, not live embeds

The original ask mentioned "show x iframe" in the card. **Recommendation: don't.** Match
GatherOS — render a **static per-type thumbnail** in the grid and only go live when the item
is opened.

- A wall of live `WKWebView`s (one per tweet/web card) spawns dozens of web content processes
  and is the classic reason "embed-everything" grids stutter.
- It also fights OakReader's existing model, where one cover image already represents an item.
- Consistent with the memory note *"for reference-modeled features, match the reference."*

So the grid stays **dumb and type-agnostic at render time**: every card just shows
`coverImageData` + a small type badge, with an icon+title fallback. All the per-type
intelligence moves into **cover generation** (below), done once at import, not per scroll.

## OakReader fit (what already exists)

- `LibraryItem` (`LibraryModels.swift`) already has `coverImageData: Data?`, `contentType`
  (`.pdf/.html/.markdown/.audio/.link`), and `primaryAttachment?.sourceURL`.
- `LibraryCoverService` already generates **PDF first-page** covers and **HTML WKWebView
  snapshots**, stored at `storage/{itemKey}/attachments/{attKey}/cover.webp`.
- `LibraryTableView` is the list mode; `LibraryStore` holds filter/sort state and the
  multi-selection set.

Three gaps: (a) no view-mode state/toggle, (b) no masonry view, (c) covers are missing for
YouTube / external links / tweets / markdown / audio, and we don't store cover dimensions.

## Plan

### Phase 1 — View-mode state + toolbar control
- `enum LibraryViewMode: String { case list, card }` + a `cardColumns: Int` (clamp 2…6),
  both persisted in `Preferences` and surfaced on `LibraryStore` as `@Observable`.
- `LibraryTableToolbar`: add the segmented `list | grid` control and the column slider
  (slider only visible/enabled in `.card`). Reuse `OakToolButton` styling.
- `LibraryRootView` switches the middle pane on `viewMode`: `.list` → existing
  `LibraryTableView`; `.card` → new `LibraryCardGridView`.

### Phase 2 — The masonry grid
SwiftUI has no native masonry; we're on macOS 15, so use the **`Layout` protocol**.

- `MasonryLayout: Layout` — greedy shortest-column placement (real Pinterest packing): for
  each subview compute its height from its declared aspect ratio at the current column width,
  place it into the currently-shortest column. Needs each card's aspect ratio up front
  (we store it — see Phase 3) so there is **no measure-then-reflow jank**.
  - *Fallback option if Layout proves fiddly:* GatherOS's dumb round-robin (`HStack` of N
    `LazyVStack`s, `items[i] → column[i % N]`). Cheaper, slightly worse balance. Start with
    `Layout`; keep this in pocket.
- `LibraryCardView` has **two render paths**, chosen by whether a raster cover exists:
  - *Has raster* (`coverImageData`): aspect-fit image + a small overlay badge (PDF page count,
    ▶ for video, domain favicon for web/tweet).
  - *No raster*: the **generated text card** (see "Web preview" below) — title + description +
    favicon/domain + theme color. Rendered natively, **not** baked to an image. Markdown/audio
    reuse the same text-card shape with their icon.
- Wrap in `ScrollView` + `LazyVStack`-backed layout for virtualization; bind selection to the
  existing `LibraryStore` selection set; reuse the existing context menu and drag providers.

## Web preview: OG image + the no-image fallback card

This is the load-bearing detail for whether web cards look great or cheap. **Current state is
inconsistent** and must be unified:
- Live links (`generateLinkCover`, `LibraryCoverService.swift`) already scrape `og:image` /
  `twitter:image` via `HTMLMeta.content` and download it. ✅
- HTML **snapshots** (`generateHTMLCover`) only take a blind WKWebView screenshot — they ignore
  `og:image` entirely. ✗
- Nobody persists `og:description` / `og:site_name` / `theme-color` / favicon in a form a card
  can render. (HTML import drops some into CSL; links write a `metadata.json` with
  `description`/`thumbnailURL` only.)

**Where to extract — the extension, at capture time.** The live DOM has resolved `og:image`,
favicon and `theme-color` with the user's cookies/auth; SingleFile may rewrite/strip meta, and
a server-side re-fetch can hit paywalls/bot-blocks. The extension *already* does this for
**link** saves (`extractLinkMetadata`, `link.ts`); extend the **HTML-archive** path to send the
same `{description, thumbnailURL, faviconURL, themeColor, siteName}` in the clip payload.
Server-side `HTMLMeta` parsing of the saved HTML stays as the fallback for non-extension imports
(drag-drop, etc.).

**Persist one card model — `preview.json` per web attachment** (written for snapshots *and*
links so they render identically):
```
{ title, description, siteName, faviconURL, themeColor, ogImageURL, coverWidth, coverHeight }
```
The card view reads this single struct. `coverWidth/coverHeight` are the chosen image's **true**
dimensions (keep the real aspect ratio — OG images are ~1.91:1; do NOT squash to 320×240 like
today) so masonry places without measuring.

**Image priority chain** (one resolver, snapshot or link alike):
1. `og:image` → `twitter:image` → `link rel=image_src` → JSON-LD `image`. **Validate**: skip
   < ~200 px and 1×1 trackers (this is why naive OG cards look junky). Download → re-encode →
   `cover.webp` + record W/H.
2. *Snapshots only*: WKWebView rendered page (today's `generateHTMLCover`) — the "real page" look.
3. No usable raster → the **generated text card** (rendered natively):
   - **Title** (2–3 lines), **description** excerpt (2–3 lines), **favicon + domain** chip.
   - **Deterministic theme color**: `<meta name="theme-color">` → dominant color of favicon →
     `hash(domain)→hue`. Used as a soft gradient/accent. Deterministic per-domain ⇒ all cards
     from one site share a hue (looks intentional, à la Arc/Linear/Notion link cards).
   - Fixed pleasant aspect ratio (e.g. 4:3 or 16:10) so masonry placement is stable.

Native render (not a baked image) for the text card: stays crisp at any column width, follows
dark mode, reflows, and the title/description stay selectable/searchable.

### Phase 3 — Per-type cover/preview generation (extend `LibraryCoverService`)
Populate either a raster `cover.webp` (+ W/H) **or** a `preview.json` text-card model for
**every** kind, so the grid stays dumb.

| Kind | Preview source | Status |
|---|---|---|
| PDF | first-page render | ✅ exists |
| HTML snapshot | OG image from saved HTML (extension-supplied or `HTMLMeta`); else WKWebView snapshot; else text card | screenshot exists; **add OG-first + text-card fallback** |
| Website link (`.link`) | OG image (extension or one fetch); else text card | OG fetch exists; **add `preview.json` + text-card fallback** |
| YouTube (`.link`, host youtube/youtu.be) | derive `https://img.youtube.com/vi/{id}/maxresdefault.jpg` from `sourceURL` — no API, no embed | new (trivial) |
| X / tweet | tweet `og:image` / first media image (static) — same path as website | new |
| Markdown / audio | no raster → text card with their icon | n/a |

Generation stays async/off the main thread, triggered at import (and lazily backfilled for
existing items), exactly like the current sidebar-panel cover task.

## Out of scope (explicitly)
- Live web/tweet embeds in the grid (see "Key decision").
- The board / freeform-canvas surface GatherOS also has — separate feature if ever wanted.
- Per-card hover video preview, color-palette filtering (GatherOS has both; not now).

## Open questions
- Badge density: how much chrome on a card (page count, domain, type icon) before it gets
  noisy? Start minimal (type badge only), add on feedback.
- Backfill: regenerate covers for the whole existing library on first launch after ship, or
  lazily as items scroll into view? Lean lazy + a one-time background sweep.
