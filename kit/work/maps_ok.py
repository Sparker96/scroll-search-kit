#!/usr/bin/env python3
"""Are a strip's ink maps real? Every PREFIX_s*.tif in DIR must read as an image with finite values, and they must not
all be zero (an all-zero set from a render that had papyrus in it means the ink step went wrong, not that the papyrus
is blank). Exit 0 = fine; 1 = unreadable, non-finite or all zero (reason printed).
usage: maps_ok.py DIR PREFIX
"""
import sys
from pathlib import Path

import numpy as np
import tifffile


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    d, prefix = Path(sys.argv[1]), sys.argv[2]
    maps = sorted(d.glob(f"{prefix}_s*.tif"))
    if not maps:
        print("no maps"); sys.exit(1)
    nonzero = False
    for m in maps:
        try:
            a = tifffile.imread(m)
        except Exception as e:
            print(f"{m.name}: unreadable ({e.__class__.__name__})"); sys.exit(1)
        if a.size == 0 or (np.issubdtype(a.dtype, np.floating) and not np.isfinite(a).all()):
            print(f"{m.name}: empty or non-finite"); sys.exit(1)
        nonzero |= bool(np.any(a))
    if not nonzero:
        print(f"all {len(maps)} maps are zero"); sys.exit(1)
    print(f"{len(maps)} maps ok")


if __name__ == "__main__":
    main()
