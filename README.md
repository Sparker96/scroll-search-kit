# Search eligible scrolls on rented GPUs: a reproducible kit + measured cost per cm²

DRAFT 2026-10-20 — not released. ⟨TBD⟩ = not filled in yet.

A scripted, resumable pipeline that searches a Herculaneum scroll scan for ink on a rented multi-GPU Linux machine,
from the public OME-Zarr data to depth-resolved ink maps on tifxyz surfaces, and what that measurably costs.

**Measured on one 2 cm band of an eligible 9.362 µm scroll** (rented 8-GPU machine, $3.13/h): **$9.64 for 3.06 h;
86 cm² of papyrus read at 11 depths, counted once = $0.11 per cm²**, about 6 % of that band's papyrus (the 33 strips
add up to 146.5 cm², but overlap; "counted once" = the union of their surfaces, see COSTS). A whole scroll (~14,000 cm²) is not yet affordable this way: even with every GPU
busy and no overlap the measured ink speed puts it at ~$150-220 and 2-3 days, and the ink step, not the GPUs, is the
bottleneck. [docs/COSTS.md](docs/COSTS.md) has the numbers and what would change them.

## Why

Most First Letters attempts read small, hand-picked areas. Letters can sit in one small region of a scroll (PHerc.
0343's first letters all lie in one area), so a blank search of a few cm² says little; covering much more of a
scroll means thousands of surfaces read at several depths, unattended, on hardware most people would have to rent.
This kit does that, with the failure modes we hit on the first rented run already fixed
([docs/LESSONS.md](docs/LESSONS.md)), and says honestly how far it gets per dollar.

## What it does

`kit/work/run.sh <config>` runs one scroll's search unattended. A config file holds everything specific to the scroll
(scan and prediction URLs, voxel size, axis, z bands) and the ink model; the code has no scroll built in
(`kit/config/TEMPLATE.env`, `kit/config/control-0343.env`).

1. **Same-answer check** (`check.sh`): render a public control strip and read it with the run's own ink model and
   settings, compare with that model's known maps; the search starts only if they match.
2. **Per band** (`band.sh`): seed points in rings around the scroll axis, minus any outside the scan's mask
   (`mask_check.py`), and a grid of boxes over the band.
3. **Per box** (`box.sh`; the growers of all boxes share one pool of CPU slots, two bands grow at once): copy the
   box's part of the surface prediction
   (`zarr_region.py`); grow seed patches and two expansion passes (`vc_grow_seg_from_seed`, `tgt_overlap_count` 10
   then 30, with the prediction's normal grids); stitch them into large strips (`vc_grow_seg_from_segments`,
   `same_surface_th` 4), each started from the most-overlapped patch no earlier strip covers (`next_start.py`).
   Being tested: `COVER=1` inks a cover of the grown patches themselves instead (`cover.py`), which reaches far more of
   what growth found; patches outside the scan's mask are left out first (in ink tests of two boxes the cover reached
   4.3× and 6.8× the unique area of 12 stitched strips in the same box).
4. **One shared GPU queue** (`inkq.sh`): every kept strip, from any box or band, goes to the next free GPU: render
   61 layers (`vc_render_tifxyz --flip-normals`), find the written side from the axis (`reading_side.py`), read it
   with the ink model at 11 depths (`infer_windows.py`), then set each map to 0 wherever its input had no data
   (`nodata.py`: outside the mesh or the scan's mask, where a model can draw strokes that are not ink). Strips outside
   the mask are skipped; blank renders get one fresh try and are then set aside.
5. **Summary** (`summary.py`): strips and cm² per outcome, time per stage, cm² per hour; `metrics.sh` + `usage.py`
   give CPU/GPU use and cost.

Every step is timed and resumable; a stopped run continues where it stopped (`stop.sh` stops one cleanly). Nothing
waits forever while the meter runs: growers, the stitcher, renders and the ink step have time limits, a full disk or
an unreachable scan stops the run after a bounded wait, failed boxes and bands are retried and, if they keep failing,
reported (`run.sh` ends NOT COMPLETE, never "done"); an ink worker that its GPU's failures stopped, or that died, is
started again a few times. Inputs are standard community formats (OME-Zarr straight from the
open-data bucket); outputs are tifxyz strips and TIFF ink maps that open in VC3D. `watch.sh` is a read-only health
check to run from your own machine.

## Validated on public data

- **PHerc. 0343** (known letters): on our own automatically grown, stitched strip, the known letters come back at
  whatever depth that part of the strip needs (r 0.63-0.89 against the map of his own surface; Reader V3 0.70-0.88).
- **PHerc. 0814**, on the 9.362 µm scan type of the eligible scrolls: our own patches show the published text lines
  where they lie on the inked layer (r up to 0.65).
- **Same answer on rented hardware**: a rented 8-GPU machine reproduced a desktop machine's maps byte for byte (11/11
  maps, same GPU architecture). The kit runs this check first.
- **Reader V3, the default model**, separates the known PHerc. 0343 letters from the gaps between them a little better
  than Reader v2 (AUC 0.746 vs 0.725 on the inked layer, 0.648-0.661 vs 0.616 one layer off), at the same
  or better speed. It draws false strokes where its input is empty; the kit removes those (`nodata.py`).
- **This version of the kit** ⟨to fill: release-candidate test on a desktop GPU; stand-in tool tests in `tests/`⟩.

See [docs/VALIDATION.md](docs/VALIDATION.md), including what this does *not* show.

## Quick start

You need a vast.ai account with prepaid credit (auto top-up off), its API key in a file only you can read, and an
SSH key used only for rented machines. Step by step, with costs and safety notes: [docs/RENTING.md](docs/RENTING.md).

```bash
kit/make_kit.sh build/kit                  # the folder that goes to the machine (fetches VC3D + control data, checksums)
kit/vast.sh offers                         # pick a machine
kit/vast.sh create OFFER my-search 2000    # rent it with a 2000 GB disk; prints its ID
kit/vast.sh wait ID && kit/vast.sh push ID build/kit
kit/vast.sh ssh ID 'bash /root/kit/setup.sh /root/kit/config/control-0343.env'    # ~1-5 min
kit/vast.sh ssh ID 'setsid nohup bash /root/work/run.sh /root/kit/config/control-0343.env > /root/run.log 2>&1 < /dev/null &'
kit/vast.sh ssh ID 'bash /root/work/watch.sh /root/results/PHerc0343'               # while it runs
kit/vast.sh pull ID /root/results ./results          # maps + surfaces, no 3D volumes
kit/vast.sh destroy ID                               # billing stops only when the machine is destroyed
```

For a first try, `kit/config/control-0343-quick.env` searches the same band with a small growth budget and 2 strips per
box (⟨time: from the release-candidate test⟩), and starts strips at six of the known letters (`SEEDS_EXTRA`; a letter
that no strip reaches gets the patch grown there inked instead), so its maps can be checked for them.

## Requirements

- Rented or own Linux x86_64 machine with NVIDIA GPUs, a driver new enough for CUDA 13, and outbound internet.
  The measured run used 128 CPU threads, 251 GB RAM and 1 TB of disk for one 2 cm band (the scan cache reached
  32 GB; plan disk for the scan data you will read). Smaller machines work with fewer growers (`band.sh` caps them
  by RAM and by the container's thread limit).
- Nothing to compile: VC3D comes as a pinned, checksum-verified AppImage (see NOTICE); Python
  3.14 + PyTorch 2.14.1 (CUDA 13.0) are installed by `setup.sh` with `uv`.

## Limitations

- Reviewing the maps is still manual. We found no automatic score that reliably puts real
  writing above the blob fields and crack edges that fire on blank papyrus.
- Where the surface prediction merges sheets, the grown surfaces cut across layers and read
  nothing; the kit does not detect this by itself.
- Throughput depends heavily on the CPU (the ink step is CPU-bound on slow-clock server CPUs).
- Coverage: with the default settings one band's strips covered ~6 % of its papyrus, counted once. More strips per
  area are a setting away (`NTR`, `START_*`) but cost proportionally more ink time.
- Ink maps from different models are not on one scale: Reader V3 marks about twice as many pixels as Reader v2 above
  p = 0.5. Compare models at matched sensitivity, never with one fixed threshold.

## Licences and credits

- Our code: MIT ([LICENSE](LICENSE)). Data we publish (the control strip and its reference
  maps, and the images in `docs/img`): CC-BY-NC 4.0.
- VC3D (Volume Cartographer, ScrollPrize/villa): GPLv3; we mirror one unmodified, verified build
  because upstream release builds rotate ([NOTICE.md](NOTICE.md)).
- Reader V3 (the default) and Reader v2 ink models by Domenico Russo, MIT (downloaded at setup from Hugging Face at
  pinned revisions, not redistributed). The `vesuvius` Python package from ScrollPrize/villa.
- Public data: the Vesuvius Challenge open-data bucket; PHerc. 0343's letters, letter mesh and scroll axis by Erwin
  Nieuwlaar (the axis file ships with his MIT notice); the PHerc. 0814 team segment.

## How this was made

The code, the measurements and these documents were produced by AI agents (Anthropic's Claude),
working as a small team on the repository owner's home server, a home desktop GPU and rented
machines. The repository owner (GitHub: Sparker96) chose the goals and approved every spend and
every publication. Every number in the documents comes from logged runs.
