#!/usr/bin/env python3
"""For run_fake.sh's nodata scenario: in every strip of RUN, is each PREFIX map 0 wherever its input layers (S ..
S+DEPTH-1 of the strip's render) are all 0, and equal to what the stand-in ink wrote everywhere else (layer S // 2)?
Prints: maps checked, maps that fail, and the non-zero pixels the nodata_PREFIX.tsv files say were removed.
usage: nodata_verify.py RUN PREFIX DEPTH"""
import sys
from pathlib import Path

import numpy as np
import tifffile
import zarr

run, prefix, depth = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
maps = bad = removed = 0
for z in run.glob("band_*/box_*/render/*/*_61.zarr"):
    d = z.parent
    v = np.asarray(zarr.open_group(str(z), mode="r")["0"][:])
    for p in d.glob(f"{prefix}_s*.tif"):
        s = int(p.stem.split("_s")[1].split("_")[0])
        m = tifffile.imread(p)
        empty = ~v[s:s + depth].any(axis=0)
        raw = (v[min(s, len(v) - 1)] // 2).astype(np.uint8)
        bad += int(m[empty].any() or not np.array_equal(m[~empty], raw[~empty]))
        maps += 1
    t = d / f"nodata_{prefix}.tsv"
    if t.exists():
        removed += sum(int(line.split("\t")[4]) for line in t.read_text().splitlines()[1:])
print(maps, bad, removed)
