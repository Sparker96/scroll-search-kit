# Lessons from running the search on a rented multi-GPU machine

DRAFT 2026-10-21 — numbers about the rented run were re-checked against its logs on 2026-10-21; the others come from
the content lead's tests on a desktop GPU and say so.

These are the things that cost us time or money on the first rented run. Most of them are not
specific to one provider.

## 1. The container's thread limit, not CPU or RAM, was the first wall

Rented GPU machines are usually containers, and containers have a process/thread limit
(`cat /sys/fs/cgroup/pids.max`; ours: 31,232). Each VC3D grower (`vc_grow_seg_from_seed`) starts
OpenBLAS and OpenMP thread pools with one thread per CPU thread. On a 128-thread machine that is
~360 threads per grower, so ~119 growers ran into the limit: `pthread_create` failed ("Resource temporarily
unavailable") for 70 growers in 4 of the 7 boxes (their logs), and dozens more sat at 0 % CPU until threads were freed
(42, counted while it happened), holding those boxes up for about an hour.

What the kit does now:
- growers run with `OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1` (~110 threads each instead of ~360);
- every grower runs under `timeout` (`GROW_TIMEOUT`, default 1800 s), so a hung one cannot block a box;
- the number of growers is capped at `(pids.max - 4000) / 150`, and also by RAM (`GROWER_GB` 0.5 each after
  `RESERVE_GB` for the ink workers; the cgroup memory limit counts if it is lower than the host's RAM).

## 2. The ink step is CPU-bound on slow-clock server CPUs

Reader v2 inference (`infer_windows.py`, 11 depth windows per strip) kept the GPUs mostly idle on a
2.0 GHz EPYC: the main Python thread was the bottleneck (about 74 % of one core), not the GPU. Ink took 90 s per cm²
per GPU process on the rented machine (75-120 s), against ~43 s on a desktop i7 (re-measured from the run's logs).

What helps:
- parallel data loading (`INK_NUM_WORKERS=4`, the default): on a desktop RTX 4070 SUPER with Reader V3 the main thread
  spent 17 of 26 s per window normalising tiles (a median and percentiles over 17 x 384 x 384 values each); four
  loader processes do that in parallel, 2.7x faster with byte-identical maps; eight add nothing;
- one shared GPU queue for every strip of every box (`inkq.sh`; the first run's `par_ink.sh` only spread a box's
  strips over GPUs that other boxes had finished with);
- not more ink processes per GPU: on the desktop (28 threads, one GPU, Reader V3 with 4 loaders) a second process
  added 30 %, a third nothing, because the step is CPU-bound: about 80 CPU-seconds per cm² for 11 windows
  (`INK_PER_GPU` stays 1);
- when renting, choose by CPU threads per GPU and clock speed, not by the number of GPUs.

Not tested here: two open pull requests to villa's `merge-ink-pipelines` branch, not in the code this kit runs, go
after this bottleneck. `--gpu-normalize` ([#2189](https://github.com/ScrollPrize/villa/pull/2189), armando-gaona)
normalises the tiles on the GPU; its author reports Reader V3 inking a full segment on an NVIDIA L4 in 48 s instead of
65 s, with 0.002 % of the pixels 1/255 apart. [#2213](https://github.com/ScrollPrize/villa/pull/2213) (phippsrtyler)
reports 1.9-4.7× more segments per hour with 2-4 `infer.py` processes per GPU, in two of its three tests together with
that flag. With the normalising off the CPU, `INK_PER_GPU` above 1 may pay off where it did not on our desktop.

## 3. Stitching time is unpredictable

The tracer (`vc_grow_seg_from_segments`) took anywhere from 24 s to 515 s per strip, about 10×,
depending on the box (46 attempts, mean 97 s). Boxes finish at very different times, which is why the ink step is one
shared queue.

## 4. Stitching needs dense overlap, and one non-default setting

With a median of ~11 overlapping patches per patch, every tracer attempt stalled
("best th: 0"). With ~30 it produces strips that fill the box's height. The kit grows in two
expansion passes (`tgt_overlap_count` 10, then 30), sets `same_surface_th` to 4 (the default, 2,
stalled on these thick predictions) and starts each strip from the most-overlapped patch that no
earlier strip covers. The tracer is not deterministic from run to run. (From the content lead's tests on the desktop.)

## 5. Patch growth needs the prediction's normal grids

Without `normal_grid_path`, growth on the surface prediction produced flat planes cutting across
sheets. With the published normal grids (read remotely), patches stay on the sheet.

## 6. VC3D's command-line tools cache every chunk they stream, with no size limit

`~/.VC3D/remote_cache` grew to 249 GB and filled a 492 GB disk; only the GUI applies a cache
budget. Size the rented disk for the scan download of everything you process (our 2 cm band left 31.9 GB of cache;
a whole masked scan can approach ~1 TB).
The growers also download the prediction's normal grids into `normal_grid_path`: ~2 GB after a
single small test box on PHerc. 0343. The kit keeps one copy per scroll (`~/data/normal-grids/<S>`)
so boxes share it.

## 6b. Masked scans have no data outside the scroll, but predictions can still show surfaces there

The public scan volumes are masked: outside the scroll there are simply no chunk files. The
surface prediction can still contain surfaces there, so seeds placed from the prediction alone
can grow strips that render all-zero (9 of the 42 strips on the rented run: 42.7 of the 189 cm² of strips grown). The kit drops seeds whose scan chunk does not exist and skips any
strip whose sampled nodes all fall outside the mask (`mask_check.py`, one HEAD request per chunk).

## 7. Run VC3D through its AppRun launcher

The VC3D AppImage bundles glibc and its own dynamic loader. Calling the tools through
`squashfs-root/AppRun <tool> ...` makes the host's glibc irrelevant (it ran unchanged on Ubuntu
24.04, Ubuntu 26.04 under WSL2 and Debian 13). Running the extracted binaries with
`LD_LIBRARY_PATH` alone segfaulted on Debian 13.

## 8. Make every step resumable, and make every wait end

Rented machines can disappear and runs get stopped. Each phase of `box.sh` leaves a marker file
(`.done`, `.seeded`, `.expanded1/2`) and the ink queue keeps every strip's state, so rerunning the same command
continues where it stopped. And nothing may wait forever while the meter runs: growers, the stitcher, renders and
the ink step all have time limits; a full disk stops the run after a bounded wait instead of idling; the run stops
if its ink workers die; network steps at a band's start are retried a few times before the band is given up.

## 9. Check that a new machine gives the same answer before trusting it

Before searching, the kit renders and inks a strip whose maps we already have, and compares.
On the same GPU architecture (Ada, sm_89) the maps were byte-identical, 11 of 11. Across
architectures expect a correlation above 0.99 rather than identical bytes (not yet tested).

## 10. Memory

With ~119 growers the rented machine used at most 34 GB in all: ~0.3 GB per grower beyond what they share (their
resident size, which counts shared pages, reads ~1 GB). Renders hold an 8 GB chunk cache each; an ink process ~3 GB.

## 11. Blank strips

A strip can still render empty (`depth.tsv` empty, or the ink step reports "No occupied blocks").
The kit gives it one fresh render (`RENDER_RETRIES`), then sets it aside in `queue/blank/` with
its surface kept, instead of counting it as searched.

## 12. Reading at several depths makes up for surfaces that sit a sheet off

On the public PHerc. 0343 control, a patch sitting one layer off the inked layer scored r 0.05
against the known letters at depth 0 and 0.86 at depth −8. The kit therefore reads 11 depths
(−20 to +20 layers, in steps of 4). Five depths (−16, −8, 0, 8, 16) kept most of the signal for
~2.2× less GPU time. (From the content lead's control runs.)

## 13. Cost control (vast.ai)

- Prepaid credit with automatic top-up off is a hard spending cap.
- **Destroy** the instance when results are pulled; a stopped instance keeps billing for its disk.
- Downloads and disk are billed separately from the GPU hour; include them when comparing offers.
- The API key stays on your own machine; the rented machine only ever sees public data and the
  kit. Check vast.ai's current 2FA / API-key behaviour before you rely on the API.

## 14. A model can draw strokes where there is no data

A strip's render is a rectangle around an irregular surface: on our real test strips 44-53 % of it is empty (invalid
mesh nodes render as 0 in every layer, and so does the scan outside its mask). The inference skips tiles that are
empty throughout, but a tile that holds some data is predicted whole, empty part included. There Reader v2 writes a
flat low value (median ~0.24 over 46 % of the public control's empty area, with straight steps where it meets a
skipped tile); Reader V3 writes faint lines and a regular comb of short vertical strokes, which look like rows of
letters. The kit now sets each map to 0 wherever that map's own input layers are all 0 (`nodata.py`,
`NODATA=1`, with `NODATA_MARGIN` to widen it), before anything else looks at the maps. Check any new model's output
over empty areas before trusting what it shows near them.

## 15. Later strips in a box mostly re-cover the first ones

In the rented run each box's strips added less and less new area: measured against the box's earlier strips, the
1st added 100 % of its area, the 2nd 68 %, the 3rd 59 %, the 4th 49 %, the 5th 56 % and the 6th 34 %. A box ended
with ~14 cm² of unique papyrus out of ~200 cm² in its share of the band. The start rule (`next_start.py --by
overlaps`: the most-overlapped patch no strip covers yet) makes the biggest strips but places them next to each
other, and ink is paid on every strip's whole area. `MIN_NEW` (off by default) keeps such strips without inking them;
`next_start.py --by spread` starts each strip as far from the earlier ones as the patch cloud allows.

We re-stitched three of the rented run's boxes on a CPU with both rules (same patches, same tracer settings). `spread`
needed ~14 % less strip area per unique cm² but added only 4 % unique area, and even 12 strips per box reached just
12-30 cm² unique per box. The boxes' grown patches, meanwhile, cover 104-372 cm² each: the stitcher connects only a
small part of what growth found. A greedy cover of the patches themselves (each pick adds the most new area) reaches
half of that area with 1.1-1.2 cm² inked per cm² covered, and 80 % with ~1.5. The kit can ink such a cover instead of
strips (`COVER=1`, `COVER_FRAC`).

An ink test of one box's 80 % cover (54 patches) then found 24 of them, 45 %, outside the masked scan: they rendered
empty. Growth follows the surface prediction, which shows surfaces where the masked scan stores no data (the same
cause as the rented run's blank strips). So cover mode now checks every patch node against the scan's mask first
(`MASK_CHECK=1`, the default) and leaves out patches less than 80 % inside: on that test, the empty patches had at
most 55 % of their nodes in stored chunks and the others at least 94 %, so 80 % sorted all 54 right. The 30 patches
with data covered ~4.3× the unique area of 12 stitched strips in the same box, at ~1.5 cm² rendered and inked per
new cm², about what strips cost. Whether a patch is seen by no other patch did not predict an empty render, so
`DROP_SINGLE` is not recommended.

A second box's 80 % cover was then picked with the mask check on (94 patches, 291 cm²), and every patch rendered with
data, including the 4 with only 81-91 % of their nodes inside. By the cover's count it covers ~202 cm², ~6.8× the
unique area of 12 stitched strips in that box, at 1.44 cm² inked per covered cm². (On the first box the same count,
60.5 cm², matched the 60.7 cm² of the patches that rendered with data.) On one desktop GPU with nothing else running,
render and ink (Reader V3, 11 depths, 4 data-loading workers) took 4.3 + 17.9 s per inked cm². Strips stay the default
until a whole cover-mode run has been measured.

## 16. A worst-case reserve can starve a small machine

The first test of this version on a 31 GB desktop reserved all of its RAM for the ink worker (render cache, model,
data loaders: a worst case), which left 2 grower slots for 4 boxes. The patch clouds stayed thin, every stitched strip
came out under 1 cm², none was kept, and the run still said it had finished. The reserve is now capped at 40 % of RAM,
fewer than 8 grower slots is logged as a warning, a box that keeps no strip says why, and a run that inked nothing
ends with exit 6 ("NOTHING SEARCHED"), never "done".


## 17. A stopped run is over only when its last tool has ended

The first stop in the middle of inking on a real machine (rc4) ended `run.sh` within seconds, but a restart one second
later was refused: "another run.sh is already using" the results folder. Every process a run starts inherits its
lock, and the lock stays held until the last of them exits; a tool that ignores TERM (the stitcher can) or is still
shutting down holds it after `run.sh` has gone. The lock is right to wait for them, since a second run must not start
while the first one's tools still write into the same boxes, so the fix waits instead of dropping the lock: `run.sh`
now ends its leftovers itself before it exits (TERM, then KILL after 10 s), `stop.sh` returns only when nothing of the
run is left (and ends what a `run.sh` killed with -9 left running), and a `run.sh` started while a stopped run's tools
are ending waits up to 2 minutes for them. A `run.sh` started next to one that is still running is refused at once.

## 18. A strip started at a hand-picked point often stalls

In two release-candidate runs of the quick PHerc. 0343 control, the kit started strips at six of the known letters
(`SEEDS_EXTRA`). Of these 12 starts, one grew into a 1.55 cm² strip that reached 10 of the 18 letters and shows the
eight it covers on the inked layer in the run's own map ([VALIDATION](VALIDATION.md) §1). The stitcher stopped the other
eleven early ("stopping growth after 5 expansions with no valid-count increase", 0.05-0.90 cm²), although their start
patches had grown normally (2.6-2.9 cm²) and lay partly on the inked layer (about a third to three quarters of their
nodes within 20 voxels of the published letter mesh). The stitcher extends a surface only where many overlapping patches
agree, and a point picked for its letters is not picked for that. Strips that the kit's own rule started (at the
most-overlapped patch) reached the 1 cm² a strip must have in 5 of 18 tries in the same runs, whose small growth budget
makes stitching uncertain anyway. A third run kept 3 of its 6 letter starts and 2 of its 10 rule starts, so over the
three runs 4 of 18 letter starts and 7 of 28 rule starts reached 1 cm²: under this budget a start stalls more often than
not, wherever it is. So a seed point that no inked strip reaches now gets the patch grown at it inked as it is, a minute
or two of GPU time (`box_*/seeds_extra.ink.tsv` says which points were reached and which were inked this way): the
config asked for that place to be searched, and the patch around it is what the run has there. In the second run, the
six patches inked this way reached all 18 letters between them, and every letter shows in at least one of them. Tries
started at seed points no longer count against `MAXTRY`: in that run they had used 3 of one box's 4 tries, leaving the
kit's own rule a single one there. In the third run, its boxes made up to 6 tries (4 for the rule, plus one per seed
point).
