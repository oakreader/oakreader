# Motion & Animation Guidelines

Reusable conventions for UI animation in OakReader. Unlike `ADR.md` (one-time
decisions) these are standing rules — apply them to *every* new animation, not
just the one that prompted them.

---

## Expand/collapse "pill" toolbars (active item reveals its label)

**Pattern.** A row of icon-only buttons where the *selected* one expands into a
capsule that reveals a text label (icon + word), while the others stay
icon-only. Modeled on Dia's command bar / iOS active-tab labels.

**Reference implementation:** `OakReader/Views/TabBar/TabBarView.swift` —
`PanelTabButtonView` and `LibraryTabButtonView` (the right-side title-bar
buttons: AI Chat / Metadata / Translation / Quiz Cards).

### The principles (transferable — these are the actual lessons)

1. **Bounce = 0 for anything containing text.** Use a critically-damped spring
   (`.smooth`, or `.spring(... dampingFraction: 1.0)`), never an under-damped
   one. Overshoot on a *label* is the #1 polish mistake — the eye is trying to
   read the word while it bounces, which reads cheap. Save bounce for playful,
   text-free elements. (Apple WWDC23 "Animate with springs" defaults bounce to 0
   for exactly this reason.)

2. **Asymmetric in/out: slow expand, fast collapse.** Each button animates
   *independently* and knows nothing about the others. If collapse is as slow as
   expand, switching A→B leaves A's label lingering while B's grows → the two
   labels visibly **overlap**. Fix: make collapse much faster than expand so the
   old label is gone before the new one finishes.
   - Current values: **expand `0.55s`, collapse `0.15s`** (`.smooth`).
   - Implemented as `.animation(isActive ? .smooth(0.55) : .smooth(0.15), value: isActive)`
     — the conditional reads the *new* state, so becoming-active = slow,
     becoming-inactive = fast.

3. **One spring drives both layout and the label transition.** Tie the capsule's
   width growth and the label's `.transition` to the *same* `value:` so they
   share a clock. Different curves/durations on width vs. opacity = "text chasing
   the container" tearing.

4. **Clip, don't truncate.** `.clipShape(Capsule())` on the container +
   `.fixedSize(horizontal: true, vertical: false)` on the label. The label keeps
   its ideal width (so it never gets an ellipsis mid-grow) and is *clipped* by
   the still-growing capsule instead — a clean slide-out, not an ugly "…" flash.

5. **Anchor the icon — don't recenter the row.** Keep a *constant* leading
   padding (`.padding(.leading, 9)`) and grow only the trailing side
   (`.padding(.trailing, isActive ? 10 : 9)`, `.frame(minWidth: 34, alignment: .leading)`).
   If you instead toggle symmetric padding, the icon's x-position shifts when the
   label appears and the icon visibly "jumps."

6. **Reveal direction = outward from the icon.** Label transition is
   `.move(edge: .leading).combined(with: .opacity)` — the word slides out from
   behind the icon, icon stays put.

### The polish workflow (how to tune, not just what to ship)

Before trusting any hand-picked spring, **slow it to ~0.1× and watch it
frame-by-frame** (temporarily multiply the duration ~10×). It surfaces problems
invisible at full speed: icon jump, label overshoot, old/new overlap, easing
mismatch between width and opacity. Tune at 0.1×, then restore. (The "slow to
0.1x" CSS-polish technique — it's an inspection step, not a shipped value.)

### Perceptual timing band

~250–400ms is the sweet spot for a micro-interaction reveal: above the ~100ms
"instant" threshold (so the motion is readable) but fast enough to feel
responsive. Sub-100ms reads as instant/no-animation; >600ms starts to feel slow.

---

## Sources

- Apple, WWDC23 "Animate with springs" (session 10158) — two-param model
  (duration + bounce), bounce 0 = safe default.
- `.smooth` / `.snappy` / `.bouncy` ≈ critically-damped / small / visible
  overshoot; all default `duration: 0.5`.
- pow.rs easing handbook & NN/g — asymmetric in/out, the ~100ms instant
  threshold, ease-out as the default UI curve.
