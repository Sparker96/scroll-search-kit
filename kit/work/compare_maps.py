#!/usr/bin/env python3
"""Compare ink maps with reference maps of the same names (the same-answer check).

For every map in REF_DIR (every *.tif, or those matching --glob, e.g. one model's rv3_s*.tif): is the same file in NEW_DIR byte-identical, and how well does it correlate (Pearson r over
all pixels)? Prints one tab-separated line per map and a last line PASS or FAIL. PASS = every reference map exists in
NEW_DIR with the same shape and r >= --min-r (identical files always pass).
usage: compare_maps.py REF_DIR NEW_DIR [--glob 'rv3_s*.tif'] [--min-r 0.99]
"""
import argparse
import hashlib
import sys
from pathlib import Path

import numpy as np
import tifffile


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ref", type=Path)
    ap.add_argument("new", type=Path)
    ap.add_argument("--min-r", type=float, default=0.99)
    ap.add_argument("--glob", default="*.tif")
    a = ap.parse_args()
    refs = sorted(a.ref.glob(a.glob))
    if not refs:
        print(f"FAIL no reference maps {a.glob} in {a.ref}")
        sys.exit(1)
    ok = True
    print("map\tidentical\tr\tmax_abs_diff")
    for rp in refs:
        npth = a.new / rp.name
        if not npth.exists():
            print(f"{rp.name}\tmissing\t\t")
            ok = False
            continue
        if sha(rp) == sha(npth):
            print(f"{rp.name}\tyes\t1.00000\t0")
            continue
        r_, n_ = tifffile.imread(rp).astype(np.float64), tifffile.imread(npth).astype(np.float64)
        if r_.shape != n_.shape:
            print(f"{rp.name}\tshape {n_.shape} vs {r_.shape}\t\t")
            ok = False
            continue
        if r_.std() == 0 or n_.std() == 0:
            r = 1.0 if np.array_equal(r_, n_) else 0.0
        else:
            r = float(np.corrcoef(r_.ravel(), n_.ravel())[0, 1])
        print(f"{rp.name}\tno\t{r:.5f}\t{np.abs(r_ - n_).max():.0f}")
        ok &= r >= a.min_r
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
