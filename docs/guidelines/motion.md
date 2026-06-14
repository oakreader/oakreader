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
`PillTabButton` (the right-side title-bar buttons: AI Chat / Metadata /
Translation / Quiz Cards, and the library detail tabs).

### The one rule that matters: never insert/remove the label

> **Do NOT write `if isActive { Text(label) }`.** The label must be *permanent*
> in the view tree; animate its **width and opacity as continuous properties**
> instead.

Conditionally inserting/removing the label hands the animation to SwiftUI's
`.transition` machinery, which produced two bugs that *no amount of
duration-tuning fixed*:

1. **Double-image / "ghost".** Switching A→B cross-fades A's *removal* with B's
   *insertion*, so two labels are briefly on screen at once. Asymmetric
   fast-collapse/slow-expand only narrows the overlap window — it never closes
   it, because the incoming label starts fading in from t=0 while the outgoing
   one is still fading out.

2. **Flash.** Trying to fix #1 by *delaying* the incoming label's `.transition`
   makes SwiftUI pop it to its final state for one frame before animating — a
   known insertion-transition quirk
   ([forums.swift.org/t/.../42211](https://forums.swift.org/t/transitions-view-insertion-not-animating/42211),
   [HWS](https://www.hackingwithswift.com/forums/swiftui/transition-insertion-not-working/8139)).

The community pattern for this exact "active reveals label" UI is to **animate
one continuous thing, never insert/remove** — e.g. a single highlight capsule
moved with `matchedGeometryEffect` across always-present labels
([nilcoalescing](https://nilcoalescing.com/blog/CustomSegmentedControlWithMatchedGeometryEffect/),
[objc.io](https://www.objc.io/blog/2020/02/25/swiftui-tab-bar/)). Our buttons
collapse the label to *zero width* when inactive, which is the same idea applied
per-button.

### How `PillTabButton` does it

1. **Label always present; width measured once.** A `TabLabelWidthKey`
   preference reads the label's natural width, then
   `.frame(width: isActive ? labelWidth : 0, alignment: .leading)` + `.opacity`
   animate it open/closed. No `if`, no `.transition`, no identity change.

2. **Delay lives on the *property* animation, not a transition.** Becoming
   active uses `.smooth(0.3).delay(0.13)`; becoming inactive uses
   `.smooth(0.12)`. The delay (~= collapse time) sequences the labels so the old
   one is fully gone before the new one starts — *zero* overlap. The delay is
   safe **only** because it sits on width/opacity, not on a `.transition` (that
   would re-introduce the flash from #2 above).
   - Trade-off: opening a panel from *nothing* active also waits `0.13s`. With a
     property animation (no flash) this reads as fine; if it ever feels sluggish,
     lift "is a switch in progress" to the parent and drop the delay on
     first-open only.

3. **Bounce = 0 for anything containing text.** Use a critically-damped spring
   (`.smooth`), never an under-damped one. Overshoot on a *label* is the #1
   polish mistake — the eye is trying to read the word while it bounces.
   (Apple WWDC23 "Animate with springs" defaults bounce to 0 for exactly this.)

4. **One `value:` drives everything.** Width, opacity, fill, padding, and color
   all key off `isActive` through the same `.animation(_:value: isActive)` so
   they share a clock — no "text chasing the container" tearing.

5. **Clip, don't truncate.** `.clipShape(Capsule())` on the container +
   `.fixedSize()` on the label. The label keeps its ideal width (never an
   ellipsis mid-grow) and is *clipped* by the still-growing capsule.

6. **Anchor the icon — don't recenter the row.** Constant leading padding
   (`.padding(.leading, 9)`), grow only the trailing side
   (`.padding(.trailing, isActive ? 10 : 9)`, `.frame(minWidth: 34, alignment: .leading)`).
   Toggling symmetric padding shifts the icon's x-position and it visibly "jumps."

7. **Reveal direction = outward from the icon.** The label's frame grows from its
   leading edge, so the word appears to slide out from behind the icon while the
   icon stays put.

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
