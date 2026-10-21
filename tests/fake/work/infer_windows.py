#!/usr/bin/env python3
"""Fake infer_windows.py: writes PREFIX_s<S>[_reverse].tif per start; all-zero input -> 'No occupied blocks'.
FAKE_INK_FAIL=<regex on the zarr path> writes only the first map and exits 1; FAKE_INK_SLEEP=<s> makes it slow;
FAKE_INK_COMB=1 writes what Reader V3 writes where a window's input is all zero: a comb of strokes and faint lines;
FAKE_INK_FAIL_FIRST=<n> (with FAKE_INK_FAIL_DIR) makes only the first n calls on strip renders fail, like a passing fault;
FAKE_IGNORE_TERM=1 ignores SIGTERM (as the real stitcher does: only KILL ends it)."""
import argparse, os, re, signal, sys
import numpy as np, tifffile, zarr
ap = argparse.ArgumentParser(); ap.add_argument("zarr"); ap.add_argument("ck"); ap.add_argument("out")
ap.add_argument("--starts", type=int, nargs="+"); ap.add_argument("--direction"); ap.add_argument("--prefix", default="rv2")
a, _ = ap.parse_known_args()
if os.environ.get("FAKE_IGNORE_TERM") == "1":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
print(f"input_depth {os.environ.get('FAKE_DEPTH', '17')}", flush=True)
import time; time.sleep(float(os.environ.get("FAKE_INK_SLEEP", "0")))
v = np.asarray(zarr.open_group(a.zarr, mode="r")["0"][:])
dirs = ["forward", "reverse"] if a.direction == "both" else [a.direction]
fail = os.environ.get("FAKE_INK_FAIL") and re.search(os.environ["FAKE_INK_FAIL"], a.zarr)
if int(os.environ.get("FAKE_INK_FAIL_FIRST", "0")) and "/band_z" in a.zarr:
    os.makedirs(os.environ["FAKE_INK_FAIL_DIR"], exist_ok=True)
    for i in range(int(os.environ["FAKE_INK_FAIL_FIRST"])):
        try:
            os.close(os.open(os.path.join(os.environ["FAKE_INK_FAIL_DIR"], str(i)), os.O_CREAT | os.O_EXCL)); fail = True; break
        except FileExistsError:
            continue
if not v.any():
    print("No occupied blocks found in the input volume")
n = 0
for s in a.starts:
    for d in dirs:
        out = os.path.join(a.out, f"{a.prefix}_s{s}{'_reverse' if d == 'reverse' else ''}.tif")
        if os.path.exists(out):
            continue
        m = (v[min(s, len(v) - 1)] // 2).astype(np.uint8)
        if os.environ.get("FAKE_INK_COMB") == "1":
            empty = ~v[s:s + int(os.environ.get("FAKE_DEPTH", "17"))].any(axis=0)
            comb = np.zeros_like(m); comb[:, ::8] = 90; comb[::30, :] = 20
            m[empty] = comb[empty]
        tifffile.imwrite(out, m)
        print(os.path.basename(out)); n += 1
        if fail:
            print("RuntimeError: CUDA out of memory (fake)"); sys.exit(1)
