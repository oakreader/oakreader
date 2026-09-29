---
name: design-token-extraction
description: "Extract design tokens (colors, fonts, typography metrics) from a running or installed macOS app — to reverse-engineer/reference its visual design. Colors come exactly from compiled asset catalogs (assetutil); fonts from bundled files; and font size / line-height / paragraph-spacing are MEASURED from a live screenshot via pixel analysis (the metrics are baked into code and not statically readable). Invoke when the user wants to analyze another app's typography/colors, measure line spacing or font size from a screenshot, pull a color palette, or build a token set that matches a reference app (e.g. Dia)."
---

# Design-token extraction from a macOS app

Two tracks, because two kinds of data live in two places:

| Want | Where it lives | How to get it | Precision |
|---|---|---|---|
| **Colors** (named, light/dark) | compiled `Assets.car` | `assetutil` → `extract-colors.py` | exact |
| **Fonts** (which faces ship) | `*.bundle` font files | `find … -iname '*.otf' -o -iname '*.ttf'` | exact (names) |
| **Font size / line-height / spacing** | baked into code (NSFont/NSParagraphStyle) | screenshot + pixel analysis → `measure-typography.py` | ±0.5pt (measured) |
| **Body text color** | often NOT named | usually system `labelColor` / `secondaryLabelColor` | infer |

Both scripts live in `scripts/` next to this file.

## Track 1 — Colors (exact)

```bash
# whole app (scans every Assets.car) or a single catalog
python3 agent/skills/design-token-extraction/scripts/extract-colors.py /Applications/Foo.app
python3 .../extract-colors.py /Applications/Foo.app/Contents/Resources/SomeBundle.bundle/Contents/Resources/Assets.car
python3 .../extract-colors.py /Applications/Foo.app --filter 'border|background|text|accent'
```
Output is `Name [Appearance] #RRGGBB @alpha%`, with `any` (light) and `NSAppearanceNameDarkAqua` (dark)
rows per token. Look for the bundle whose name matches the surface you care about (e.g. Dia's chat colors
are in `BoostBrowser_AssistantPanelUIBase.bundle`, accent themes in `BoostBrowser_ColorPalette.bundle`).

Fonts:
```bash
find /Applications/Foo.app -iname '*.otf' -o -iname '*.ttf' -o -iname '*.ttc' | sed 's|.*/||' | sort -u
```
Brand fonts are usually **licensed → not redistributable**. Map to the system equivalent (SF Pro for a
grotesque sans, SF Mono for code, PingFang SC for CJK) unless brand identity is essential.

## Track 2 — Typography (measured from a screenshot)

### Step A — capture the surface with the `computeruse` skill
The metrics are NOT in the binary; you must measure a *rendered* example. Get the app showing a real
reply with body text, ideally a heading, a code block, and a list.
```bash
computeruse permissions                              # need accessibility + screen_recording
computeruse apps --format json | grep -i foo         # find pid
computeruse windows --pid <pid> --format json        # get window id AND display.scale_factor
computeruse key --key escape --pid <pid>             # dismiss popovers for a clean shot
computeruse screenshot --pid <pid> --window-id <wid> --output /tmp/shot.png
```
**Scale factor is critical.** Retina = 2 → `2px = 1pt`. Confirm with
`sips -g pixelWidth /tmp/shot.png` ÷ window-width-in-points, or `display.scale_factor` from `windows`.

### Step B — measure
Open the PNG (Read tool) to pick clean crop regions, then:
```bash
# LINE-HEIGHT + paragraph spacing: crop a column over several body lines
python3 .../measure-typography.py /tmp/shot.png --region x0,y0,x1,y1 --scale 2

# FONT SIZE: crop ONE clean line (pure CJK, or monospace); autocorrelation finds the advance
python3 .../measure-typography.py /tmp/shot.png --region x0,y0,x1,y1 --scale 2 --advance --advance-range 16,40
```

### The math (how the script reasons)
- **Line-height** = baseline-to-baseline pitch = `fontSize × lineHeightMultiple`. Found by horizontal
  projection (dark-ink per row) → text bands → distance between band centers. A pitch noticeably larger
  than the modal one is a **paragraph gap**; `paragraphSpacing = bigPitch − normalPitch`.
- **Font size** via glyph **advance** (vertical autocorrelation of column-ink):
  - **CJK: advance == em == font size, exactly.** Best probe — use a pure-CJK run. (Set `--advance-range`
    to ~16–40px so it can't lock onto a half-period.)
  - **Monospace: advance ≈ 0.6 × em** → `em = advance / 0.6`.
  - **Latin proportional:** advance is meaningless; instead read the band's ink height ≈ **cap-height ≈
    0.7 × em**, or measure a known-cap word.
- **CJK sanity check:** ink height ≈ 0.86–0.88 × em for PingFang — if ink/advance lands there, you've
  got it right.

### Pitfalls
- Pick regions with **uniform content** — mixing CJK + Latin + punctuation breaks per-glyph segmentation
  (autocorrelation tolerates it better than band-splitting, but a clean run is best).
- CJK chars have internal stroke gaps → don't trust naive column band-splitting for advance; use `--advance`
  (autocorrelation), not column counting.
- Code blocks with LaTeX / sub-superscripts add stray rows → measure the plainest code line.
- Always re-confirm scale; an external display may be 1x while the built-in is 2x.

## Output
Compile into a tokens doc + a Swift `OakStyle`-style snippet: body/code `NSFont` sizes,
`lineHeightMultiple`, `paragraphSpacing`, and the light/dark surface colors (resolve via `NSColor`
with appearance variants). See `oakreader-dia-research/docs/research/dia-design-tokens.md` for a worked
example (Dia 1.32.0: body ≈15pt / line-height ≈1.67 / ¶ +12.5pt; panel BG `#FEFFFF`/`#2D2D2D`).

> Reference, don't copy: extracted colors/fonts/metrics are the vendor's IP. Use them to *match feel* and
> learn technique, not to lift assets wholesale. Brand fonts especially are licensed.
