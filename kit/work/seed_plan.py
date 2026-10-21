#!/usr/bin/env python3
"""Plan seed points for growing surface patches across a scroll: rings around the scroll axis at chosen heights.

For each height z: the axis point (umbilicus control points, linearly interpolated), the outer edge of the predicted
papyrus along N rays (last predicted-surface pixel on the 8x-downsampled prediction, level 3), and a point at each
fraction of that radius; every point is then moved to the nearest predicted-surface voxel at full resolution
(level 0, within 40 voxels). Writes OUT.tsv: name, x, y, z, ray angle (deg), radius fraction, radius (vx), moved (vx).

usage: seed_plan.py PRED_URL UMBILICUS_JSON OUT.tsv --z 9216 9648 --rays 8 --fracs 0.3 0.55 0.8 [--prefix s]
       seed_plan.py PRED_URL - OUT.tsv --points IN.tsv   (IN.tsv: name, x, y, z per line; each point is only moved to
       the nearest predicted-surface voxel; angle, fraction and radius are written as -1)
"""
import argparse
import json
import math
import time
import urllib.request

import numcodecs
import numpy as np


def get(url):
    for t in range(4):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (403, 404):
                return None
        except Exception:
            pass
        time.sleep(min(30, 2 ** t))   # pause before the next try
    raise RuntimeError(f"failed: {url}")


class Level:
    def __init__(self, url, level, keep=True):
        self.url = f"{url}/{level}"
        self.keep = keep
        m = json.loads(get(self.url + "/.zarray"))
        self.shape, self.chunks = m["shape"], m["chunks"]
        self.codec = numcodecs.get_codec(m["compressor"])
        self.cache = {}

    def chunk(self, iz, iy, ix):
        k = (iz, iy, ix)
        if k in self.cache:
            return self.cache[k]
        raw = get(f"{self.url}/{iz}/{iy}/{ix}")
        cz, cy, cx = self.chunks
        c = (np.zeros((cz, cy, cx), np.uint8) if raw is None
             else np.frombuffer(self.codec.decode(raw), np.uint8).reshape(cz, cy, cx))
        if self.keep:
            self.cache[k] = c
        return c

    def plane(self, z):
        cz, cy, cx = self.chunks
        Z, Y, X = self.shape
        out = np.zeros((Y, X), np.uint8)
        for iy in range(math.ceil(Y / cy)):
            for ix in range(math.ceil(X / cx)):
                c = self.chunk(z // cz, iy, ix)[z % cz]
                h, w = min(cy, Y - iy * cy), min(cx, X - ix * cx)
                out[iy * cy:iy * cy + h, ix * cx:ix * cx + w] = c[:h, :w]
        return out

    def nearest(self, x, y, z, reach=24):
        cz, cy, cx = self.chunks
        keys = {((z + a) // cz, (y + b) // cy, (x + c) // cx) for a in (-reach, reach) for b in (-reach, reach) for c in (-reach, reach)}
        best = (1e9, None)
        for iz, iy, ix in sorted(keys):
            if min(iz, iy, ix) < 0:
                continue
            p = np.argwhere(self.chunk(iz, iy, ix) >= 128)
            if len(p):
                p = p + np.array([iz * cz, iy * cy, ix * cx])
                d = np.linalg.norm(p - np.array([z, y, x]), axis=1)
                j = d.argmin()
                if d[j] < best[0]:
                    best = (float(d[j]), p[j])
        return best


def axis_at(points, z):
    pts = sorted(points, key=lambda p: p["z"])
    zs = np.array([p["z"] for p in pts], float)
    return float(np.interp(z, zs, [p["x"] for p in pts])), float(np.interp(z, zs, [p["y"] for p in pts]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pred")
    ap.add_argument("umbilicus")
    ap.add_argument("out")
    ap.add_argument("--z", type=int, nargs="+")
    ap.add_argument("--points")
    ap.add_argument("--rays", type=int, default=8)
    ap.add_argument("--fracs", type=float, nargs="+", default=[0.3, 0.55, 0.8])
    ap.add_argument("--prefix", default="s")
    a = ap.parse_args()
    if a.points:
        l0 = Level(a.pred, 0, keep=False)
        rows = []
        for line in open(a.points):
            name, x, y, z = line.split()[:4]
            d, p = l0.nearest(int(x), int(y), int(z))
            if p is None or d > 40:
                print(f"{name}: no predicted surface within 40 vx")
                continue
            rows.append((name, int(p[2]), int(p[1]), int(p[0]), -1, -1, -1, round(d, 1)))
        with open(a.out, "w") as fh:
            for r in rows:
                fh.write("\t".join(map(str, r)) + "\n")
        print(f"{len(rows)} seeds -> {a.out}")
        return
    if not a.z:
        ap.error("--z or --points is required")
    u = json.load(open(a.umbilicus))
    u = u.get("control_points", u)
    l3, l0 = Level(a.pred, 3), Level(a.pred, 0, keep=False)
    rows = []
    for z in a.z:
        n0 = len(rows)
        ux, uy = axis_at(u, z)
        img = l3.plane(z // 8) > 0
        for k in range(a.rays):
            t = 2 * math.pi * k / a.rays
            dx, dy = math.cos(t), math.sin(t)
            rmax = 0
            for r in range(1, 2000):
                px, py = int(round((ux + 8 * r * dx) / 8)), int(round((uy + 8 * r * dy) / 8))
                if not (0 <= px < img.shape[1] and 0 <= py < img.shape[0]):
                    break
                if img[py, px]:
                    rmax = 8 * r
            if rmax < 400:
                continue
            for f in a.fracs:
                x, y = int(round(ux + f * rmax * dx)), int(round(uy + f * rmax * dy))
                d, p = l0.nearest(x, y, z)
                if p is None or d > 40:
                    continue
                name = f"{a.prefix}z{z}a{int(round(math.degrees(t))):03d}f{int(round(100 * f)):02d}"
                rows.append((name, int(p[2]), int(p[1]), int(p[0]), round(math.degrees(t)), f, rmax, round(d, 1)))
        print(f"z {z}: axis ({ux:.0f}, {uy:.0f}), {len(rows) - n0} seeds", flush=True)
    with open(a.out, "w") as fh:
        for r in rows:
            fh.write("\t".join(map(str, r)) + "\n")
    print(f"{len(rows)} seeds -> {a.out}")


if __name__ == "__main__":
    main()
