#!/usr/bin/env python3
"""Pixel-compare reminder-card snapshots rendered at the base and head revisions.

usage: compare-snapshots.py <base-dir> <head-dir> <out-dir>
Writes <out-dir>/report.md and a side-by-side before|after PNG per card (plus a diff mask when
pixels differ). Exits 1 if any card differs or is missing on either side.
"""
import os
import sys

from PIL import Image, ImageChops


def main(base, head, out):
    os.makedirs(out, exist_ok=True)
    names = sorted(n for n in set(os.listdir(base)) | set(os.listdir(head)) if n.endswith(".png"))
    rows, failed = [], False
    for n in names:
        b, h = os.path.join(base, n), os.path.join(head, n)
        if not (os.path.exists(b) and os.path.exists(h)):
            rows.append(f"| {n} | missing on {'head' if os.path.exists(b) else 'base'} |")
            failed = True
            continue
        ib, ih = Image.open(b).convert("RGBA"), Image.open(h).convert("RGBA")
        if ib.size != ih.size:
            rows.append(f"| {n} | size {ib.size} vs {ih.size} |")
            failed = True
            continue
        diff = ImageChops.difference(ib, ih)
        changed = sum(1 for p in diff.getdata() if any(p))
        side = Image.new("RGBA", (ib.width * 2 + 20, ib.height), (0, 0, 0, 0))
        side.paste(ib, (0, 0))
        side.paste(ih, (ib.width + 20, 0))
        side.save(os.path.join(out, n.replace(".png", "-before-after.png")))
        if changed:
            diff.point(lambda v: 255 if v else 0).save(os.path.join(out, n.replace(".png", "-diff.png")))
            failed = True
        rows.append(f"| {n} | {'identical' if not changed else f'{changed} pixels differ'} |")
    with open(os.path.join(out, "report.md"), "w") as f:
        f.write("| card | result |\n|---|---|\n" + "\n".join(rows) + "\n")
    print("\n".join(rows))
    return 1 if failed or not names else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:4]))
