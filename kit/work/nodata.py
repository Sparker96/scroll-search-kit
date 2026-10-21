#!/usr/bin/env python3
"""Set an ink map to 0 wherever the model's input had no data.

A strip's render is a rectangle, and much of it can be empty: invalid mesh nodes render as 0 in every layer, and so
does the scan outside its mask. The model still writes something there, wherever an inference tile also held some
data: Reader v2 a flat low value (~0.24 on the public control, with straight steps at the tile edges), Reader V3 faint
lines and a regular comb of strokes that look like writing. For each map PREFIX_s<S>[_reverse].tif in DIR (layers
S .. S+DEPTH-1 of the render ZARR, in either reading direction), every pixel where all of those layers are 0 is set
to 0. With --margin PX, so is every pixel within PX pixels of one (a square neighbourhood).
A map is replaced (atomically) only if something changes, so running this again changes nothing.
Writes DIR/nodata_PREFIX.tsv, one line per map: its layers; the empty pixels and their share of the map; how many of
them were not 0 and the largest such value (what the model wrote where it saw no data); the margin, and how many
non-zero pixels it removed. Exit 0 = done; 1 = no maps, or a map that does not match the render.
usage: nodata.py DIR ZARR PREFIX DEPTH [--margin PX]
"""
import argparse
import os
import re
import sys
from pathlib import Path

import numpy as np
import tifffile
import zarr


def grow(b, r):
    """b with every pixel within r pixels (square neighbourhood) of a True pixel set True."""
    out = b.copy()
    for k in range(1, r + 1):
        out[k:] |= b[:-k]
        out[:-k] |= b[k:]
    rows = out.copy()
    for k in range(1, r + 1):
        out[:, k:] |= rows[:, :-k]
        out[:, :-k] |= rows[:, k:]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir", type=Path); ap.add_argument("zarr"); ap.add_argument("prefix"); ap.add_argument("depth", type=int)
    ap.add_argument("--margin", type=int, default=0)
    a = ap.parse_args()
    pat = re.compile(rf"{re.escape(a.prefix)}_s(\d+)(_reverse)?\.tif")
    maps = sorted((p, int(m.group(1))) for p in a.dir.iterdir() if (m := pat.fullmatch(p.name)))
    if not maps:
        print("no maps"); sys.exit(1)
    g = zarr.open(a.zarr, mode="r")
    v = g["0"] if hasattr(g, "keys") and "0" in g else g
    nl, h, w = v.shape
    starts = sorted({s for _, s in maps})
    if len(starts) > 64:
        print(f"{len(starts)} windows: at most 64 supported"); sys.exit(1)
    bit = {s: i for i, s in enumerate(starts)}
    dt = np.uint16 if len(starts) <= 16 else np.uint32 if len(starts) <= 32 else np.uint64
    # bit i of has[y, x] = window i has data at that pixel. The render is read in slabs of whole chunk rows (all
    # layers), so memory stays near one slab plus 2-8 bytes per pixel.
    has = np.zeros((h, w), dt)
    step = max(1, int(v.chunks[1]))
    for y0 in range(0, h, step):
        nz = np.asarray(v[:, y0:y0 + step]) != 0
        hs = has[y0:y0 + step]
        for s, i in bit.items():
            lo, hi = min(max(s, 0), nl), min(s + a.depth, nl)   # the layers the model read, clamped like villa's
            np.bitwise_or(hs, dt(1 << i), out=hs, where=nz[lo:hi].any(axis=0))
    rows = []
    for p, s in maps:
        with tifffile.TiffFile(p) as tf:
            pg = tf.pages[0]
            m = pg.asarray()
            tile = (pg.tilelength, pg.tilewidth) if pg.is_tiled else None   # keep villa's layout where TIFF allows it
            if tile and (tile[0] % 16 or tile[1] % 16):
                tile = None
        if m.shape != (h, w):
            print(f"{p.name}: shape {m.shape} but the render is {(h, w)}"); sys.exit(1)
        empty = (has & dt(1 << bit[s])) == 0
        gone = m[empty]
        removed = int(np.count_nonzero(gone)); top = int(gone.max()) if removed else 0
        changed = removed > 0
        m[empty] = 0
        margin_removed = 0
        if a.margin > 0:
            ring = grow(empty, a.margin) & ~empty
            margin_removed = int(np.count_nonzero(m[ring]))
            if margin_removed:
                m[ring] = 0; changed = True
        if changed:
            tmp = p.with_name(f".{p.name}.nodata-tmp")
            tifffile.imwrite(tmp, m, compression="lzw", tile=tile, bigtiff=True, software="scroll-search-kit nodata.py")
            os.replace(tmp, p)
        n_empty = int(empty.sum())
        rows.append(f"{p.name}\t{s}-{min(s + a.depth, nl) - 1}\t{n_empty}\t{100 * n_empty / m.size:.2f}\t{removed}\t{top}"
                    f"\t{a.margin}\t{margin_removed}")
    out = a.dir / f"nodata_{a.prefix}.tsv"
    tmp = out.with_name(f".{out.name}.tmp")
    tmp.write_text("map\tlayers\tempty_px\tempty_pct\tremoved_px\tremoved_max\tmargin_px\tmargin_removed_px\n"
                   + "\n".join(rows) + "\n")
    os.replace(tmp, out)
    print(f"{len(maps)} maps: {sum(int(r.split(chr(9))[4]) for r in rows)} non-zero pixels in no-data areas set to 0")


if __name__ == "__main__":
    main()
