#!/usr/bin/env python3
"""Stand-ins for the three VC3D tools the kit calls, for testing the kit's orchestration without VC3D or data.

grow PRED PATCHES PARAMS [x y z]   -> PATCHES/auto_grown_<n>/{x,y,z}.tif, meta.json (area_cm2), overlapping.json
trace --volume .. --src-dir PATCHES --target-dir TD --params P --src-segment S -> TD/auto_trace_<n>/ (a bigger grid)
render --volume V --segmentation TRACE --num-slices N ... --zarr-output Z -> Z (zarr v2, group with array "0")
Environment: FAKE_TRACE_FAIL=1 (tracer makes nothing), FAKE_TRACE_SLEEP=<s> (slow tracer; with FAKE_TRACE_HANG=<regex on the target dir> only those), FAKE_RENDER_BLANK=<regex
on the trace path> (all-zero render), FAKE_RENDER_HOLES=1 (renders have no data in the last 40 columns, like invalid
mesh nodes, and none in layers 40+ of a top-left corner, like a surface leaving the scan's mask), FAKE_RENDER_FAIL=<regex> (render exits 1), FAKE_GROW_FAIL=<regex on the patches path> (expansion growers fail),
FAKE_TRACE_SAME=1 (every stitched strip lies on the same sheet), FAKE_TRACE_FAIL_META=<regex on the start patch's
meta.json> (only those tracers make nothing, like the real stitcher stalling at once), FAKE_TRACE_AT_START=1 (a strip is
centred on its start patch, so it reaches the point that patch grew from), FAKE_SLEEP=<seconds per call>,
FAKE_IGNORE_TERM=1 (ignore SIGTERM, as the real stitcher does: only KILL ends it), FAKE_GROW_HANG=<regex on the patches
path and the params file> (the first matching grower of each box hangs for FAKE_GROW_SLEEP seconds [600] and makes
nothing, until GROW_TIMEOUT stops it; with FAKE_GROW_IGNORE_TERM=<regex> it also ignores SIGTERM).
"""
import json
import os
import random
import re
import signal
import sys
import time
from pathlib import Path

import numpy as np
import tifffile


def grid(cx, cy, cz, rows, cols, step=20.0):
    r, c = np.mgrid[0:rows, 0:cols].astype(np.float32)
    x = cx + (c - cols / 2) * step
    y = cy + 0.0 * r + 0.3 * (c - cols / 2) * step
    z = cz + (r - rows / 2) * step
    return x, y, z


def write_tifxyz(d, x, y, z, meta):
    d.mkdir(parents=True, exist_ok=True)
    for n, a in (("x", x), ("y", y), ("z", z)):
        tifffile.imwrite(d / f"{n}.tif", a.astype(np.float32))
    (d / "meta.json").write_text(json.dumps(meta))


def grow(args):
    pred, patches, params = Path(args[0]), Path(args[1]), json.loads(Path(args[2]).read_text())
    if params["mode"] == "expansion" and os.environ.get("FAKE_GROW_FAIL") and re.search(os.environ["FAKE_GROW_FAIL"], str(patches)):
        print("pthread_create failed: Resource temporarily unavailable (fake)")
        return 1
    hang = os.environ.get("FAKE_GROW_HANG")
    if hang and re.search(hang, f"{patches} {args[2]}"):
        try:   # only the first matching grower of each box hangs: it leaves a marker in the box folder
            os.close(os.open(patches.parent / ".fake_hang", os.O_CREAT | os.O_EXCL | os.O_WRONLY))
        except FileExistsError:
            pass
        else:
            it = os.environ.get("FAKE_GROW_IGNORE_TERM")
            if it and re.search(it, f"{patches} {args[2]}"):
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            print("hanging (fake)", flush=True)
            time.sleep(float(os.environ.get("FAKE_GROW_SLEEP", "600")))
            return 1
    rng = random.Random(os.getpid() ^ int(time.time() * 1e6))
    existing = sorted(patches.glob("auto_grown_*"))
    if len(args) >= 5:
        cx, cy, cz = (float(v) for v in args[2 + 1:2 + 4])
    elif existing:
        x0 = tifffile.imread(rng.choice(existing) / "x.tif")
        cx, cy, cz = float(x0.mean()) + rng.uniform(-60, 60), 4000.0, 10000.0 + rng.uniform(-200, 200)
    else:
        print("no patches to expand from")
        return 1
    x, y, z = grid(cx, cy, cz, 40, 60)
    name = f"auto_grown_{time.time_ns()}_{rng.randrange(1 << 30)}"
    write_tifxyz(patches / name, x, y, z, {"area_cm2": round(40 * 60 * 400 * (8.64e-4) ** 2, 3), "mode": params["mode"],
                                           "seed": [cx, cy, cz]})
    others = [p.name for p in existing][-min(len(existing), params.get("tgt_overlap_count", 10) or 10):]
    (patches / name / "overlapping.json").write_text(json.dumps({"overlapping": others}))
    print("grown", name)
    return 0


def opt(args, k):
    return args[args.index(k) + 1]


def trace(args):
    hang = os.environ.get("FAKE_TRACE_HANG")   # regex on the target dir: only those tracers are slow
    if not hang or re.search(hang, str(opt(args, "--target-dir"))):
        time.sleep(float(os.environ.get("FAKE_TRACE_SLEEP", "0")))
    td, start = Path(opt(args, "--target-dir")), Path(opt(args, "--src-segment"))
    fm = os.environ.get("FAKE_TRACE_FAIL_META")
    if os.environ.get("FAKE_TRACE_FAIL") == "1" or (fm and re.search(fm, (start / "meta.json").read_text())):
        print("stopping growth after 5 expansions with no valid-count increase")
        return 0
    x0 = tifffile.imread(start / "x.tif")
    cx = 600.0 if os.environ.get("FAKE_TRACE_SAME") == "1" else float(x0.mean())   # 1: every strip on one sheet
    cy, cz = 4000.0, 10000.0
    if os.environ.get("FAKE_TRACE_AT_START") == "1":
        cy, cz = (float(tifffile.imread(start / f"{a}.tif").mean()) for a in "yz")
    x, y, z = grid(cx, cy, cz, 60, 100)
    name = f"auto_trace_{time.time_ns()}"   # like VC3D: written under a temporary name, renamed when complete
    write_tifxyz(td / f".tmp_{name}", x, y, z, {"source": start.name})
    os.rename(td / f".tmp_{name}", td / name)
    print("trace written")
    return 0


def render(args):
    seg, zout, n = opt(args, "--segmentation"), Path(opt(args, "--zarr-output")), int(opt(args, "--num-slices"))
    if os.environ.get("FAKE_RENDER_FAIL") and re.search(os.environ["FAKE_RENDER_FAIL"], seg):
        print("render error: timeout reading chunks")
        return 1
    import zarr
    blank = bool(os.environ.get("FAKE_RENDER_BLANK") and re.search(os.environ["FAKE_RENDER_BLANK"], seg))
    g = zarr.open_group(str(zout), mode="w", zarr_format=2)
    a = g.create_array("0", shape=(n, 120, 200), chunks=(n, 120, 200), dtype="uint8")
    if not blank:
        rng = np.random.default_rng(len(seg))
        a[:] = (60 + 120 * np.exp(-((np.arange(n) - n // 2) / 6.0) ** 2))[:, None, None].astype(np.uint8) \
            + rng.integers(0, 20, (n, 120, 200), dtype=np.uint8)
        if os.environ.get("FAKE_RENDER_HOLES") == "1":
            a[:, :, 160:] = 0
            a[40:, :30, :50] = 0
    print("rendered", zout.name, "blank" if blank else "")
    return 0


def main():
    if os.environ.get("FAKE_IGNORE_TERM") == "1":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(float(os.environ.get("FAKE_SLEEP", "0")))
    mode, args = sys.argv[1], sys.argv[2:]
    sys.exit({"grow": grow, "trace": trace, "render": render}[mode](args))


if __name__ == "__main__":
    main()
