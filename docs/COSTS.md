# What it costs: one band measured, and what a whole scroll would take

The band was measured on 2026-10-20 with the pilot version of this kit (same recipe; this version adds the fixes below).
Numbers re-measured from the run's raw logs (`metrics.tsv`, every box's `timing.tsv`); desktop measurements of the fixes
are marked as such. The scroll is one of the eligible 9.362 µm scrolls; we do not name it yet. The release test at the
end (2026-10-22) ran this version on the public PHerc. 0343 control.

## The machine

| | |
|---|---|
| GPUs | 8 × RTX 4070 Ti SUPER 16 GB (Ada) |
| CPU | AMD EPYC 7702, 128 threads, 2.0 GHz base |
| RAM / disk | 251 GB / 1000 GB NVMe |
| price | $2.67/h machine + $0.46/h for the disk = $3.13/h; downloads $0.0026/GB |
| provider | vast.ai, on-demand, paid from prepaid credit |

## One 2 cm band, end to end

| | |
|---|---|
| **charged** | **$9.64 for 3.06 h**, from renting to destroying the machine: setup (54 s), the same-answer check (~9 min) and an hour lost to the thread-limit fault included |
| **searched** | **86 cm² of papyrus, counted once**, read at 11 depths (33 strips with papyrus; 146.5 cm² summed over strips, which overlap) |
| **cost per cm² searched** | **$0.112** per unique cm² ($0.066 per cm² of strip) |
| coverage | ~6 % of the band's papyrus (~1,400 cm²) |
| wasted | 9 more strips (42.7 cm²) lay outside the scan's mask and rendered blank; the kit now drops such seeds and skips such strips |

Rates per stage:

| stage | measured | note |
|---|---|---|
| growth | 54 CPU-thread-seconds per cm² of patches grown (in the one box the thread fault did not hit) | ~7,500 cm² of overlapping patches over the band in two time-capped passes (40 + 30 min per box); growth was not the limit |
| stitching | 46 tracer attempts, 97 s mean, 24-515 s | 6 strips kept per box |
| render (61 layers) | 6.1 s per cm² of strip, 25 s per strip on average | |
| ink (Reader v2, 11 depths) | 90 s per cm² per GPU process (75-120 s) | bound by one CPU core per process: GPUs were 1-2 % busy; a desktop i7 does ~43 s per cm² |
| ink (Reader V3, now the default) | 64 s per cm² per GPU in the release test (below: another machine and scroll, mostly while boxes were still growing) | on a desktop RTX 4070 SUPER with 4 data-loading workers (the default) and nothing else running: 17.9 s per cm² over 94 cover patches (291 cm²; their render took 4.3 s per cm²); without parallel loading 33-37 s, Reader v2 42 |
| scan download | 31.9 GB, ~95 MB/s | public open-data bucket |

"Unique" here = the union of the strips' surfaces: a strip node counts unless an earlier strip, sampled every ~5
voxels, has a point within 10 voxels (~94 µm at 9.362 µm) of it (`kit/work/summary.py`). Comparing grid nodes only, every 20 voxels, gives 97 cm²;
tolerances of 6-14 voxels give 82-89 cm². About 41 % of the strip area was overlap: neighbouring boxes overlap by
design, and several strips per box can start on the same sheet.

How busy the machine was (`kit/usage.py`): CPU ~100 % during growth and 57 % over the whole run; GPUs ~0 % during
growth and 1-2 % while inking; at most 2-4 of the 8 GPUs had work at any time, because each box inked its own strips
on one GPU. This version of the kit puts all strips in one shared GPU queue; in the release test below, all four GPUs
took strips from it.

## Start-up versus cost per cm²

The measured run was one band, so its price mixes a one-off start with the cost of searching. From its metrics
(`usage.py`, 10-minute blocks): setup and the same-answer check took the first ~10 minutes; growing the band took the
next ~80 minutes (about an hour of it lost to the thread-limit fault) while all 8 GPUs had nothing to do; the first
strip was inked ~1.5 h after the start, about half of the 3.06 h billed. A longer run pays that start once: this
version grows the next band while the GPUs ink the previous one, and inks each box's strips as soon as they are
stitched. So $0.112 per unique cm² overstates what each further cm² costs; the rate a multi-band run settles at is not
measured yet. The ink rate itself (90 s per cm²) was measured while growth had mostly finished. Growth running at the
same time does slow it: on a 28-thread desktop with one GPU (Reader V3, 4 data-loading workers), ink took ~17 s per cm²
with nothing else running and ~45 s per cm² while a band was growing, even with the growers at a lower CPU priority
(`GROW_NICE` 10). That scan has ~17 % more pixels per cm², so growth made the ink 2.2-2.6× slower. The ink step is
limited by the CPU feeding the GPU, so a run that grows and inks at once needs CPU threads kept free for the ink workers
(`RESERVE_THREADS`), or a machine with more cores per GPU.

## A whole scroll, at these rates

This scroll's papyrus is ~14,000 cm² by our estimate from the surface prediction (one 2 cm band ≈ 1,400 cm²).

- **Straight extrapolation of the measured run:** $0.112 per unique cm² × 14,000 cm² ≈ **$1,500**, if coverage
  could be pushed to the whole scroll at all. Most of that is inefficiency we can already see: GPUs mostly idle
  (2-4 of 8 had work at a time), an hour lost to the thread fault, 41 % of strip area overlapping.
- **Floor at the measured ink speed:** all 8 GPUs busy at 75-120 s per cm², no overlap: ink ~37-58 h (~$115-180),
  plus ~10-12 h of growth: **~$150-220 and 2-3 days**. This assumes strips tile the papyrus without overlap, which
  the measured run is far from (~6 % of the band covered).

So a whole scroll is not yet affordable with this recipe. What would change it, each **not yet measured**:

| change | expected effect | kit setting |
|---|---|---|
| parallel data loading in the ink step (now the default, 4 processes) | 2.7× faster ink on a desktop RTX 4070 SUPER with Reader V3 (3.37 → 1.25 s per cm² per window), maps byte-identical; 8 processes or batch 8 add nothing; not yet measured on a rented machine | `INK_NUM_WORKERS` |
| fewer depth windows | 5 windows kept most of the signal on the public control, ~2.2× less ink time | `CENTRES` |
| more strips per area, or a tiling planner | higher coverage per band | `NTR`, `START_*`, `GRID` |
| ink a cover of the grown patches instead of strips | in ink tests of two boxes: 4.3× and 6.8× the unique area of 12 stitched strips in the same box, at 1.4-1.5 cm² inked per new cm², once patches outside the masked scan are left out (45 % of the first box's cover rendered empty; the second box's, picked with the mask check, had data in all 94 patches) | `COVER`, `COVER_FRAC`, `MASK_CHECK` |
| skip strips that add little new area | in the rented run, a 40 % threshold would have cut render + ink area by 32 % and lost 12 % of the unique area | `MIN_NEW` |
| a machine with faster or more CPU cores per GPU | faster ink while it stays CPU-bound | rent accordingly |
| normalising on the GPU (`--gpu-normalize`) and 2-4 ink processes per GPU, from open villa pull requests ([#2189](https://github.com/ScrollPrize/villa/pull/2189), [#2213](https://github.com/ScrollPrize/villa/pull/2213)) not in the code this kit runs | their authors report Reader V3 1.37× faster with practically the same map, and 1.9-4.7× more segments per hour with 2-4 processes per GPU; our ink step is CPU-bound on exactly this normalising ([LESSONS](LESSONS.md) §2) | `INK_PER_GPU`; the flag needs a newer villa |
| one shared GPU queue (done in this version) | no GPU idles while another box finishes; in the release test all four GPUs took strips from it, up to four at once | — |

Our unverified guess with these fixes: ~$60-120 and 20-30 h for a whole scroll. We will replace the guess with
measurements before anyone should rely on it.

## Release test: a first try on a rented 4-GPU machine

On 2026-10-22 the last release candidate ran the quick control configuration with a second band added: PHerc. 0343 at
8.64 µm, two bands of 2050 voxels, two strips per box, strips also started at six known letters. It was rented and run
with the kit's own commands. This measures what a first try costs and how fast Reader V3 inks on a rented server CPU.
It is not a cost per cm² for a search: the scroll is another one, and the growth budget is small.

| | |
|---|---|
| machine | 4 × RTX 4070 SUPER 12 GB (Ada), Intel Xeon E5-2699 v4 (2.2 GHz) with 88 threads, 251 GB RAM, 400 GB disk; $0.96/h + $0.06/h for the disk = $1.02/h (vast.ai, on-demand) |
| **charged** | **$1.54** from renting the machine to destroying it (88 minutes; the balance difference) |
| times | SSH answered 2 min 44 s after `create`; push 38 s; `setup.sh` 67 s; same-answer check 3 min (render 45 s, ink 136 s); `run.sh` 80 min for both bands; pull 22 s (406 MB); destroy 1 s |
| searched | 18 strips and patches, 44.9 cm² summed, 35.9 cm² counted once (26.7 cm² per hour of `run.sh`) |
| ink (Reader V3, 11 depths) | 64 s per cm² per GPU (126-199 s per strip or patch), most of it while other boxes were still growing; render 13 s per cm² |
| how busy (`usage.py`) | CPU 52 % over the run, 64-77 % while growing; GPUs 2 %, 5 % while inking; all four GPUs took strips from the one queue, up to four at once, two or more in 12 of the 81 minutes |
| most used | RAM 33 GB of 251; disk 47 GB of 400 (the scan cache 19 GB) |

Growth took most of the time: ink is short next to growth with this configuration, so the GPUs had little to do. The
ink rate is the one to compare: on the desktop (Intel i7, 28 threads, one GPU) the same model inked ~45 s per cm² while
a band grew and ~17 s alone. Most likely the rented machine's older, slower cores fed each GPU more slowly: the ink
step is CPU-bound ([LESSONS](LESSONS.md) §2).

## Measure your own

- `kit/usage.py metrics.tsv --threads N --usd-per-hour P` — CPU/GPU busy time and cost, in 10-minute blocks. It
  covers only the time `metrics.sh` ran (from the run's start to its end), not setup, the pull or the minutes before
  the machine is destroyed.
- `kit/vast.sh balance` before renting and after destroying: the difference is the full charge (machine, disk and
  downloads). That is how the $9.64 above was measured.
- `kit/work/summary.py RESULTS/<run>` — strips and cm² per state, seconds per phase, cm² searched per hour.
