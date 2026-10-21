#!/usr/bin/env python3
"""Safety check for an ink-model checkpoint before its first use: load it with torch's weights-only loader.

A .pth file is a Python pickle, and a pickle can run code when it is loaded. torch.load(weights_only=True) accepts only
tensors and plain containers and refuses anything else, so a checkpoint that passes holds data, not code. The inference
code loads the same file again later; this check is what makes that safe to do.

Prints the model's crop depth in layers (config.model.crop_size[0] or config.crop_size[0]) or "none" if the checkpoint
does not record it (then the config's MODEL_DEPTH is used). Exit 0 = safe; any failure to load raises and exits non-zero.
usage: model_check.py CHECKPOINT
"""
import sys

import torch


def crop_depth(ck):
    """Depth of the model's input crop in layers: config.model.crop_size[0] (villa InkConfig) or config.crop_size[0]
    (Reader v2 and Reader V3 keep it at the top level of their training config)."""
    cfg = ck.get("config") if isinstance(ck, dict) else None
    if not isinstance(cfg, dict):
        return None
    model = cfg.get("model") if isinstance(cfg.get("model"), dict) else {}
    for cs in (model.get("crop_size"), cfg.get("crop_size")):
        if isinstance(cs, (list, tuple)) and cs and isinstance(cs[0], int) and cs[0] > 0:
            return cs[0]
    return None


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    ck = torch.load(sys.argv[1], map_location="cpu", weights_only=True)
    d = crop_depth(ck)
    print(d if d is not None else "none")


if __name__ == "__main__":
    main()
