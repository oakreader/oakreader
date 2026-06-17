# Handoff: AI Chat assistant-prose overflow / clip / distortion

**Status:** UNRESOLVED. Multiple fix attempts failed. Written for the next agent.
**Date:** 2026-06-17
**Scope:** OakReader AI Chat — assistant message markdown rendering width.

---

## 1. The bug (what the user sees)

The assistant message text in the AI Chat panel renders wrong on the right side:
- Sometimes **text is clipped** at the right edge (words cut mid-character).
- Sometimes the **whole chat content is wider than its panel and is "pushed
  outside the panel / drawn distorted"** (user's words: "chat 被挪到面板外/画变形",
  "history 和左边缘被截断").
- A consistent thread: it looks fine **while streaming**, and breaks **the moment
  the answer settles** (streaming completes). The user also reports it looking
  wrong "from the start" in some runs.

**CRITICAL CLUE (do not repeat my mistake):** It happens in **BOTH** the PDF
viewer (PDFKit) **and** the HTML/live-web viewer (WKWebView). I wasted a long
detour believing it was the live-web `WKWebView` bleeding over the chat
(`ContentView.swift:64-72` `.clipped()` band-aid). **It is NOT WKWebView-specific.**
Because PDF view (no WKWebView at all) shows the same overflow, the cause is the
**chat prose width itself**, independent of document type.

---

## 2. The core tension (the single most important insight)

The bug lives in `Packages/OakMarkdownUI/Sources/OakMarkdownUI/ProseBlockView.swift`
— an `NSViewRepresentable` wrapping a TextKit-1 `NSTextView` (`MarkdownTextView`).
Each assistant prose block is one such NSTextView.

There are **two failure modes in direct tension**, toggled by one line —
`container.widthTracksTextView`:

| Setting | Fixes | Breaks |
|---|---|---|
| `widthTracksTextView = false` (commit b60ba53a, Jun 16) | CJK long-line "balloon" (chat stays in panel) | **Settle-clip**: container width leaks wider than the frame; glyphs clipped at right edge after streaming settles |
| `widthTracksTextView = true` (pre-Jun-16 + my revert) | Settle-clip (container auto-tracks frame) | **Balloon**: NSTextView reports a too-wide intrinsic width → pushes whole chat past its panel frame → "drawn outside panel / distorted" |

**Neither pure setting works.** Every single-line flip I tried fixed one mode and
reintroduced the other. The real fix must satisfy BOTH invariants simultaneously:
1. The NSTextView must **never report/lay-out a width wider than its committed
   frame** (no balloon).
2. The text container's wrap width must **always equal the committed frame width**,
   including at settle when no further layout pass runs (no clip).

---

## 3. Hard data (from instrumentation — trust this)

I added temporary `NSLog` to `ProseBlockView.sizeThatFits` (logged the SwiftUI
`proposal.width`) and to a `MarkdownTextView.draw()`/`layout()` override (logged
`bounds.width` vs `textContainer.size.width`). The user reproduced; I read the log.

**With `widthTracksTextView = false`:**
```
proposal=431  -> committed frame bounds = 431   (correct)
proposal=711  -> a wider PROBE width
layout: bounds=431  container=711   <-- container 280px WIDER than frame
layout: bounds=448  container=728   <-- same +280 delta
```
So SwiftUI probes `sizeThatFits` at MULTIPLE widths in one layout pass (the real
431 AND a wider 711). `sizeThatFits` sets `container.containerSize = proposedWidth`
as a side effect of measuring height. Whichever probe fires **last** leaves the
shared display container at that width. While streaming, constant relayout re-pins
it (so it looks fine); at settle, nothing re-runs layout → the wide probe (711)
**sticks** → text wraps at 711 in a 431-wide view → clipped. The `+280` delta was
remarkably consistent (711-431, 728-448) — its origin in the layout chain was
never fully traced.

**With `widthTracksTextView = true`:**
```
layout: bounds=727  container=727   <-- container correctly tracks frame, NO leak
```
The container leak is gone. BUT the user then reports the chat "drawn outside the
panel / distorted" — consistent with the NSTextView ballooning its frame (intrinsic
width) past the panel `.frame(width:)`.

---

## 4. Git regression timeline (answers "why did this start ~2 days ago")

- **≤ Jun 15 (`bad7fae7`)**: `widthTracksTextView = true`, `sizeThatFits` did
  `width = proposal.width ?? 320` (NO `.infinity` guard). Mostly worked, but a
  `.infinity` probe → returned infinity → single unwrapped line → CJK balloon.
- **Jun 16 (`b60ba53a`)** "fix(markdown): force container wrap width so long CJK
  lines wrap": flipped `widthTracksTextView` true→false + drove container width
  manually from `sizeThatFits`. Fixed the balloon, **introduced the settle-clip leak.**
- **Jun 17 (`a5db3cad`, the WIP sweep)**: added a `MarkdownTextView.layout()`
  override that pins `container.size.width = bounds.width` each layout, AND added
  the `.infinity` guard (`proposed.isFinite ? proposed : 320`) in `sizeThatFits`.
  This is a partial band-aid: re-pins during streaming/layout, but **settle has no
  layout pass**, so the leaked width still sticks.

The memory note "[Chat Panel AppKit Overflow]" (2026-06-15) records that
`widthTracksTextView=false` was chosen specifically to fix the chat-markdown
balloon — confirming the tension is real and known.

---

## 5. What I changed (CURRENT working-tree state — uncommitted, on `main`)

Two unrelated concerns are bundled; **keep #2, re-evaluate #1**:

1. **(Re-evaluate)** Reverted to the pre-regression markdown width approach:
   - `ProseBlockView.makeNSView`: `widthTracksTextView = true` (was `false`).
   - `ProseBlockView.sizeThatFits`: kept the `.infinity` guard; removed the manual
     `widthTracksTextView = false` line and my experimental restore hacks.
   - `MarkdownTextView`: **removed** the `layout()` override (the a5db3cad pin).
   - Net: these two files ≈ `bad7fae7` (Jun-15 "good") + the `.infinity` guard.
   - **This fixes settle-clip but reintroduces balloon — so it is NOT a complete
     fix.** The next agent should likely ADD an `intrinsicContentSize` cap (see §6)
     rather than flip the flag again.
   - `ChatBubbleView.swift`: `.clipped()` at line ~150 restored to original
     (I had removed it; it was a red herring — file is back to zero diff).
   - All `NSLog`/`OAKWRAP`/`OAKDRAW` debug removed (verified clean).

2. **(Keep — user's product decision)** Removed the redundant **library-level**
   chat surface. `LibraryRootView` had TWO chats on the same `appState.libraryChatVM`:
   the full-page Agent canvas (`librarySurface == .agent`, `presentation: .canvas`)
   AND a browse detail-panel "Chat" tab (`libraryDetailTab == .chat`). User chose
   to keep ONLY the full-page Agent canvas. Removed:
   - `LibraryDetailTab.chat` case (`Utilities/PDFConstants.swift`).
   - The `.chat` branch + switch case in `Views/Library/LibraryRootView.swift`.
   - **Kept** the per-document chat (`RightPanelContentView` → `AIChatView(chatVM:
     viewModel.chat)`, item-scoped, Dia-style) and the Agent canvas. This is
     orthogonal to the overflow bug.

Also ran `xcodegen generate` once (the user concurrently deleted
`ConceptMapWebView.swift` for an unrelated Studio refactor, leaving a stale pbxproj
reference that broke the build until regen). Build is currently GREEN.

---

## 6. Root-cause hypothesis + recommended fix (start here)

The crux is the NSTextView's **dual role**: it both MEASURES (sizeThatFits writes
the shared container width) and DISPLAYS (the same container governs wrapping). The
measurement side-effect leaks; and the NSTextView's intrinsic width can balloon.

**Recommended robust fix (satisfies both invariants):**

A. **Cap intrinsic width** so the view can never push its frame past what SwiftUI
   proposes (kills the balloon, makes `widthTracksTextView = true` safe):
   ```swift
   // in MarkdownTextView
   override var intrinsicContentSize: NSSize {
       NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
   }
   ```
   With `sizeThatFits` implemented, SwiftUI uses it for sizing; forcing
   `noIntrinsicMetric` stops AppKit's natural (unwrapped) width from leaking.

B. **Decouple measurement from display** so a probe width can never stick in the
   display container (kills the settle-clip leak). Options, roughly in order of
   cleanliness:
   - Measure height with a **throwaway/secondary** `NSLayoutManager` +
     `NSTextContainer` attached to the same `NSTextStorage`, OR via
     `attributedString.boundingRect(with:options:)`, leaving the DISPLAY container
     untouched. Then the display container is only ever sized by frame-tracking.
   - OR keep `widthTracksTextView = true` and ensure `sizeThatFits` restores the
     container to the committed `bounds.width` (with a forced re-layout) before
     returning — I tried a version of this; it needs the re-layout (`ensureLayout`
     + `needsDisplay`) AND must handle the case where `bounds` is stale at probe time.

**Verify both modes after any change:** long CJK lines (no spaces) must wrap inside
the panel (no balloon), AND a freshly-streamed answer must stay wrapped after it
settles (no right-edge clip). Test in BOTH PDF and HTML document views, and at
narrow AND wide panel widths (drag the divider).

Also worth checking: the assistant bubble horizontal padding is only
`.padding(.horizontal, 4)` in `AssistantBubbleStyle` (ChatBubbleView ~line 640),
plus `OakStyle.Spacing.sm` (10) on the message list — so even when correct, text
sits ~14px from the panel edge and looks cramped. Consider bumping for breathing
room once the overflow is truly fixed (separate, cosmetic).

---

## 7. How to reproduce + instrument (and ENVIRONMENT CONSTRAINTS)

**Environment is hostile to self-driving — read this or waste hours:**
- `screencapture`/window-capture frequently grabs an overlapping **Google Chrome**
  window instead of OakReader (multiple displays / window overlap). Screenshots are
  unreliable; **ask the user to screenshot** instead.
- Driving the UI via AppleScript/System Events is unreliable: a **Chinese input
  method mangles synthetic ASCII keystrokes** (typed text comes out as garbled
  Chinese), and a new-tab omnibox / wrong-window focus steals input. **Have the USER
  type the chat prompt**, not the agent.

**Instrumentation that worked:**
1. Add `NSLog` in `ProseBlockView.sizeThatFits` (log `proposal.width`, the chosen
   width, and `selectable`) and in a `MarkdownTextView.draw(_:)` override
   (log `bounds.width` vs `textContainer.size.width`; dedupe on width change).
2. Build, then launch FROM TERMINAL so stderr→file:
   `"$BUILT/OakReader.app/Contents/MacOS/OakReader" > /tmp/oak.log 2>&1 &`
   (Rebuild skill `macos-rebuild-dev` launches via `open` → NSLog goes to unified
   log; readable via `log show --predicate 'eventMessage CONTAINS "OAKDRAW"'`.)
3. Ask the user to open a doc, open AI Chat, send a multi-paragraph question, let it
   FULLY settle. Then read the log. Distinguish streaming vs settled via the
   `selectable` flag in the log (`selectable=0` while streaming, `=1` settled —
   driven by `StreamingMarkdownView`'s `selectable: !streaming`).

---

## 8. Key files

- `Packages/OakMarkdownUI/Sources/OakMarkdownUI/ProseBlockView.swift`
  — `makeNSView` (container/tracking setup), `sizeThatFits` (measurement +
  `.infinity` guard), `updateNSView` (incremental text replace; `isSelectable`
  flips on settle).
- `Packages/OakMarkdownUI/Sources/OakMarkdownUI/Internal/MarkdownTextView.swift`
  — the `NSTextView` subclass (custom `HuggingLayoutManager`, link hover). Add the
  `intrinsicContentSize` cap here.
- `Packages/OakMarkdownUI/Sources/OakMarkdownUI/StreamingMarkdownView.swift`
  — block splitting + memoization; `selectable: !streaming` (the stream→settle flip
  that re-renders the tail block and is the timing trigger).
- `OakReader/Views/RightPanel/ChatBubbleView.swift`
  — `AssistantBubbleStyle` (4px h-padding), `chatMarkdown`, `.clipped()` at ~line 150.
- `OakReader/Views/RightPanel/AIChatView.swift`
  — `messageList` frame chain, `canvasConstrained`, `presentation` (.panel vs
  .canvas), `canvasContentWidth = 760`.
- `OakReader/Views/MainWindow/ContentView.swift`
  — right panel `.frame(width: min(rightPanelWidth, maxRightPanel))` (line ~83),
  content-column `.clipped()` for WKWebView (line ~72; NOT the cause — see §1).

---

## 9. Things already ruled out (don't re-investigate)

- ❌ The WKWebView bleed (`.clipped()` in ContentView) — ruled out: bug also occurs
  in PDF view (no WKWebView).
- ❌ The assistant bubble `.clipped()` removal — red herring; the clip that cuts the
  text is the NSTextView's own bounds clip (container wider than frame), not the
  SwiftUI `.clipped()`. Restored to original.
- ❌ `canvasContentWidth`/`.canvas` presentation — `canvasConstrained` uses
  `maxWidth:` (caps, can't force-overflow). The `727 ≈ 760` coincidence misled us;
  727 was just the real panel width, not a forced canvas width.
- ❌ My `updateNSView` re-pin of `widthTracksTextView`, and my `sizeThatFits`
  restore-to-bounds hack — both tried, both insufficient (settle had no relayout;
  restore needs a forced `ensureLayout`).
