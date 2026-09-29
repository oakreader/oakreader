---
name: dead-code-scan
description: "Find and safely remove dead/unused Swift code in OakReader using `periphery` (index-based, handles implicit refs that grep can't). Invoke when the user says 'dead code', 'find unused code', 'periphery', 'what can I delete', 'clean up dead code', or wants a dead-code audit."
---

# Dead-Code Scan (periphery)

Find truly-unused Swift declarations in the OakReader app target and remove them
safely. Use `periphery` — it analyzes the compiled index, so it correctly resolves
implicit references (protocol witnesses, `#selector`, `NotificationCenter` names,
SwiftUI `@Observable` access, `#Preview`) that **grep gets wrong**. Do not hand-roll
dead-code detection with grep; grep also can't see transitive death (a type referenced
only by other dead code reads as "used").

## Prerequisite

```bash
which periphery || brew install peripheryapp/periphery/periphery
```
It is NOT a project dependency — just a local CLI. periphery needs the project to
**build successfully first**; fix any red build before scanning.

## 1. Scan

```bash
cd /Users/yuanjiwei/Documents/GitHub/oakreader
periphery scan --project OakReader.xcodeproj --schemes OakReader --targets OakReader --quiet > /tmp/periphery.txt 2>/dev/null
wc -l /tmp/periphery.txt
```
This rebuilds the project (~1–3 min). Scope to `--targets OakReader` (the app); the SPM
packages — OakAI, OakAgent, etc. — expose public API and would report false positives if
scanned the same way. Audit a package separately only on request, and verify its public
symbols are truly unused across the whole repo first.

## 2. Categorize

```bash
# Whole unused top-level types — the high-value, low-risk deletions
grep -E "warning: (Struct|Class|Enum|Protocol|Actor) '.*' is unused" /tmp/periphery.txt \
  | sed -E "s|.*/oakreader/||; s|:[0-9]+:[0-9]+: warning:|  →|"
# Counts
echo "types:  $(grep -cE "warning: (Struct|Class|Enum|Protocol|Actor) '.*' is unused" /tmp/periphery.txt)"
echo "funcs:  $(grep -c "warning: Function '" /tmp/periphery.txt)"
echo "props:  $(grep -c "warning: Property '" /tmp/periphery.txt)"
```

Group findings into tiers and act in this order (safest first):
1. **Whole unused types where the entire file is dead** → delete the file.
2. **Unused types/cascade config models** that only the now-deleted code referenced.
3. **Members inside live files** (funcs/properties) — high volume, low value, higher
   risk to trim. Leave these alone unless the user explicitly asks; flag the count.

## 3. Methodology: the compiler is the arbiter

Swift is statically compiled — **a deletion can't silently break anything**. So:
delete a batch → `xcodebuild` → if it errors, the error names exactly what still needs
the symbol → `git checkout` that one file back. Never trust a grep ref-count over a
build result.

```bash
git rm -q <files...>
# XcodeGen uses glob sources (project.yml: path: OakReader), so regenerate after add/remove:
xcodegen generate >/dev/null
xcodebuild -scheme OakReader -configuration Debug -destination 'platform=macOS' build 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -30
```

**Iterate.** Deleting a feature makes its private helpers newly-dead. Re-run the scan
(step 1) after each big deletion — the count drops and the next layer surfaces. Repeat
until only false-positives / intentional-WIP remain.

## 4. The two gotchas (both hit in the 2026-06 sweep — see [[dead-code-cleanup-2026-06]])

1. **Secondary live type hiding in a "dead" file.** periphery flags a file's *primary*
   type as unused, but the file may also declare a small *live* type. Deleting the whole
   file breaks the build. Example: `PageRange` lived at the bottom of the (dead)
   `WatermarkConfig.swift` but was used by `ExportSheet`/`PageRangeSelector`. Fix:
   extract the live type to its own file, don't restore the dead one. Before deleting a
   file, scan it for ALL top-level decls, not just the flagged one.

2. **Child-VM wiring + external readers.** A `DocumentViewModel` lazy child VM
   (`var security = SecurityViewModel(...)`) can have ALL its methods flagged unused yet
   the class itself NOT flagged — because something still instantiates/reads it
   (`OakReaderDocument` reads `.security.settings`). Don't delete a child VM on the
   strength of "all methods unused"; check who reads the accessor. To remove a genuinely
   dead child VM, also delete its `_x`/`var x` block in `DocumentViewModel`.

## 5. Keep, don't delete

periphery can't tell "dead" from "built but not yet wired". Before deleting, sanity-check
against project memory and roadmap. Known intentional-WIP to KEEP even when flagged:
`WebExtensionController` (planned for [[browser-mode]], needs macOS 15.4). When unsure
whether something is abandoned vs. planned, ask the user rather than deleting.

## 6. Report

Tell the user: scan count before/after, what was deleted (grouped by feature), anything
kept and why, and the remaining member-level count left untouched. Note that everything
is recoverable from git. Offer to record a memory note if a whole dormant feature was
removed (so it isn't re-hunted later).
