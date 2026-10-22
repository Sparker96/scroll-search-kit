# Tests

Two levels, both CPU-only.

## `run_fake.sh` — the orchestration, with stand-in tools (seconds per scenario, no downloads)

```bash
tests/run_fake.sh /path/to/python [scenario ...]
```

Needs a Python with numpy, tifffile, zarr and torch (CPU build is enough). Test homes go under `$TMPDIR`; point it
at a disk folder if /tmp is a RAM disk (each scenario leaves a few MB to ~100 MB behind). `tests/fake/` replaces VC3D's three tools,
the prediction copy, seed planning, the mask check and the ink model with small fakes that write the same kinds of
files; everything else is the kit's real code, run in a throw-away HOME. Scenarios:

| scenario | checks |
|---|---|
| happy | two bands end to end: every kept strip inked once, maps per strip, mask filter, window starts, summary (with each strip's whole worker time), DEL_ZARR |
| minnew | with `MIN_NEW`, strips that add too little new area to their box are kept but never queued or rendered; logged and counted in the summary |
| cover | `COVER=1`: a greedy cover of the grown patches (up to `COVER_FRAC` of their union) is inked instead of stitched strips; a resumed run queues the same patches; with a stand-in mask, patches mostly outside the scan are left out (none queued, each pick >= 0.8 inside, counted in the box log and the summary); `DROP_SINGLE` leaves out a patch no other comes near |
| nostrips | a run that keeps no strip anywhere ends with exit 6 "NOTHING SEARCHED", each box warns with its largest strip, the summary shows the warnings |
| reserve | the default RAM reserve is capped at 40 % of RAM, so a small machine still gets growers |
| blank | a blank render gets one fresh render, then waits in `queue/blank/` with its surface kept; `retry blank` works |
| outside | a strip outside the scan's mask is never rendered (`queue/outside/`); `inkq.sh retry RUN outside` puts it back |
| inkfail | an ink failure lands in `queue/failed/` with its reason; `watch.sh` alerts; `run.sh` reports it (exit 6) |
| renderfail | a failed render gets one retry, then lands in `queue/failed/` (not blank) |
| netdown | renders fail while the scan stays unreachable: after `NET_DOWN_MAX` seconds the ink workers stop the run with an alert and an error exit; the strips stay pending in the queue, none marked failed |
| gpufail | a worker whose ink step keeps failing stops after `GPU_FAIL_MAX` strips (no restarts); the run ends with an error |
| restart | workers retired by a passing GPU fault start again and finish the queue (exit 6, failed strips reported); a worker killed mid-strip: its tools are stopped, its strip requeued, the worker started again, every strip done |
| diskfull | a disk that stays full stops the ink workers and the run (exit != 0), strips kept in the queue |
| tracetimeout | a hung stitcher is stopped by `TRACE_TIMEOUT` and the run still finishes |
| growtimeout | a grower that hangs is stopped by `GROW_TIMEOUT` (TERM; KILL 30 s later if it ignores TERM); its box goes on with the other growers' patches and the run finishes |
| noumb | a config whose scroll-axis file is missing stops at once |
| workerdeath | if the ink workers die mid-run, `run.sh` stops the bands (exit 4) and leaves nothing running |
| boxfail | a box whose growth keeps failing: the failed pass is detected, the band is tried again (`BAND_TRIES`), then the run ends NOT COMPLETE naming that band (exit 5) while the other band finishes |
| resume | a run stopped during growth continues on restart and finishes every strip |
| stop | `stop.sh` mid-ink, with stand-in tools that ignore TERM (as the stitcher can): it returns when nothing of the run is left (they get KILL), a second `run.sh` meanwhile is refused at once, a restart right after the stop finishes every strip, the interrupted strips requeued |
| orphans | after `kill -9` of `run.sh` its workers keep running: `stop.sh` ends them; a process still holding the run's lock makes the next `run.sh` wait, then finish the search |
| extraseeds | `SEEDS_EXTRA`: a seed point inside the band joins its seeds (only the box that holds it), one outside is ignored; that box's first strip starts at the patch grown there, and that try comes on top of `MAXTRY`; when the stitcher stalls there, that patch is inked itself (`x_<name>`, counted in the summary), and when a strip reaches the point it is not; a point listed by two boxes counts once in the summary, and only one that no box inked or reached is warned about; machine.txt records the setting |
| nodata | maps are 0 wherever their input layers had no data (a stand-in comb there is removed), unchanged elsewhere; `NODATA=0` keeps raw maps; a bad `NODATA_MARGIN` stops the run |
| check | the check reads only the run's model's reference maps at their windows, with the config's batch size; no maps for the model, or maps from another checkpoint: exit 2; a damaged reference (vs `SHA256SUMS`) or a changed map: FAIL |
| safety | a checkpoint holding Python objects is refused (weights-only load); a wrong checksum is refused |
| dryrun | `band.sh` with `DRYRUN=1` plans boxes only |

## `run_real_box.sh` — the real VC3D tools on real public data

```bash
tests/run_real_box.sh /path/to/python /path/to/vc3d/squashfs-root/AppRun /path/to/test-home
```

Seed planning and the mask filter on PHerc. 0343's real prediction and scan, one small box grown and stitched with
VC3D, its strips rendered from the scan; only the ink step is a stand-in. Downloads ~1-3 GB of public data
(the prediction's normal grids alone are ~2 GB) into the test home. Takes a few minutes on 16 CPU threads.

The ink model itself, the GPU and the same-answer check against real reference maps are tested on a GPU machine
(`kit/work/check.sh`), not here.
