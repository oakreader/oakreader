#!/usr/bin/env python3
"""Measure typography (line-height, font size, paragraph spacing) from a screenshot.

Compiled apps bake type metrics into code — you cannot read them statically. But you
CAN measure them from a rendered screenshot with pixel analysis. On Retina, the PNG is
2x the point size, so divide px by the scale factor (usually 2) to get points.

Techniques:
  * LINE-HEIGHT  — horizontal projection (dark-ink per row) finds text bands; the
                   distance between consecutive band centers is the baseline pitch
                   (= fontSize x lineHeightMultiple). Paragraph gaps show up as a
                   larger-than-normal pitch.
  * FONT SIZE    — vertical autocorrelation of column-ink finds the glyph advance.
                   For CJK, advance == em == font size EXACTLY (cleanest probe).
                   For monospace, advance ~= 0.6 x em. For Latin proportional text,
                   prefer cap-height (~0.7 x em) measured from a single line's ink height.

Get the scale factor from `computeruse windows --pid <pid>` (display.scale_factor) or
`sips -g pixelWidth img.png` / window-width-in-points.

Usage:
    python3 measure-typography.py shot.png --region 1360,380,2110,780          # line-height
    python3 measure-typography.py shot.png --region 1380,576,1760,604 --advance # font size (CJK/mono)
    python3 measure-typography.py shot.png --region ... --scale 2 --threshold 120

Requires: Pillow (PIL), numpy.
"""
import argparse, sys
import numpy as np
from PIL import Image


def bands_from_profile(profile, frac=0.12, min_thr=3):
    thr = max(min_thr, profile.max() * frac)
    on = profile > thr
    bands, s = [], None
    for i, v in enumerate(on):
        if v and s is None:
            s = i
        if not v and s is not None:
            bands.append((s, i - 1))
            s = None
    if s is not None:
        bands.append((s, len(on) - 1))
    return bands, thr


def measure_lines(crop, scale, x0, y0, threshold):
    ink = (crop < threshold).sum(axis=1)  # dark px per row
    bands, thr = bands_from_profile(ink)
    print(f"  rows scanned, threshold={thr:.0f}, {len(bands)} text bands:")
    centers = []
    for s, e in bands:
        h = e - s + 1
        centers.append((s + e) / 2)
        print(f"    y={y0+s:5d}-{y0+e:<5d} inkHeight={h:3d}px ({h/scale:.1f}pt)")
    pitches = [centers[i] - centers[i - 1] for i in range(1, len(centers))]
    if pitches:
        print("  baseline pitches (consecutive centers):")
        for p in pitches:
            print(f"    {p:6.1f}px = {p/scale:.2f}pt")
        # the modal (smallest cluster) pitch is the intra-paragraph line-height;
        # larger ones are paragraph gaps.
        sp = sorted(pitches)
        line = np.median([p for p in pitches if p <= sp[len(sp)//2] * 1.3])
        paras = [p for p in pitches if p > line * 1.3]
        print(f"\n  => line-height ~= {line:.1f}px = {line/scale:.2f}pt")
        if paras:
            extra = np.mean(paras) - line
            print(f"  => paragraph spacing ~= +{extra:.1f}px = +{extra/scale:.2f}pt")


def measure_advance(crop, scale, lo, hi):
    ink = (255 - crop.astype(float)).sum(axis=0)  # darkness per column
    ink -= ink.mean()
    n = len(ink)
    res = []
    for lag in range(lo, hi):
        if n - lag < 8:
            break
        c = np.corrcoef(ink[: n - lag], ink[lag:])[0, 1]
        if not np.isnan(c):
            res.append((lag, c))
    res.sort(key=lambda t: -t[1])
    print("  glyph advance candidates (autocorrelation):")
    for lag, c in res[:6]:
        print(f"    {lag:3d}px = {lag/scale:.2f}pt   corr={c:.2f}")
    if res:
        best = res[0][0]
        print(f"\n  => advance ~= {best}px = {best/scale:.2f}pt")
        print(f"     CJK: font size = {best/scale:.1f}pt | mono: em ~= {best/0.6/scale:.1f}pt")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("--region", required=True, help="x0,y0,x1,y1 in image pixels")
    ap.add_argument("--scale", type=float, default=2.0, help="px per pt (Retina=2)")
    ap.add_argument("--threshold", type=int, default=120, help="dark-pixel cutoff 0-255")
    ap.add_argument("--advance", action="store_true", help="also estimate font size via autocorrelation")
    ap.add_argument("--advance-range", default="8,40", help="lo,hi advance search in px")
    args = ap.parse_args()

    x0, y0, x1, y1 = (int(v) for v in args.region.split(","))
    gray = np.asarray(Image.open(args.image).convert("L"))
    H, W = gray.shape
    print(f"image {W}x{H}px, scale={args.scale} (so {args.scale}px = 1pt), region=({x0},{y0})-({x1},{y1})")
    crop = gray[y0:y1, x0:x1]

    print("\n[LINE-HEIGHT / SPACING]")
    measure_lines(crop, args.scale, x0, y0, args.threshold)
    if args.advance:
        lo, hi = (int(v) for v in args.advance_range.split(","))
        print("\n[FONT SIZE / ADVANCE]")
        measure_advance(crop, args.scale, lo, hi)
    return 0


if __name__ == "__main__":
    sys.exit(main())
