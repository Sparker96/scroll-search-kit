#!/usr/bin/env python3
"""Copy one region of a remote OME-Zarr (zarr v2, '/' or '.' chunk keys) to a local zarr, chunk files unchanged.

VC3D's tracer (vc_grow_seg_from_segments) reads only local volumes; this makes a local copy holding just the chunks
that intersect a box at level 0 (other chunks are absent = fill value, as zarr allows). The metadata lists only
level 0. Already-present chunk files are skipped, so a re-run resumes.
usage: zarr_region.py URL OUT.zarr --box Z0 Z1 Y0 Y1 X0 X1 [--threads 16]
"""
import argparse
import json
import os
import urllib.error
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor


def get(url, tries=5):
    for t in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (403, 404):
                return None
        except Exception:
            pass
        time.sleep(min(30, 2 ** t))   # pause before the next try
    raise RuntimeError(f"failed: {url}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("url"); ap.add_argument("out")
    ap.add_argument("--box", type=int, nargs=6, required=True)
    ap.add_argument("--threads", type=int, default=16)
    a = ap.parse_args()
    url = a.url.rstrip("/")
    os.makedirs(os.path.join(a.out, "0"), exist_ok=True)
    zattrs = json.loads(get(url + "/.zattrs"))
    for ms in zattrs.get("multiscales", []):
        ms["datasets"] = [d for d in ms["datasets"] if d["path"] == "0"]
    json.dump(zattrs, open(os.path.join(a.out, ".zattrs"), "w"), indent=2)
    open(os.path.join(a.out, ".zgroup"), "wb").write(get(url + "/.zgroup"))
    zarray_raw = get(url + "/0/.zarray")
    open(os.path.join(a.out, "0", ".zarray"), "wb").write(zarray_raw)
    meta = json.loads(zarray_raw)
    sep = meta.get("dimension_separator", ".")
    cz, cy, cx = meta["chunks"]
    z0, z1, y0, y1, x0, x1 = a.box
    keys = [(iz, iy, ix) for iz in range(z0 // cz, (z1 - 1) // cz + 1)
            for iy in range(y0 // cy, (y1 - 1) // cy + 1) for ix in range(x0 // cx, (x1 - 1) // cx + 1)]

    def fetch(k):
        rel = sep.join(str(i) for i in k)
        dst = os.path.join(a.out, "0", *rel.split("/"))
        if os.path.exists(dst):
            return 0
        data = get(f"{url}/0/{rel}")
        if data is None:
            return 0
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        tmp = dst + ".part"
        open(tmp, "wb").write(data)
        os.replace(tmp, dst)
        return len(data)

    with ThreadPoolExecutor(a.threads) as ex:
        sizes = list(ex.map(fetch, keys))
    print(f"{len(keys)} chunks in the box, {sum(1 for s in sizes if s)} downloaded now, {sum(sizes) / 1e6:.0f} MB")


if __name__ == "__main__":
    main()
