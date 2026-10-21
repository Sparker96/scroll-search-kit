#!/usr/bin/env python3
"""How much of a new strip is new? Its nodes count as new unless an earlier strip has a point within --tol voxels
(summary.py's unique area: earlier strips sampled every ~5 voxels; a strip on the next sheet, ~20 voxels away, is new).
Prints: new percent, new cm2, strip cm2.
usage: new_area.py TRACE [EARLIER_TRACE...] --vx VOXEL_UM [--tol 10]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # the kit's own folder (python -I leaves it out)
from summary import unique_areas  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace"); ap.add_argument("earlier", nargs="*")
    ap.add_argument("--vx", type=float, required=True); ap.add_argument("--tol", type=float, default=10.0)
    a = ap.parse_args()
    total, new = unique_areas(a.earlier + [a.trace], a.vx, a.tol)[-1]
    print(f"{100 * new / total if total else 0:.0f} {new:.2f} {total:.2f}")


if __name__ == "__main__":
    main()
