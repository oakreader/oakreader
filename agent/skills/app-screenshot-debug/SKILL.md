---
name: app-screenshot-debug
description: "Drive the running OakReader app via AppleScript / System Events to reproduce a specific UI state (open a window, switch a Settings pane, click a control, open a sheet), capture a pixel-accurate screenshot of just that window, and read it back for visual analysis — for diagnosing layout / animation / spacing / 'this looks ugly' issues that can't be judged from code alone. Invoke when the user says 'screenshot the app', 'take a screenshot', 'show me what it looks like', 'what does X look like', 'navigate to X and capture it', 'debug this visually', 'verify the UI change', '截图看看', '看看长什么样', '帮我截个图分析'. Complements `macos-rebuild-dev` (which only rebuilds + launches) — use that first if code changed, then this to see the result."
---

# Screenshot-driven UI debugging (AppleScript + screencapture)

The loop for *seeing* an OakReader UI change instead of guessing from code:

```
(rebuild if code changed)  →  drive app into the target state  →  capture the window  →  Read the PNG  →  judge / iterate
```

You cannot evaluate spacing, alignment, "ghosting", overlap, or "this looks
ugly" from source. Get a real screenshot, Read it, then decide.

## Prerequisites

- The app must be **running** and built. If you just changed code, run the
  `macos-rebuild-dev` skill first (it kills, rebuilds, relaunches). The dev build
  is named **OakReader** (display "OakReader Dev", bundle `…OakReader.dev`); the
  process name for System Events is still `OakReader`.
- These need macOS **Accessibility** + **Screen Recording** permission for the
  terminal/Claude Code host. If `System Events` calls error with `-25211` or the
  capture is black, that permission is missing — tell the user to grant it in
  System Settings → Privacy & Security.

## The three helper scripts (in `scripts/`)

Run them with bash; they take the app name from `$OAK_APP_NAME` (default
`OakReader`).

1. **`capture-window.sh [out.png]`** — screenshot *just* the frontmost OakReader
   window (no shadow `-o`, no sound `-x`), reading its live bounds first. Prints
   the window origin + size. Captures the window region 1:1 in points, so **a
   point you read off the resulting image is window-relative** (image (dx,dy) =
   screen (originX+dx, originY+dy)).

2. **`open-settings.sh [row]`** — `⌘,` to open Settings, then optionally select a
   sidebar pane by 1-based row index (the sidebar is an `AXOutline`). As of this
   writing: 1 General · 2 Library · 3 AI · **4 Agent** · 5 Audio · 6 Skills ·
   7 Extensions · 8 Translation · 9 Web Search — **verify against the live build**,
   panes get reordered.

3. **`click-in-window.sh <dx> <dy>`** — click at a **window-relative** point: it
   re-reads the live window origin and adds your offset. Use the exact (dx,dy) you
   measured on a `capture-window.sh` image — this survives the window moving or
   opening on a different display.

## Canonical recipe

```bash
SK=agent/skills/app-screenshot-debug/scripts

bash $SK/open-settings.sh 4          # open Settings → Agent pane
bash $SK/capture-window.sh /tmp/shot.png
# → Read /tmp/shot.png with the Read tool, find the control you want at (dx,dy)
bash $SK/click-in-window.sh 313 362  # e.g. click a "Manage…" button
bash $SK/capture-window.sh /tmp/shot2.png   # Read again to see the sheet
osascript -e 'tell application "System Events" to key code 53'  # Escape = dismiss sheet
```

Then **Read** each PNG to analyze. Capture before *and* after a change for an
honest before/after.

## Driving the UI — patterns that actually work

- **Open Settings:** `keystroke "," using command down` (after `activate`).
- **Select a sidebar pane (NavigationSplitView):** it's an outline of rows —
  `select row N of outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1`.
  Plain `click` on the row's static text is unreliable; `select row` is solid.
- **Click a control:** prefer `click-in-window.sh` with coords read off the
  screenshot. `click at {x,y}` (global points) conveniently **returns the AX
  element path it hit** — use that to confirm you hit the right thing (e.g.
  `button "Reflection prompts" of group 3 of scroll area 1 …`).
- **Dismiss a sheet / cancel:** `key code 53` (Escape). Default button:
  `keystroke return`.
- **Get window bounds live:** `get position of window 1` / `get size of window 1`.

## Gotchas (learned the hard way)

- **Never hardcode window coordinates across calls.** The window can reopen at a
  different origin or on another display between launches. Always re-read bounds
  (the scripts do) — this is the whole reason `click-in-window.sh` exists.
- **`screencapture -R x,y,w,h` uses the same global point coords** as System
  Events, and the captured image maps points→pixels 1:1 for the width you asked
  for, so window-relative math is trivial: `dx = screenX - originX`.
- **`whose value is "Agent"` / searching `entire contents`** often throws
  `Invalid index (-1719)` or returns nothing because the label is a nested child
  or has no AX `value`/`title` (e.g. a SwiftUI `Label` in a `Button`). Fall back
  to row-index selection or coordinate clicks.
- **Always `-o` (no shadow) and `-x` (silent)** so the crop is exact and there's
  no shutter sound.
- **Add a `sleep`** (~0.8–1.2s) after navigation/clicks before capturing, so the
  sheet/animation has settled — otherwise you screenshot a mid-transition frame
  (which, ironically, is sometimes exactly what you want for animation debugging:
  capture mid-transition on purpose to inspect overlap/ghosting).
- Save shots under `/tmp/<task>/…png` and Read them; don't leave them in the repo.
```
