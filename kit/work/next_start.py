#!/usr/bin/env python3
"""Pick the start patch for the next stitched trace: the largest grown patch that the traces made so far do not cover.

A box is covered with several stitched strips (vc_grow_seg_from_segments), each started from one patch. A patch counts as
covered when more than --max-covered of its nodes lie within --tol voxels of a node of an existing trace (a patch on
the next sheet out sits ~20 vx away, so it stays uncovered and can start its own trace).
A trace does not cover all of its own start patch (it follows the consensus of the other patches and its z range), so
earlier start patches are excluded by name (--exclude FILE, one folder name or path per line).
--by overlaps ranks by the number of overlapping patches (overlapping.json) instead of area: the stitcher only grows
from points that several patches agree on (in our tests the largest patch stalled, the most-overlapped one grew). It
also puts later strips next to earlier ones (each added less new area in the rented run).
--by spread: among uncovered patches whose overlap count is at least the median of all the box's patches, the one
farthest from every earlier trace (ties: more overlaps); the first strip as --by overlaps.
--first SEEDS_TSV (name x y z rows): before any rule, the patch grown at one of these seed points (its meta.json
"seed", in file order), while one is left that is not excluded, is at least --min-area and is not covered: strips then
start where the config asked for them (e.g. at known letters, a positive control).
--list-first (with --first): pick nothing; print one line per seed point, in file order: name, state, patch. state =
reached (a TRACE_DIR comes within --tol voxels of the point), ink (not reached: patch = the patch grown there, which
box.sh then inks as it is) or nopatch (no patch of at least --min-area grew there); patch is - unless state is ink.
usage: next_start.py PATCHES_DIR [TRACE_DIR...] [--tol 8] [--max-covered 0.2] [--min-area 0.5] [--exclude FILE]
       [--by area|overlaps|spread] [--first SEEDS_TSV [--list-first]]
  PATCHES_DIR holds auto_grown_*/ (tifxyz + meta.json with area_cm2); TRACE_DIRs are tifxyz folders.
Prints the chosen patch folder, or nothing if every patch of at least --min-area cm2 is covered.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import tifffile
from scipy.spatial import cKDTree


def grid(d):
    P = np.stack([tifffile.imread(Path(d) / f"{a}.tif") for a in "xyz"], -1).astype(np.float32)
    return P, np.all(np.isfinite(P), -1) & np.all(P > 0, -1)


def nodes(d, every=1):
    P, ok = grid(d)
    return P[::every, ::every][ok[::every, ::every]]


def dense(d, n=4):
    """Points every 1/n of a node step inside every grid cell whose 4 corners are valid (nodes are ~20 vx apart, so
    node-to-node distances alone cannot tell 'same sheet' from 'next sheet')."""
    P, ok = grid(d)
    cell = ok[:-1, :-1] & ok[:-1, 1:] & ok[1:, :-1] & ok[1:, 1:]
    a, b, c, e = P[:-1, :-1][cell], P[:-1, 1:][cell], P[1:, :-1][cell], P[1:, 1:][cell]
    out = []
    for fr in np.arange(n) / n:
        for fc in np.arange(n) / n:
            out.append((1 - fr) * ((1 - fc) * a + fc * b) + fr * ((1 - fc) * c + fc * e))
    return np.concatenate(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("patches"); ap.add_argument("traces", nargs="*")
    ap.add_argument("--tol", type=float, default=8); ap.add_argument("--max-covered", type=float, default=0.2)
    ap.add_argument("--min-area", type=float, default=0.5); ap.add_argument("--exclude")
    ap.add_argument("--by", choices=("area", "overlaps", "spread"), default="area")
    ap.add_argument("--first", help="tsv of name x y z seed points whose patches start strips first")
    ap.add_argument("--list-first", action="store_true", help="list the --first points' states instead of picking")
    a = ap.parse_args()
    skip = set()
    if a.exclude and Path(a.exclude).exists():
        skip = {Path(l.strip()).name for l in Path(a.exclude).read_text().splitlines() if l.strip()}
    cands, grown_at = [], {}
    for p in Path(a.patches).glob("auto_grown_*"):
        try:
            meta = json.loads((p / "meta.json").read_text())
            area = float(meta.get("area_cm2", 0))
        except (OSError, ValueError):
            continue
        if area >= a.min_area and (p / "x.tif").exists() and p.name not in skip:
            if isinstance(meta.get("seed"), list) and len(meta["seed"]) >= 3:
                grown_at.setdefault(tuple(round(float(v)) for v in meta["seed"][:3]), p)
            key = area
            if a.by in ("overlaps", "spread"):
                try:
                    key = len(json.loads((p / "overlapping.json").read_text()).get("overlapping", []))
                except (OSError, ValueError):
                    key = 0
            cands.append((key, p))
    cands.sort(key=lambda t: (-t[0], t[1].name))
    trace_pts = [dense(t) for t in a.traces if (Path(t) / "x.tif").exists()]
    tree = cKDTree(np.concatenate(trace_pts)) if trace_pts else None

    def uncovered(p):
        if tree is None:
            return True
        q = nodes(p, every=2)
        if len(q) == 0:
            return False
        dist, _ = tree.query(q, k=1, distance_upper_bound=a.tol)
        return np.mean(np.isfinite(dist)) <= a.max_covered

    if a.list_first:
        for line in Path(a.first).read_text().splitlines() if a.first and Path(a.first).exists() else []:
            f = line.split("\t")
            try:
                pt = [float(v) for v in f[1:4]] if len(f) >= 4 else None
            except ValueError:
                continue
            if pt is None:
                continue
            p = grown_at.get(tuple(round(v) for v in pt))
            if tree is not None and np.isfinite(tree.query(pt, k=1, distance_upper_bound=a.tol)[0]):
                print(f"{f[0]}\treached\t-")
            else:
                print(f"{f[0]}\tink\t{p}" if p is not None else f"{f[0]}\tnopatch\t-")
        return
    if a.first and Path(a.first).exists():
        for line in Path(a.first).read_text().splitlines():
            f = line.split("\t")
            try:
                p = grown_at.get(tuple(round(float(v)) for v in f[1:4])) if len(f) >= 4 else None
            except ValueError:
                continue
            if p is not None and uncovered(p):
                print(p); return
    if a.by == "spread" and tree is not None and cands:
        floor = float(np.median([k for k, _ in cands]))
        best = None
        for key, p in cands:
            if key < floor:
                break   # sorted by overlaps: the rest are below the median too
            q = nodes(p, every=2)
            if len(q) == 0:
                continue
            dist, _ = tree.query(q, k=1)
            if np.mean(dist <= a.tol) > a.max_covered:
                continue
            far = float(np.min(dist))   # how far the patch stays from every earlier trace
            if best is None or (far, key) > (best[0], best[1]):
                best = (far, key, p)
        if best is not None:
            print(best[2])
        return
    for _, p in cands:
        if uncovered(p):
            print(p); return


if __name__ == "__main__":
    main()
