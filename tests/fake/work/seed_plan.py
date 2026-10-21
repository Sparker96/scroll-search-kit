#!/usr/bin/env python3
"""Fake seed_plan.py: FAKE_SEEDS seeds in a ring (same columns as the real one), no download."""
import math, os, sys
out = sys.argv[3]; z = int(sys.argv[sys.argv.index("--z") + 1]); n = int(os.environ.get("FAKE_SEEDS", "6"))
with open(out, "w") as fh:
    for k in range(n):
        t = 2 * math.pi * k / n
        x, y = int(500 + 300 * math.cos(t)), int(500 + 300 * math.sin(t))
        name = f"bz{z}a{int(math.degrees(t)):03d}f55" + ("out" if k == n - 1 else "")
        fh.write(f"{name}\t{x}\t{y}\t{z}\t{int(math.degrees(t))}\t0.55\t600\t1.0\n")
print(f"{n} seeds -> {out}")
