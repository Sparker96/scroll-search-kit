#!/usr/bin/env python3
"""Pick the grown patches to ink so that they cover most of a box's patch cloud (COVER mode, instead of stitched
strips: the rented run's strips covered 12-30 cm2 per box of clouds of 104-372 cm2).

Coverage rule = summary.py's unique area: a node of patch B is covered by patch A if A, sampled 4x4 per grid cell
(every ~5 vx), has a point within --tol voxels. Greedy: each pick is the patch that adds the most not-yet-covered
area; picks stop once they cover --frac of the union of all patches.
--mask VOL_URL first checks every node against the scan's mask (mask_check.py: is the node's level-0 chunk stored?).
A patch with less than --min-inside of its nodes inside is left out: it would render empty. Calibrated on one box of the
rented run, whose 54 cover patches were rendered: the 24 that came out empty had at most 0.55 of their nodes in stored
chunks (stored chunks at the mask's edge are mostly zero), the 30 with data at least 0.94; 0.8 sorts all 54 right.
A second box's 94 picks, made with the check (0.81-1.00 of their nodes inside), all rendered with data.
Of the patches kept, only the nodes inside count, for the union and for each pick's new area. --drop-single first removes patches that no other patch comes within --tol of.
Writes OUT.tsv (tab-separated, in pick order): patch, pick, new_cm2, cum_pct (of the union), single_seen (1 = no other
patch within --tol), single_frac (share of its nodes no other patch sees), in_mask (share of its nodes inside the
scan's mask; 1 without --mask). With --mask, OUT.outside.tsv lists the patches left out (patch, in_mask, cm2).
Prints one summary line.
usage: cover.py PATCHES_DIR OUT.tsv [--frac 0.8] [--mask VOL_URL [--min-inside 0.8] [--read]] [--drop-single]
       [--tol 10] [--min-cm2 1.0] --vx VOXEL_UM
"""
import argparse
import os
import sys
from pathlib import Path

import numpy as np
import tifffile
from scipy.spatial import cKDTree


def grid(d):
    P = np.stack([tifffile.imread(d / f"{a}.tif") for a in "xyz"], -1).astype(np.float32)
    return P, np.all(np.isfinite(P), -1) & np.all(P > 0, -1)


def dense(P, ok, n=4):
    """Points every 1/n of a node step inside every grid cell whose 4 corners are valid (as summary.py)."""
    cell = ok[:-1, :-1] & ok[:-1, 1:] & ok[1:, :-1] & ok[1:, 1:]
    a, b, c, e = P[:-1, :-1][cell], P[:-1, 1:][cell], P[1:, :-1][cell], P[1:, 1:][cell]
    out = [(1 - fr) * ((1 - fc) * a + fc * b) + fr * ((1 - fc) * c + fc * e)
           for fr in np.arange(n) / n for fc in np.arange(n) / n]
    return np.concatenate(out) if len(a) else P[ok]


def write(path, header, rows):
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(header + "\n" + "".join(r + "\n" for r in rows))
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("patches", type=Path); ap.add_argument("out", type=Path)
    ap.add_argument("--frac", type=float, default=0.8); ap.add_argument("--drop-single", action="store_true")
    ap.add_argument("--mask", metavar="VOL_URL"); ap.add_argument("--min-inside", type=float, default=0.8)
    ap.add_argument("--read", action="store_true", help="with --mask: download stored chunks, all-zero ones = outside")
    ap.add_argument("--tol", type=float, default=10.0); ap.add_argument("--min-cm2", type=float, default=1.0)
    ap.add_argument("--vx", type=float, required=True)
    a = ap.parse_args()
    node = 400 * (a.vx * 1e-4) ** 2
    pats = []
    for d in sorted(a.patches.glob("auto_grown_*")):
        try:
            P, ok = grid(d)
        except (OSError, ValueError):
            continue
        if not ok.any() or ok.sum() * node < a.min_cm2:
            continue
        pats.append({"name": d.name, "P": P, "ok": ok, "cm2": ok.sum() * node, "in_mask": 1.0})
    outside = []
    if a.mask:
        sys.path.insert(0, str(Path(__file__).resolve().parent))   # mask_check.py sits here; python -I leaves it out
        from mask_check import Scan
        scan = Scan(a.mask, read=a.read)
        kept = []
        for p in pats:
            ins = np.zeros(p["ok"].shape, bool)
            ins[p["ok"]] = scan.inside_points(p["P"][p["ok"]])
            p["in_mask"] = ins.sum() / p["ok"].sum()
            if p["in_mask"] < a.min_inside:
                outside.append(p)
            else:
                p["ok"] = ins   # only the nodes a render fills count from here on
                kept.append(p)
        pats = kept
    for p in pats:
        p["q"] = p["P"][p["ok"]]; p["lo"] = p["q"].min(0) - a.tol; p["hi"] = p["q"].max(0) + a.tol
    n = len(pats)
    # every pair once: which of B's nodes does A cover? (bounding boxes first, so most pairs cost nothing)
    cover = [dict() for _ in range(n)]
    for i, A in enumerate(pats):
        tree = None
        for j, B in enumerate(pats):
            if j == i or np.any(B["hi"] < A["lo"]) or np.any(B["lo"] > A["hi"]):
                continue
            tree = tree or cKDTree(dense(A["P"], A["ok"]))
            dist, _ = tree.query(B["q"], k=1, distance_upper_bound=a.tol)
            idx = np.nonzero(np.isfinite(dist))[0]
            if len(idx):
                cover[i][j] = idx
    seen = [np.zeros(len(p["q"]), bool) for p in pats]
    for i in range(n):
        for j, idx in cover[i].items():
            seen[j][idx] = True
    single = np.array([not s.any() for s in seen])
    single_frac = np.array([1.0 - s.mean() for s in seen])
    use = ~single if a.drop_single else np.ones(n, bool)
    # greedy over all usable patches (the union is what they cover in the end), then keep picks up to --frac of it
    covered = [np.zeros(len(p["q"]), bool) for p in pats]
    picked = np.zeros(n, bool)
    picks, gains = [], []
    while True:
        new = np.array([(~covered[k]).sum() if use[k] and not picked[k] else -1 for k in range(n)])
        k = int(new.argmax()) if n else 0
        if n == 0 or new[k] <= 0:
            break
        picked[k] = True; picks.append(k); gains.append(new[k] * node)
        covered[k][:] = True
        for j, idx in cover[k].items():
            covered[j][idx] = True
    union = float(sum(gains))
    cum = np.cumsum(gains) if gains else np.zeros(0)
    m = int(np.searchsorted(cum, a.frac * union - 1e-9) + 1) if gains else 0
    m = min(m, len(picks))
    write(a.out, "patch\tpick\tnew_cm2\tcum_pct\tsingle_seen\tsingle_frac\tin_mask",
          [f"{pats[k]['name']}\t{r + 1}\t{gains[r]:.2f}\t{100 * cum[r] / union:.1f}\t{int(single[k])}\t"
           f"{single_frac[k]:.2f}\t{pats[k]['in_mask']:.2f}" for r, k in enumerate(picks[:m])])
    if a.mask:
        write(a.out.with_name(a.out.stem + ".outside.tsv"), "patch\tin_mask\tcm2",
              [f"{p['name']}\t{p['in_mask']:.2f}\t{p['cm2']:.2f}" for p in outside])
    summed = sum(pats[k]["cm2"] for k in picks[:m])   # whole patches: a render covers the nodes outside too
    left = (f"{len(outside)} outside the scan mask left out (< {a.min_inside:g} of their nodes inside, "
            f"{sum(p['cm2'] for p in outside):.1f} cm2), " if a.mask else "")
    print(f"{n + len(outside)} patches >= {a.min_cm2:g} cm2, {left}{int(single.sum())} isolated"
          f"{' (dropped)' if a.drop_single else ''}; union {union:.1f} cm2{' inside the mask' if a.mask else ''}; "
          f"{m} picked = {summed:.1f} cm2 to ink for {100 * (cum[m - 1] / union if m else 0):.0f} % of the union")


if __name__ == "__main__":
    main()
