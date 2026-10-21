#!/usr/bin/env python3
"""Summarise a search run: strips and cm² per state, time per phase, throughput. Writes RUN/summary.json too.

Reads RUN/queue/*/*.job (each strip's trace), RUN/band_z*/box_*/timing.tsv (seconds per phase), RUN/times.txt,
RUN/metrics.tsv and the boxes' seeds_extra.ink.tsv (SEEDS_EXTRA points: reached, inked as their own patch, no patch;
each point counted once, although overlapping boxes may both list it). Strip area = valid tifxyz nodes x 400 voxel² per
node (grid every 20 voxels) x voxel area.
Strips overlap (neighbouring boxes, several strips per box), so the summed area overstates what was searched. UNIQUE
area counts a node only if no earlier strip (in path order) has a point within --unique-tol voxels of it [10]; earlier
strips are sampled 4x4 per grid cell (every ~5 voxels). The headline number is the unique area.
usage: summary.py RUN [--voxel-um 9.362] [--unique-tol 10]   (voxel size: from the environment or the run's config)
"""
import argparse
import json
import os
import re
from collections import defaultdict
from pathlib import Path

import numpy as np
import tifffile
from scipy.spatial import cKDTree


def voxel_um(run, given):
    if given:
        return given
    if os.environ.get("VOXEL_UM"):
        return float(os.environ["VOXEL_UM"])
    try:
        cfg = Path((run / "config.path").read_text().strip()).read_text()
        m = re.findall(r"^\s*VOXEL_UM=([0-9.]+)", cfg, re.M)
        if m:
            return float(m[-1])
    except OSError:
        pass
    raise SystemExit("voxel size unknown: pass --voxel-um")


def area_cm2(trace, vx):
    try:
        x = tifffile.imread(Path(trace) / "x.tif")
    except (OSError, ValueError):
        return 0.0
    return float((x > 0).sum()) * 400 * (vx * 1e-4) ** 2


def _grid(d):
    P = np.stack([tifffile.imread(Path(d) / f"{a}.tif") for a in "xyz"], -1).astype(np.float32)
    return P, np.isfinite(P).all(-1) & (P[..., 0] > 0)


def _dense(P, ok, n=4):
    cell = ok[:-1, :-1] & ok[:-1, 1:] & ok[1:, :-1] & ok[1:, 1:]
    a, b, c, e = P[:-1, :-1][cell], P[:-1, 1:][cell], P[1:, :-1][cell], P[1:, 1:][cell]
    pts = [(1 - fr) * ((1 - fc) * a + fc * b) + fr * ((1 - fc) * c + fc * e)
           for fr in np.arange(n) / n for fc in np.arange(n) / n]
    return np.concatenate(pts) if len(a) else P[ok]


def unique_areas(traces, vx, tol=10.0):
    """[(summed_cm2, unique_cm2)] per trace, in the given order: a node is new unless an earlier trace has a point
    within tol voxels of it."""
    node = 400 * (vx * 1e-4) ** 2
    done, out = [], []
    for d in traces:
        try:
            P, ok = _grid(d)
        except (OSError, ValueError):
            out.append((0.0, 0.0))
            continue
        q = P[ok]
        if len(q) == 0:
            out.append((0.0, 0.0))
            continue
        lo, hi = q.min(0) - tol, q.max(0) + tol
        covered = np.zeros(len(q), bool)
        for blo, bhi, tree in done:
            if np.any(hi < blo) or np.any(lo > bhi):
                continue
            dist, _ = tree.query(q, k=1, distance_upper_bound=tol)
            covered |= np.isfinite(dist)
        out.append((len(q) * node, float((~covered).sum()) * node))
        pts = _dense(P, ok)
        done.append((pts.min(0), pts.max(0), cKDTree(pts)))
    return out


def wall_hours(run):
    """Wall-clock hours from run.sh's start/end lines (times.txt). A segment without an end (a run killed hard) ends
    at the last metrics line before the next start, or at the last metrics line overall if it is the last segment."""
    m = run / "metrics.tsv"
    ts = []
    if m.exists():
        ts = sorted(float(l.split("\t")[0]) for l in m.read_text().splitlines() if l.split("\t")[0].isdigit())
    t = run / "times.txt"
    if not t.exists():
        return None
    events = []
    for line in t.read_text().splitlines():
        kind, _, v = line.partition(" ")
        if kind in ("start", "end") and v.strip().isdigit():
            events.append((kind, float(v)))
    total = 0.0
    for i, (kind, t0) in enumerate(events):
        if kind != "start":
            continue
        nxt = next((e for e in events[i + 1:]), None)
        if nxt and nxt[0] == "end":
            total += nxt[1] - t0
        else:
            limit = nxt[1] if nxt else float("inf")
            before = [x for x in ts if t0 <= x < limit]
            if before:
                total += before[-1] - t0
    return total / 3600 if total > 0 else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", type=Path)
    ap.add_argument("--voxel-um", type=float)
    ap.add_argument("--unique-tol", type=float, default=10.0)
    a = ap.parse_args()
    vx = voxel_um(a.run, a.voxel_um)
    states = defaultdict(lambda: [0, 0.0])
    done_traces = []
    for jf in sorted(a.run.glob("queue/*/*.job*")):
        st = jf.parent.name
        if st == "tmp":
            continue
        kv = dict(l.split("=", 1) for l in jf.read_text().splitlines() if "=" in l)
        cm = area_cm2(kv.get("TRACE", ""), vx)
        states[st][0] += 1
        states[st][1] += cm
        if st == "done":
            done_traces.append(kv.get("TRACE", ""))
    # strips MIN_NEW set aside (kept, not inked): traces/t*/.setaside says "new P % = N of C cm2"
    for m in sorted(a.run.glob("band_z*/box_*/traces/t*/.setaside")):
        mm = re.search(r"of ([0-9.]+) cm2", m.read_text())
        states["setaside"][0] += 1
        states["setaside"][1] += float(mm.group(1)) if mm else 0.0
    # COVER mode: patches left out as outside the scan's mask, never rendered (box_*/cover.outside.tsv: patch in_mask cm2)
    for f in sorted(a.run.glob("band_z*/box_*/cover.outside.tsv")):
        for line in f.read_text().splitlines()[1:]:
            parts = line.split("\t")
            if len(parts) >= 3:
                states["masked"][0] += 1
                states["masked"][1] += float(parts[2])
    # SEEDS_EXTRA points (box_*/seeds_extra.ink.tsv: name, reached|ink|nopatch, patch; box.sh). Boxes overlap, so a
    # point can be listed by several boxes: it counts once, as inked if any box inked its patch, else as reached if any
    # box's inked strips reached it, else as a point where no patch grew (in every box that holds it)
    rank = {"ink": 0, "reached": 1, "nopatch": 2}
    point, held = {}, defaultdict(list)
    for f in sorted(a.run.glob("band_z*/box_*/seeds_extra.ink.tsv")):
        for line in f.read_text().splitlines():
            parts = line.split("\t")
            if len(parts) >= 2 and parts[1] in rank:
                if parts[0] not in point or rank[parts[1]] < rank[point[parts[0]]]:
                    point[parts[0]] = parts[1]
                held[parts[0]].append(f"{f.parent.parent.name}/{f.parent.name}")
    seeds = {k: sum(v == k for v in point.values()) for k in rank} if point else None
    uniq = unique_areas(sorted(done_traces), vx, a.unique_tol)
    unique_cm2 = sum(u for _, u in uniq)
    phases = defaultdict(lambda: [0, 0])
    for t in a.run.glob("band_z*/box_*/timing.tsv"):
        for line in t.read_text().splitlines()[1:]:
            f = line.split("\t")
            if len(f) >= 2 and f[1].isdigit():
                phases[f[0]][0] += 1
                phases[f[0]][1] += int(f[1])
    wall_h = wall_hours(a.run)
    done_cm2 = states["done"][1]
    out = {
        "voxel_um": vx,
        "searched_unique_cm2": round(unique_cm2, 1),
        "unique_definition": f"nodes with no earlier strip point within {a.unique_tol:g} voxels",
        "strips": {k: {"n": v[0], "cm2": round(v[1], 1)} for k, v in sorted(states.items())},
        "phase_seconds": {k: {"n": v[0], "s": v[1]} for k, v in sorted(phases.items())},
        "seed_points": {k: seeds[k] for k in ("reached", "ink", "nopatch")} if seeds else None,
        "wall_hours": round(wall_h, 4) if wall_h else None,
        "searched_cm2_per_hour": round(unique_cm2 / wall_h, 1) if wall_h else None,
        "warnings": ([re.sub(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ", "", l)
                      for l in (a.run / "alerts.log").read_text().splitlines() if "WARNING" in l]
                     if (a.run / "alerts.log").exists() else [])
                    + [f"WARNING: seed point {n}: no patch grew there ({', '.join(held[n])})"
                       for n, v in point.items() if v == "nopatch"],
    }
    (a.run / "summary.json").write_text(json.dumps(out, indent=2) + "\n")
    print(f"run {a.run.name}: voxel {vx} um")
    for k, v in out["strips"].items():
        print(f"  strips {k:8s} {v['n']:6d}  {v['cm2']:10.1f} cm2")
    for k, v in out["phase_seconds"].items():
        print(f"  phase  {k:8s} {v['n']:6d} x  {v['s'] / 3600:8.2f} h summed")
    print(f"  searched {unique_cm2:.1f} cm2 UNIQUE ({done_cm2:.1f} cm2 summed over strips; overlap within "
          f"{a.unique_tol:g} voxels counted once)")
    if wall_h:
        print(f"  in {wall_h:.2f} h wall clock = {out['searched_cm2_per_hour']} unique cm2/h")
    if seeds:
        print(f"  seed points (SEEDS_EXTRA, each counted once): {seeds['reached']} reached by what was inked, "
              f"{seeds['ink']} inked as their own patch, {seeds['nopatch']} where no patch grew")
    for w in out["warnings"]:
        print(f"  {w}")


if __name__ == "__main__":
    main()
