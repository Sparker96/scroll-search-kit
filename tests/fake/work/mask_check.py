#!/usr/bin/env python3
"""Fake mask_check.py: seeds whose name ends in 'out' are outside; traces matching FAKE_OUTSIDE are outside; Scan (which
cover.py imports): points above z = FAKE_MASK_ZMAX are outside (none without it)."""
import os, re, sys
import numpy as np


class Scan:
    def __init__(self, url, read=False):
        self.zmax = float(os.environ.get("FAKE_MASK_ZMAX", "inf"))

    def inside_points(self, pts, threads=16):
        return np.asarray(pts, np.float64)[:, 2] <= self.zmax


def main():
    mode, vol, src = sys.argv[1:4]
    if mode == "seeds":
        rows = [l for l in open(src) if l.strip()]
        keep = [l for l in rows if not l.split("\t")[0].endswith("out")]
        open(sys.argv[4], "w").writelines(keep)
        print(f"{len(rows) - len(keep)} of {len(rows)} seeds dropped (scan chunk missing or empty), {len(keep)} kept")
    else:
        pat = os.environ.get("FAKE_OUTSIDE")
        if pat and re.search(pat, src):
            print("OUTSIDE-MASK 0 of 20 sampled nodes inside the scan mask"); sys.exit(3)
        print("inside: 20 of 20 sampled nodes")


if __name__ == "__main__":
    main()
