#!/usr/bin/env python3
"""Dump named colors (with light/dark variants) from a macOS asset catalog.

Compiled `Assets.car` files store named colors with exact RGBA + per-appearance
(light / dark) variants. `assetutil` (built into macOS) can emit them as JSON.
This wraps it into a readable table with hex + alpha.

Usage:
    python3 extract-colors.py /path/to/Assets.car
    python3 extract-colors.py /Applications/Some.app        # finds all *.car inside
    python3 extract-colors.py Some.app --filter 'border|background|text'

Requires: /usr/bin/assetutil (preinstalled on macOS).
"""
import argparse, glob, json, os, re, subprocess, sys


def find_cars(path: str) -> list[str]:
    if os.path.isfile(path) and path.endswith(".car"):
        return [path]
    if os.path.isdir(path):
        return sorted(glob.glob(os.path.join(path, "**", "*.car"), recursive=True))
    return []


def hexify(comp):
    try:
        r, g, b, a = [float(x) for x in comp]
    except (ValueError, TypeError):
        return None
    h = "#%02X%02X%02X" % (round(r * 255), round(g * 255), round(b * 255))
    if a < 0.999:
        h += " @%d%%" % round(a * 100)
    return h


def dump(car: str, filt) -> int:
    try:
        out = subprocess.run(["assetutil", "--info", car], capture_output=True, text=True, check=True).stdout
        data = json.loads(out)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
        print(f"  ! {car}: {e}", file=sys.stderr)
        return 0
    colors = [d for d in data if isinstance(d, dict) and d.get("AssetType") == "Color"]
    rows, seen = [], set()
    for d in colors:
        name = str(d.get("Name"))
        if filt and not filt.search(name):
            continue
        hexv = hexify(d.get("Color components"))
        if not hexv:
            continue
        appr = d.get("Appearance", "any")
        key = (name, appr)
        if key in seen:
            continue
        seen.add(key)
        rows.append((name, appr, hexv))
    rows.sort()
    if rows:
        print(f"\n# {car}  ({len(rows)} colors)")
        for name, appr, hexv in rows:
            print(f"  {name:38s} [{appr:24s}] {hexv}")
    return len(rows)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", help="Assets.car file or .app/.bundle directory")
    ap.add_argument("--filter", help="regex on color name (case-insensitive)")
    args = ap.parse_args()
    cars = find_cars(args.path)
    if not cars:
        print(f"No .car found at {args.path}", file=sys.stderr)
        return 1
    filt = re.compile(args.filter, re.I) if args.filter else None
    total = sum(dump(c, filt) for c in cars)
    print(f"\ntotal: {total} named colors across {len(cars)} catalog(s)")
    return 0 if total else 2


if __name__ == "__main__":
    sys.exit(main())
