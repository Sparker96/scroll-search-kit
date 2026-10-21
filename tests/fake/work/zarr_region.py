#!/usr/bin/env python3
"""Fake zarr_region.py: makes an empty local zarr with level 0 metadata (no download)."""
import json, os, sys
out = sys.argv[2]
os.makedirs(os.path.join(out, "0"), exist_ok=True)
json.dump({"zarr_format": 2, "shape": [100, 100, 100], "chunks": [64, 64, 64], "dtype": "|u1", "compressor": None,
           "fill_value": 0, "order": "C", "filters": None}, open(os.path.join(out, "0", ".zarray"), "w"))
print("0 chunks in the box (fake)")
