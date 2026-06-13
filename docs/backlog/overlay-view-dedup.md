# Overlay View Dedup

**Status:** Backlog (low priority — do only when a trigger below fires)
**Created:** 2026-06-13

## Goal

Collapse the ~110 lines of near-identical logic shared by the three drag-to-select
snapshot overlays into a small reusable layer.

- `OakReader/Views/Viewer/SnapshotOverlayView.swift` (PDF area capture)
- `OakReader/Views/Viewer/HTMLOverlayView.swift` (HTML snapshot capture)
- `OakReader/Views/Viewer/MediaSnapshotOverlayView.swift` (media webview capture)

## Why this is NOT urgent

There is no bug, no perf issue, and nothing is blocked. The duplication just sits there.
It only becomes a real cost under one of these triggers — **don't do this work until one
of them actually happens:**

1. **A 4th overlay type is added** (e.g. a video-frame capture overlay) — then the shared
   base earns its keep immediately.
2. **A behavior change has to be made in all three at once** (e.g. changing the selection
   rectangle styling, the min-drag threshold, or the capture coordinate math) — copying
   the same edit three times and keeping them in sync is the pain that justifies the
   refactor.

If neither has happened, leave it alone. This is the opposite of the dead-code removal we
just did: that deleted unused code (pure win); this reorganizes working code (risk with no
functional gain unless a trigger makes it pay off).

## What's duplicated (from the 2026-06 periphery audit)

1. **Generic NSView tree search** — each file has its own recursive finder that differs
   only by type: `findPDFView` / `findWebView` / `findWKWebView`. Candidate:
   `extension NSView { func findFirst<T>(ofType:) -> T? }`.
2. **SwiftUI → AppKit → WebView coordinate flipping** — `HTMLOverlayView` and
   `MediaSnapshotOverlayView` carry an identical ~20-line transform. Candidate: a small
   `ViewportCoordinateConverter` helper.
3. **Drag-selection state machine** — all three repeat `isDragging` / `showSelection` /
   `dragStart` / `dragEnd` + a `normalizedRect(from:to:)`. Candidate: a shared
   `DragSelection` state struct or a parametrized `SelectionOverlayView<HitTestView>`.

## Approach (when triggered)

- Extract the three pieces above into shared helpers first (mechanical, compiler-verified).
- Only then consider a generic `SelectionOverlayView<HitTestView>` base if a 4th overlay
  makes the parametrization worth the indirection.
- **Must be verified by running the app** — overlay positioning and capture rects are
  visual/coordinate-sensitive and can't be confirmed by a green build alone. Open each of
  the three capture flows (PDF area, HTML snapshot, media snapshot) and confirm the
  selection rectangle and resulting crop are correct.

## Related

- This was "part 2" of a deferred refactor task. **Part 1 (splitting the large
  `ChatBubbleView` / `ChatViewModel` files) was evaluated and dropped** — file length
  alone isn't a problem, and those are streaming-chat hot paths with known timing
  subtleties; splitting them is pure risk with no functional gain. Don't resurrect it
  without a concrete pain point (repeated bugs / merge conflicts in those files).
- Prior cleanup context: the 2026-06 dead-code sweep (see project memory
  `dead-code-cleanup-2026-06`).
