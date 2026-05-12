# Bug: White background visible outside rounded corners in Library view

## Summary

In the Library view, the rounded top-left corner (table pane) and top-right corner (detail panel) show white background in the gap between the rounded border and the rectangular parent container. This area should match the gray tab bar background (`windowBackgroundColor`) instead of white.

## Location

- **File:** `OakReader/Views/Library/LibraryRootView.swift`
- **Affected views:** Table pane (top-left corner), Detail content panel (top-right corner)

## Root cause

The table and detail panel use `.clipShape(UnevenRoundedRectangle(...))` to create rounded corners, with `TopLeftBorderFill` / `TopRightBorderFill` overlays drawing the 1px border. The clip makes the corner areas transparent, expecting the parent background to show through as gray.

However, both panes sit inside an `HSplitView`, which is backed by AppKit's `NSSplitView`. The `NSSplitView` draws its own opaque white background that cannot be overridden by SwiftUI's `.background()` modifier. This white background fills the corner gaps instead of the expected gray.

## Visual

```
┌─────────────────────────────────────────────┐
│  Tab Bar (gray)                             │
├──────┬──WHITE──┬─────────────┬──WHITE──┬────┤
│      │ ╭──────╮│             │╭──────╮ │    │
│ Side │ │Table ││  HSplitView ││Detail│ │Nav │
│ bar  │ │      ││   divider   ││Panel │ │    │
│      │ │      ││             ││      │ │    │
└──────┴─┴──────┴┴─────────────┴┴──────┴─┴────┘
         ^WHITE                  WHITE^
         corner                  corner
```

The "WHITE" areas at the top corners should be gray (`windowBackgroundColor`).

## Attempted fixes (did not work)

1. **`.background()` after `.clipShape()`** on each pane — `NSSplitView` paints its own background on top, covering the SwiftUI background.

2. **`ZStack` wrapper** with gray `Color` inside each `HSplitView` pane — same issue, `NSSplitView` controls pane rendering.

3. **Corner fill overlay shapes** drawn on top of clipped content — the overlay shapes either rendered incorrectly or were also affected by the split view's clipping behavior.

4. **`NSViewRepresentable` to set `NSSplitView.layer.backgroundColor`** — setting the layer background does not override `NSSplitView`'s own drawing, which happens via `drawRect:` rather than layer-backed rendering.

5. **Replacing `HSplitView` with plain `HStack`** — fixes the background issue but removes the drag-to-resize functionality between table and detail panel.

## Possible solutions to explore

- **NSSplitView subclass or delegate** — use `NSSplitViewDelegate` or a custom subclass to control background drawing. May require wrapping in `NSViewRepresentable` instead of using SwiftUI's `HSplitView`.

- **Introspect the NSHostingView** inside each `NSSplitView` pane and set its layer background to clear/gray.

- **Custom split view** — replace `HSplitView` with a custom `HStack` + draggable divider (like `ContentView.panelDivider`), retaining resize functionality while gaining full control over background rendering.

- **Draw gray behind content without clipping** — use a shaped `.background(UnevenRoundedRectangle(...).fill(contentColor))` instead of rectangular `.background()` + `.clipShape()`, so the area outside the rounded shape is never filled with white in the first place.

## Reproduction

1. Launch the app
2. Go to the Library view (click "All Items" tab)
3. Open a right panel (e.g. AI Chat) so the detail panel is visible
4. Look at the top-left corner of the table area and the top-right corner of the detail panel
5. The small triangular area outside the rounded border is white instead of gray
