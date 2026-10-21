#!/usr/bin/env python
"""Run villa's flat ink inference for several layer windows of one surface volume in ONE process.

Same model, settings and per-window code path as `python -m vesuvius.ink_detection.inference.infer` (it calls that
module's parse_args, configure_model, prepare_model_for_inference and infer_single_zarr), but the checkpoint is loaded
once for all windows instead of once per window, which is where most of the time went (11 windows: ~90 s -> ~20 s).
Each window S gives OUTDIR/<prefix>_s<S>.tif (forward) and/or <prefix>_s<S>_reverse.tif, exactly as the per-window
commands named them; finished files are skipped; each is written under a temporary name and renamed when complete.

usage: infer_windows.py ZARR CHECKPOINT OUTDIR --starts S... [--direction forward|reverse|both] [--prefix rv2]
       [any infer.py option, e.g. --overlap 0.5 --blend-mode hann --batch-size 16 --no-compile --num-workers 0]
The window is S .. S + model depth - 1 (17 layers for Reader v2), as --layer-start S --layer-end S+17 did.
"""
import argparse
import logging
import os
from dataclasses import replace
from pathlib import Path

import torch

from vesuvius.ink_detection.inference import infer as I


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("zarr"); ap.add_argument("checkpoint"); ap.add_argument("outdir", type=Path)
    ap.add_argument("--starts", type=int, nargs="+", required=True)
    ap.add_argument("--direction", choices=("forward", "reverse", "both"), default="forward")
    ap.add_argument("--prefix", default="rv2")
    a, rest = ap.parse_known_args()
    a.outdir.mkdir(parents=True, exist_ok=True)
    args = I.normalize_inference_paths(I.parse_args([a.zarr, a.checkpoint, str(a.outdir / "unused.tif")] + rest))
    logging.basicConfig(level=logging.WARNING, format="[%(asctime)s] %(levelname)s %(message)s")
    if hasattr(torch, "set_float32_matmul_precision"):
        torch.set_float32_matmul_precision("high")
    configured = I.configure_model(args)
    print(f"input_depth {configured.input_depth}", flush=True)   # run.sh's preflight compares it with the kit's depth
    model, device = I.prepare_model_for_inference(configured.model, gpu_ids=args.gpu_ids,
                                                  compile_model=args.compile_model, compile_mode=args.compile_mode)
    configured = replace(configured, model=model)
    for s in a.starts:
        args.layer_start, args.layer_end = s, s + configured.input_depth
        for direction in I.resolve_run_directions(a.direction):
            out = a.outdir / f"{a.prefix}_s{s}{'_reverse' if direction == 'reverse' else ''}.tif"
            if out.exists() and out.stat().st_size > 0:
                continue
            tmp = out.with_name(out.stem + ".part.tif")
            I.infer_single_zarr(args=args, input_zarr=args.input_zarr, configured_model=configured, device=device,
                                output_tiff=tmp, layer_direction=direction)
            os.replace(tmp, out)
            print(out.name, flush=True)


if __name__ == "__main__":
    main()
