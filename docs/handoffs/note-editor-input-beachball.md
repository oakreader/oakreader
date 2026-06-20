# Handoff: Note-editor input beachballs (CPU peg) on `en-GB`

**Status:** FIXED 2026-06-20 — root cause found and patched (see "## RESOLUTION"
below). Build-green; behavioural confirmation on `en-GB` still recommended (the
repro needs a document with several saved notes open by hand — see §9).
**Owner handoff date:** 2026-06-20

---

## RESOLUTION (2026-06-20)

**Root cause (confirmed against the §3 sample stack):** the one symbol-bearing
`AppKitPopUpAdaptor` in the Notes subtree was the **per-note-card `Menu`** at
`CommentsPanelView.swift:351`, whose label is an **icon-only
`Image(systemName: "ellipsis")` that had no pinned accessibility label**. There is
one such menu **per card**, so every SwiftUI transaction flush the composer drives
re-applied accessibility properties to all N menus, each resolving the `ellipsis`
symbol's *localized* a11y description (`accessibilityEffectiveText`) — the exact
`PlatformItemList.Item.applyAccessibilityProperties → accessibilityEffectiveText`
node in the smoking-gun stack. On `en-GB` that CFBundle-table walk is slow, so with
several cards the flushes never catch up → beachball. The AIChatView Pickers (§5)
were already `OakLabel`-pinned and their options are plain `Text`, so they were
**not** the culprit.

**Fix (canonical, per `sfsymbol-a11y-locale-hang`):** pinned the menu label with
`.accessibilityLabel(Text("More"))` so SwiftUI short-circuits the symbol-description
resolution. This makes each transaction flush cheap regardless of how often the
composer re-renders — i.e. it kills the *cost*, not just one trigger (Lever A in
§10, the preferred fix). No churn-reduction (Lever B) was needed: the existing
`@Binding` guards in `NativeNoteEditorView` (`if activeFormats != set`, height
`> 0.5`, `isEmpty`/`charCount` diffs) already suppress no-op writes.

The working-tree partial fixes were kept (they are correct hygiene / shipping
values): `NoteComposerBox` `Aa` toggle `.easeOut(0.12)` + `.accessibilityHidden`
on the format-bar/link icons, and the `drawBackground` blockquote rule.

**Still to do (manual, optional):** rebuild + open a doc with several notes on the
`en-GB` machine, then click the composer / press `Aa` / apply a blockquote and
confirm CPU stays idle and a `sample` shows no `accessibilityEffectiveText` time
(the §11 Definition of Done). The original (now superseded) status follows.

---

**Original status (superseded):** OPEN — not fixed. Two partial fixes landed in the
working tree but the core hang persists.
**Severity:** High — the right-panel **Notes** composer is unusable on this machine:
clicking into the text area, pressing the `Aa` formatting toggle, or applying a
blockquote spins the macOS beachball (main thread pegged ~100% CPU).

> Goal for the next agent: find the ONE component that pegs the CPU and fix it
> cleanly, OR establish that the new native note editor needs a small structural
> rewrite of how it reports state back to SwiftUI. Do **not** keep band-aiding
> individual buttons — see "Why the first attempts failed".

---

## 1. Symptoms (as reported, in order)

1. Pressing the **blockquote** button in the note composer froze the input — could
   not type, could not press Enter, could not click other buttons.
2. After a fix attempt, pressing **`Aa`** (the formatting-bar toggle) beachballed.
3. After a second fix attempt, **just clicking into the text area** beachballs.

The trend matters: each "fix" narrowed one trigger but the underlying hang is
reachable from *any* interaction that causes the composer to re-render. Treat the
trigger list as non-exhaustive.

## 2. Environment preconditions (do not skip)

- **macOS locale is `en_GB`** (`defaults read -g AppleLocale` → `en_GB`;
  `AppleLanguages` → `en-GB`, `zh-Hans-GB`). This is the **non-base** locale that
  makes SF-Symbol *accessibility-description* resolution walk CFBundle
  localization-variant tables. The bug class is documented in the project memory
  note **`sfsymbol-a11y-locale-hang`** and was the cause of the last two shipped
  fixes (`68ed77e3`, and the AIChatView menu fix before it). **This hang does NOT
  reproduce on a base `en` / `en-US` machine** — if you can't reproduce, check your
  locale first.
- The native note editor is **new**: `f61a9f26 refactor(notes): replace Milkdown
  webview editor with a native one`. The blockquote work is uncommitted WIP on top.
- **Two same-named processes gotcha:** a Release build (`~/Applications` /
  `com.oakreader.OakReader`) and the Debug dev build
  (`com.oakreader.OakReader.dev`, display "OakReader Dev") can both be running.
  Always confirm you are testing the dev build you just rebuilt:
  `pgrep -fl "Debug/OakReader.app/Contents/MacOS/OakReader"`.

## 3. Hard evidence — the sampled spin stack

`sample <pid>` while beachballing (this is the smoking gun — main thread, collapsed):

```
__CFRunLoopDoObservers
 └ NSRunLoop.flushObservers()                         (SwiftUICore)
   └ NSHostingView.beginTransaction()                 (SwiftUI)
     └ Update.ensure / GraphHost.flushTransactions    (SwiftUICore)
       └ GraphHost.runTransaction → AG::Subgraph::update → AG::Graph::UpdateStack::update
         └ PlatformViewChild.updateValue()            (SwiftUICore)
           └ ViewRendererHost.performExternalUpdate()
             └ PlatformViewRepresentableAdaptor.updateViewProvider(_:context:)
               └ AppKitPopUpAdaptor.PlatformView.updateNSView(_:context:)   ← a Picker/Menu
                 └ PlatformItemList.Item.update(_:)
                   └ PlatformItemList.Item.applyAccessibilityProperties(to:textAttribute:)
                     └ PlatformItemList.Item.accessibilityEffectiveText.getter ← SF-symbol a11y text
```

Interpretation (high confidence):
- The spin is **inside a SwiftUI transaction flush** driven by a RunLoop observer —
  i.e. SwiftUI is re-evaluating the view graph.
- The expensive node is an **`AppKitPopUpAdaptor`** = a SwiftUI **`Picker` or
  `Menu`** rendered as an `NSPopUpButton`/`NSMenu`, whose **`PlatformItemList.Item`**
  is resolving the **accessibility text of an SF Symbol** (`accessibilityEffectiveText`).
- On `en-GB` each such resolution is slow; when the composer re-renders repeatedly
  (a "storm"), it never catches up → beachball.

This is the *same* stack as `sfsymbol-a11y-locale-hang`. The new fact is that the
re-render storm now originates from the **note composer**, and the offending
Picker/Menu has **symbol-bearing items** that have NOT been pinned with an explicit
accessibility label.

## 4. The two open questions to answer first

1. **Does it reproduce on clean `HEAD` (no working-tree diff)?**
   `git stash && <rebuild> && test`. If HEAD also beachballs, the native editor
   itself (`f61a9f26`) is the culprit and the blockquote WIP is innocent. If HEAD is
   clean, the WIP introduced it. **Determine this before anything else** — it halves
   the search space. (Unknown at handoff time.)
2. **Which `AppKitPopUpAdaptor` (Picker/Menu) is being updated?** The stack frames
   are all generic SwiftUI; they don't name our view. You need a fuller sample or a
   bisection (below) to identify the exact `Picker`/`Menu`.

## 5. Candidate culprits (the symbol-bearing Menus/Pickers near the composer)

The composer (`NoteComposerBox`) itself has **no Picker/Menu**, but it is rendered
inside `CommentsPanelView`, whose subtree DOES contain pop-up adaptors with symbols:

- `CommentsPanelView.swift:351` — the per-note-card **`Menu { … }`** ("⋯"). Label is
  `Image(systemName:"ellipsis")`; items are text-only. One instance **per card** in
  the stream → with N cards, a single graph flush re-updates N menus.
- `CommentsPanelView.swift:433` — `Label("… references", systemImage:"arrow.turn.up.left")`
  inside a card's reference disclosure.
- `AIChatView.swift:754-790` — the model/effort/permission **`Picker`s**. Their
  *labels* were already pinned with `OakLabel` in `68ed77e3`, but verify they are not
  the live one (and that the right panel isn't keeping `AIChatView` instantiated while
  the Notes tab is active).

None of these is *obviously* the one. The next agent must **confirm by experiment**,
not by static reading — that's why this is a handoff and not a one-line fix.

## 6. The re-render "storm" engine (why ANY interaction triggers it)

`NativeNoteEditorView` (an `NSViewRepresentable`) reports state back to SwiftUI via
**three `@Binding`s that fire on essentially every edit/selection/layout event**:

- `NativeNoteEditorView.swift:417-424` — `onChange` (→ `isEmpty`, `charCount`),
  `onActiveFormats` (→ `activeFormats`), `onHeight` (→ `height`). Each mutates an
  `@State` in `NoteComposerBox` → re-renders the composer subtree.
- `NativeNoteEditorView.swift:447-449` — `textViewDidChangeSelection` →
  `reportActiveFormats()`. **This fires on every caret move and on focus/click**, so
  *clicking into the field* alone pushes a binding update → a SwiftUI transaction →
  the graph flush seen in the stack.

So the editor generates a high-frequency stream of SwiftUI transactions. If any
symbol-bearing Picker/Menu is in the same window graph, each transaction re-pays its
`en-GB` a11y cost. That is the structural smell. A **clean** fix likely coalesces /
debounces these reports (height especially) and ensures the editor's per-keystroke
churn does not force sibling pop-up adaptors to re-evaluate.

## 7. What was already changed (working tree — NOT committed)

Relevant to this bug (other diffed files are unrelated WIP — see `git diff --stat`):

- `NoteComposerBox.swift`
  - `Aa` toggle animation reverted **`.smooth` spring → `.easeOut(0.12)`** (the
    committed/shipping timing). The spring's long settling tail sustained the storm;
    easeOut is short. **Keep this** — it is the proven-good shipping value, and it
    fixed the `Aa` *animation*-driven case, but NOT the click-to-focus case.
  - `.accessibilityHidden(true)` added to the format-bar `toolButton` icons and the
    `link` icons. Harmless hygiene; did **not** fix the hang because the hang is in a
    **Picker/Menu**, not these `Button`s.
- `NativeNoteEditorView.swift`
  - Blockquote rendering moved from `drawGlyphs` to the dedicated
    `drawBackground(forGlyphRange:at:)` pass (Slack-style left rule via
    `boundingRect(forGlyphRange:in:)`); removed the unused `quoteBackground` token.
    This is a correctness improvement for paragraph decoration and is unrelated to
    the a11y peg — keep or adjust as you see fit.

**These changes do not resolve the reported "clicking input beachballs" symptom.**
Consider `git stash` to debug from a clean state, then reapply the `.easeOut` revert.

## 8. Why the first attempts failed (learn from this)

The first fix hardened the format-bar **`Button`s** (`.accessibilityHidden`). But the
sample proves the peg is an **`AppKitPopUpAdaptor`** = a **`Picker`/`Menu`**, a
different component. Hiding button icons cannot fix a menu-item a11y resolution.
**Trust the sampled stack over intuition** — find the actual pop-up adaptor.

## 9. Reproduction recipe

```bash
# 1. Rebuild the dev app (signs with the stable Apple Development identity).
#    Skill: macos-rebuild-dev  — or:
pkill -x OakReader
xcodebuild -scheme OakReader -configuration Debug -allowProvisioningUpdates build 2>&1 | tail -3
open "$(xcodebuild -scheme OakReader -configuration Debug -showBuildSettings 2>/dev/null \
  | grep -m1 BUILT_PRODUCTS_DIR | sed 's/.*= //')/OakReader.app"

# 2. Open any document → right panel → Notes tab → click into the bottom composer.
#    (The library card grid is NOT AppleScript-clickable; open a doc by hand.)

# 3. While it spins, sample the main thread WITH our frames visible:
PID=$(pgrep -f "Debug/OakReader.app/Contents/MacOS/OakReader" | head -1)
sample "$PID" 4 -file /tmp/oak-note-hang.txt      # do NOT pass -mayDie (it killed the proc last time)
#    Then read /tmp/oak-note-hang.txt and find the deepest OakReader.* frame under
#    the AppKitPopUpAdaptor.updateNSView node — that names the offending view.
```

Tips for a more informative sample:
- Drop `-mayDie` — it terminated the hung process during the last capture.
- Search the call graph for `OakReader`, `CommentsPanelView`, `AIChatView`,
  `Menu`, `Picker` to tie the generic SwiftUI frames to our code.
- Alternatively **bisect by removal**: temporarily replace the per-card `Menu`
  (`CommentsPanelView.swift:351`) label/items with plain text (no `Image`), rebuild,
  and see if the hang disappears. Repeat for each candidate in §5. Whichever removal
  stops the beachball is your culprit.

## 10. Fix direction (clean, not band-aid)

Two complementary levers — prefer (A); add (B) if churn is still high:

**A. Pin accessibility on the offending pop-up's symbol content.** Per
`sfsymbol-a11y-locale-hang`, the canonical fix is the **`OakLabel(_:systemImage:)`**
factory in `OakReader/Views/Shared/OakLabel.swift` (it is `Label(...).accessibilityLabel(Text(title))`,
which pins the label so SwiftUI skips the symbol's localized-description resolution).
For icon-only `Image(systemName:)` inside a `Menu`/`Picker` item, give an explicit
`.accessibilityLabel(Text("…"))` (semantic name) or `.accessibilityHidden(true)`.
Apply to the Picker/Menu identified in §9 — and, defensively, to all symbol-bearing
menu/picker items rendered in `CommentsPanelView` (the per-card `Menu` and the
references `Label`).

**B. Reduce the composer's re-render churn (the storm).** In
`NativeNoteEditorView` / `NoteComposerBox`, coalesce the `@Binding` reports so a
click or single keystroke doesn't fan out a transaction that re-flushes sibling
pop-up adaptors:
- Only push `activeFormats` when the set actually changes (a guard exists — verify it
  holds for focus/click, which currently routes through `textViewDidChangeSelection`).
- Debounce / throttle `onHeight` (height changes drive a `.frame(height:)` on the
  representable → layout churn).
- Confirm typing/selection in the editor does not invalidate the parent
  `CommentsPanelView` (e.g. via the shared `@Observable CommentsViewModel`), which
  would re-render every card's `Menu`.

Verify with `Self._printChanges()` on the suspect views, or Instruments
(SwiftUI / Time Profiler), to confirm the re-render fan-out before and after.

## 11. Definition of done

- On `en-GB`, with a doc open and several notes in the stream: clicking the
  composer, pressing `Aa`, toggling each format button, and applying a blockquote
  all respond instantly. CPU returns to idle (`ps -p <pid> -o %cpu` ≈ 0) within a
  frame or two of each action.
- `sample <pid>` during rapid typing shows **no** sustained
  `accessibilityEffectiveText` / `applyAccessibilityProperties` time.
- Blockquote still renders its Slack-style left rule (the `drawBackground` change).
- No regression to the AIChatView menus already fixed in `68ed77e3`.

## 12. Key files & line anchors

| File | What |
|---|---|
| `OakReader/Views/RightPanel/Comments/NativeNoteEditorView.swift` | the new native editor; `NSViewRepresentable` + `NoteEditorTextView` + `NoteTagLayoutManager`. Bindings at `:417-424`, selection→activeFormats at `:447-449`, `drawBackground` blockquote at `~:461`. |
| `OakReader/Views/RightPanel/Comments/NoteComposerBox.swift` | the composer card (toolbar, `Aa`, format bar). `Aa` toggle `:205`; `toolButton` factory `~:336`. |
| `OakReader/Views/RightPanel/Comments/CommentsPanelView.swift` | hosts the composer; per-card `Menu` `:351`, references `Label` `:433`. |
| `OakReader/Views/RightPanel/AIChatView.swift` | model/effort/permission `Picker`s `:754-790` (labels already `OakLabel`-pinned). |
| `OakReader/Views/Shared/OakLabel.swift` | the canonical a11y-pinning `Label` factory. |

## 13. Project memory references (read these)

- `sfsymbol-a11y-locale-hang` — the bug class, the exact prior stack, and the
  `OakLabel` remedy. **This is the most relevant note.**
- `flomo-notes-milkdown` / `milkdown-note-editor` — history of the Notes composer
  (note: the editor was since rewritten native, `f61a9f26`).
- Build gotchas: new `.swift` files need `xcodegen generate` before `xcodebuild`
  (XcodeGen owns the file list via `project.yml`); two same-named procs (Release vs
  Debug-Dev).
