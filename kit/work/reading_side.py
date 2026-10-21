#!/usr/bin/env python
"""Which ink direction is the WRITTEN side of a rendered surface? Geometry only: mesh normal vs. the scroll axis.

Papyrus was written on the side facing the scroll axis. The villa ink models read the layer stack from the side away
from the axis towards the axis: Erwin Nieuwlaar's PHerc0343 letters (VC3D render without --flip-normals, normal =
dP/dcolumn x dP/drow pointing away from the axis) are in the REVERSE map. So, per mesh, with n . outward > 0:
  rendered without --flip-normals -> reverse is the written side; with --flip-normals -> forward.
and the other way round when n . outward < 0 (the patch tracer's normal can point either way).

usage: reading_side.py UMBILICUS_JSON MESH_DIR... [--flip]   (MESH_DIR = a tifxyz folder holding x.tif, y.tif, z.tif,
       or a folder holding one, e.g. patch/auto_grown_*/). --flip = rendered with --flip-normals.
Prints: mesh, valid nodes, median n.outward, fraction > 0, written-side direction.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import tifffile


def axis_at(points, z):
    pts = sorted(points, key=lambda p: p["z"])
    zs = np.array([p["z"] for p in pts], float)
    return np.interp(z, zs, [p["x"] for p in pts]), np.interp(z, zs, [p["y"] for p in pts])


def find_mesh(d):
    d = Path(d)
    if (d / "x.tif").exists():
        return d
    hits = sorted(d.glob("patch/auto_grown_*/x.tif")) + sorted(d.glob("*/x.tif"))
    return hits[0].parent if hits else None


def outward_dot(mesh, umb):
    P = np.stack([tifffile.imread(mesh / f"{a}.tif").astype(np.float64) for a in "xyz"], -1)
    ok = np.all(np.isfinite(P), -1) & np.all(P >= 0, -1)
    dcol = np.gradient(P, axis=1)
    drow = np.gradient(P, axis=0)
    # a node counts only when its neighbours are valid too (gradients across holes are meaningless)
    okn = ok.copy()
    okn[:, 1:] &= ok[:, :-1]; okn[:, :-1] &= ok[:, 1:]; okn[1:] &= ok[:-1]; okn[:-1] &= ok[1:]
    n = np.cross(dcol, drow)[okn]
    p = P[okn]
    ax, ay = axis_at(umb, p[:, 2])
    out = np.stack([p[:, 0] - ax, p[:, 1] - ay, np.zeros(len(p))], -1)
    nn = np.linalg.norm(n, axis=1) * np.linalg.norm(out, axis=1)
    good = nn > 0
    d = (n[good] * out[good]).sum(1) / nn[good]
    return int(good.sum()), float(np.median(d)) if d.size else float("nan"), float((d > 0).mean()) if d.size else float("nan")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("umbilicus")
    ap.add_argument("meshes", nargs="+")
    ap.add_argument("--flip", action="store_true")
    a = ap.parse_args()
    u = json.load(open(a.umbilicus))
    u = u.get("control_points", u)
    for m in a.meshes:
        mesh = find_mesh(m)
        if mesh is None:
            print(f"{Path(m).name}\tno mesh")
            continue
        n, med, frac = outward_dot(mesh, u)
        outward = med > 0
        side = ("forward" if outward else "reverse") if a.flip else ("reverse" if outward else "forward")
        print(f"{Path(m).name}\t{n}\t{med:+.3f}\t{frac:.3f}\t{side}")


if __name__ == "__main__":
    main()
