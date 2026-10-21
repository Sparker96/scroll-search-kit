#!/bin/bash
# box.sh — growth and stitching for one box of one scroll band. Started by band.sh; settings from CONFIG (config/*.env).
# 1 local copy of the box's part of the surface prediction -> 2 seed patches -> 3 expansion pass 1 (tgt_overlap_count
# 10) -> 4 expansion pass 2 (tgt_overlap_count 30) -> 5 stitched strips (vc_grow_seg_from_segments, same_surface_th 4,
# each started from the most-overlapped patch that no earlier strip covers), or with COVER=1 a cover of the grown patches
# instead (cover.py). The config's own seed points (SEEDS_EXTRA) start the first strips (on top of MAXTRY), and a point
# that nothing inked reaches gets the patch grown at it inked as it is. Every kept strip (or picked patch) goes straight
# into the run's ink queue (inkq.sh), which renders it and reads it with the ink model on whichever GPU is free.
# The stitcher needs dense overlap: with ~11 overlapping patches per patch it stalls, with ~30 it fills the box, hence
# the two expansion passes. It is not deterministic from run to run.
# Environment from band.sh: CONFIG, RUN, BOX "z0 z1 y0 y1 x0 x1", SEEDS (tsv: name x y z ...), OUT (this box's folder),
#   GROWER_SLOTS (growers at once in the whole run, shared through RUN/slots/; PAR when run alone). Writes OUT/timing.tsv (one line per phase) and OUT/.stitched when done. Resumable: each
#   phase leaves a marker, so the same command continues where it stopped.
# Growers run with 1-thread OpenBLAS/OpenMP pools: their default (one thread per CPU thread, ~360 threads each on a
# 128-thread machine) made ~119 growers hit a rented container's 31k thread limit, after which growers hung or failed.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_config "${CONFIG:?CONFIG required}" || exit 1
: "${BOX:?BOX=\"z0 z1 y0 y1 x0 x1\" required}" "${SEEDS:?SEEDS tsv required}" "${OUT:?OUT required}"
read -r Z0 Z1 Y0 Y1 X0 X1 <<< "$BOX"
NSLOTS=${GROWER_SLOTS:-${PAR:-12}}; SLOTDIR=${SLOTDIR:-${RUN:-$OUT}/slots}
PRED=$OUT/pred_local.zarr; PATCHES=$OUT/patches; TRACES=$OUT/traces; TIM=$OUT/timing.tsv
G=$HOME/data/normal-grids/$S   # shared by all boxes of the scroll
export TORCHDYNAMO_DISABLE=1
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1   # growers; stitching below sets OMP_NUM_THREADS=$STITCH_THREADS
mkdir -p "$OUT/logs" "$PATCHES" "$TRACES" "$G" "$SLOTDIR"
# the growers read the prediction's normal grids remotely through this marker file (rewritten if the URL changed)
marker=$(printf '{"url": "%s"}' "$NORMAL_GRIDS_URL")
[ "$(cat "$G/normal-grids-remote.json" 2> /dev/null)" = "$marker" ] \
  || { echo "$marker" > "$G/.marker.$$" && mv "$G/.marker.$$" "$G/normal-grids-remote.json"; }
{ [ -s "$SEEDS" ] && [ -s "$UMBILICUS" ] && [ -x "$VC" ] && [ -s "$WORK/next_start.py" ]; } || { echo "inputs missing"; exit 1; }
[ -s "$TIM" ] || printf 'phase\tseconds\tdetail\n' > "$TIM"
# a box that gave up before (OUT/.failed) starts again from its last good step; band.sh counts it failed until then
fail() { echo "BOX FAILED: $*"; echo "$*" > "$OUT/.failed"; exit 1; }
if [ -e "$OUT/.failed" ]; then
  echo "retrying after: $(cat "$OUT/.failed")"; rm -f "$OUT/.failed" "$OUT/.stitched"
fi
tim() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TIM"; }
npatch() { local n=0 p; for p in "$PATCHES"/auto_grown_*; do [ -d "$p" ] && n=$((n + 1)); done; echo "$n"; }
# summed grower seconds of the logs matching a pattern (thread-seconds: growers run with 1-thread pools)
grower_s() { cat "$OUT"/logs/$1.log.secs 2> /dev/null | awk '{s += $1} END {print s + 0}'; }
sumcm() {
  local p
  for p in "$PATCHES"/auto_grown_*; do
    "$PY" -I -c "import json, sys; print(json.load(open(sys.argv[1])).get('area_cm2', 0))" "$p/meta.json" 2> /dev/null
  done | awk '{s += $1} END {printf "%.1f", s}'
}
enqueue() {  # trace k
  if [ -n "${RUN:-}" ]; then bash "$WORK/inkq.sh" add "$RUN" "$1" "$OUT" "$2"; else echo "no RUN set: $2 not queued for ink"; fi
}
# the config's own seed points (SEEDS_EXTRA, named x_ by band.sh): strips start at the patches grown there first
# (next_start.py --first). A point that no inked strip (or picked patch) then reaches gets the patch grown at it inked as
# it is, named x_<name>: a stitcher started at such a point often stalls at once (11 of 12 starts at known letters did
# in two runs of the quick PHerc. 0343 control). The points' states (OUT/seeds_extra.ink.tsv: name, reached|ink|nopatch,
# patch) are written once, so a resumed box queues the same patches. Boxes overlap, so a point that no patch reached in
# this box may be inked by its neighbour: summary.py counts each point once and warns only about one that no box inked
# or reached. Tries started at these points do not use up MAXTRY: a box gets one more try per point it holds.
first=() nx=0
grep '^x_' "$SEEDS" > "$OUT/seeds_extra.tsv" && first=(--first "$OUT/seeds_extra.tsv") && nx=$(wc -l < "$OUT/seeds_extra.tsv")
ink_extra_seeds() {  # the tifxyz folders inked so far
  local xt=$OUT/seeds_extra.ink.tsv name st p
  [ "${#first[@]}" -gt 0 ] || return 0
  if [ ! -e "$xt" ]; then
    "$PY" -I "$WORK/next_start.py" "$PATCHES" "$@" --tol "$START_TOL" --min-area "$START_MIN_AREA" "${first[@]}" \
        --list-first > "$xt.part" && mv "$xt.part" "$xt" || { rm -f "$xt.part"; fail "seed point check failed"; }
  fi
  while IFS=$'\t' read -r name st p; do
    echo "seed point $name: $st"
    [ "$st" = ink ] && [ -d "$p" ] && enqueue "$p" "${name//[^A-Za-z0-9_.-]/-}"
  done < "$xt"
}
T=5
echo "PROGRESS 0/$T local prediction copy"
if [ ! -e "$PRED/.done" ]; then
  t=$(date +%s)
  retry "$NET_TRIES" "$PY" -I "$WORK/zarr_region.py" "$PRED_URL" "$PRED" --box "$Z0" "$Z1" "$Y0" "$Y1" "$X0" "$X1" \
      --threads 16 && touch "$PRED/.done" || fail "prediction copy failed"
  tim copy $(( $(date +%s) - t )) "$(du -sh "$PRED" | cut -f1)"
fi
seedp=$OUT/seed_params.json; exp1=$OUT/expansion_params.json; exp2=$OUT/expansion_params_30.json
for f in "seed $seedp 0" "expansion $exp1 10" "expansion $exp2 30"; do
  read -r mode file tgt <<< "$f"
  printf '{"mode": "%s", "generations": %d, "thread_limit": 1, "voxelsize": %s, "use_cuda": false, "min_area_cm": 0.2, %s"cache_size": 1000000000, "normal_grid_path": "%s", "snap_weight": 1.0}\n' \
    "$mode" "$GENS" "$VOXEL_UM" "$( [ "$tgt" -gt 0 ] && printf '"tgt_overlap_count": %d, ' "$tgt")" "$G" > "$file"
done
# start one grower as soon as one of the run's grower slots is free. The slots are shared by every box of every band,
# so a box that has finished leaves its CPU threads to the others. A slot is a lock file: the grower inherits the
# locked descriptor and holds it until it exits, however it exits (the kernel drops the lock).
grow_one() {  # LOG, then vc_grow_seg_from_seed's arguments
  local log=$1 i fd; shift
  while :; do
    for i in $(seq 1 "$NSLOTS"); do
      exec {fd}> "$SLOTDIR/$i"
      if flock -n "$fd"; then
        # the grower's own wall time goes next to its log: growers are 1-thread, so these add up to CPU-thread-seconds
        ( t0=$(date +%s); timeout -k 30 "$GROW_TIMEOUT" nice -n "$GROW_NICE" "$VC" vc_grow_seg_from_seed "$@" < /dev/null > "$log" 2>&1
          echo $(( $(date +%s) - t0 )) > "$log.secs" ) &
        exec {fd}>&-
        return 0
      fi
      exec {fd}>&-
    done
    sleep 1
  done
}
# launch N growers with params P; MAX seconds after the first launch (0 = no limit) launch no more and let the running
# ones finish (the clock starts at the first launch, not while waiting for a slot). Sets LAUNCHED.
grow_n() {
  local p=$1 n=$2 mx=$3 tag=$4 i=0 dl=0
  while [ "$i" -lt "$n" ]; do
    if [ "$dl" -gt 0 ] && [ "$(date +%s)" -ge "$dl" ]; then echo "$tag: time limit reached after $i growers"; break; fi
    i=$((i + 1))
    grow_one "$OUT/logs/${tag}_$i.log" "$PRED" "$PATCHES" "$p"
    [ "$i" = 1 ] && [ "$mx" -gt 0 ] && dl=$(( $(date +%s) + mx ))
  done
  wait
  LAUNCHED=$i
}
echo "PROGRESS 1/$T seeding"
if [ ! -e "$OUT/.seeded" ]; then
  t=$(date +%s)
  while IFS=$'\t' read -r name x y z _; do
    grow_one "$OUT/logs/seed_$name.log" "$PRED" "$PATCHES" "$seedp" "$x" "$y" "$z"
  done < "$SEEDS"
  wait; touch "$OUT/.seeded"
  tim seed $(( $(date +%s) - t )) "$(npatch) patches from $(grep -c . "$SEEDS") seeds, $(grower_s 'seed_*') grower-s"
fi
if [ "$(npatch)" = 0 ]; then rm -f "$OUT/.seeded"; fail "no seed patch grew"; fi
for pass in 1 2; do
  [ -e "$OUT/.expanded$pass" ] && continue
  echo "PROGRESS $((pass + 1))/$T growth pass $pass"
  [ -s "$OUT/n_before$pass" ] || npatch > "$OUT/n_before$pass"
  if [ "$pass" = 1 ]; then n=$NEXP1; mx=$GROW1_MAX; pf=$exp1; else n=$NEXP2; mx=$GROW2_MAX; pf=$exp2; fi
  t=$(date +%s)
  # a pass spends a launch budget; if fewer than half of its launches gave a patch, growers are failing for a common
  # reason (the rented run's thread limit: 1 patch from 21 launches), so try again after a pause, then give up
  for try in 1 2 3; do
    before=$(npatch); need=$(( n + $(cat "$OUT/n_before$pass") - before ))
    [ "$need" -gt 0 ] || break
    grow_n "$pf" "$need" "$mx" "exp${pass}t$try"
    gained=$(( $(npatch) - before ))
    echo "pass $pass try $try: $gained patches from $LAUNCHED launches"
    [ $(( 2 * gained )) -ge "$LAUNCHED" ] && break
    [ "$try" = 3 ] && fail "growth pass $pass: only $gained patches from $LAUNCHED launches, 3 tries"
    sleep $(( PASS_PAUSE * try ))
  done
  touch "$OUT/.expanded$pass"
  tim "expand$pass" $(( $(date +%s) - t )) "$(npatch) patches, $(sumcm) cm2 summed, $(grower_s "exp${pass}t*") grower-s, slots $NSLOTS (shared), $GENS generations"
done
# COVER=1: ink a cover of the grown patches themselves instead of stitched strips (cover.py: greedy, most new area
# first, until the picks cover COVER_FRAC of the patches' union). With MASK_CHECK=1 every node is checked against the
# scan's mask first: patches mostly outside it would render empty and are left out (OUT/cover.outside.tsv), and only
# nodes inside count for the cover. DROP_SINGLE=1 also leaves out patches that no other patch comes near. The pick list
# (OUT/cover.tsv) is made once and kept, so a resumed box queues the same patches.
if [ "$COVER" = 1 ]; then
  echo "PROGRESS 4/$T cover of the patch cloud"
  ct=$OUT/cover.tsv
  if [ ! -s "$ct" ]; then
    t=$(date +%s); ds=; [ "$DROP_SINGLE" = 1 ] && ds=--drop-single
    mk=(); [ "$MASK_CHECK" = 1 ] && mk=(--mask "$VOL_URL")
    out=$("$PY" -I "$WORK/cover.py" "$PATCHES" "$ct" --frac "$COVER_FRAC" "${mk[@]}" $ds --min-cm2 "$MINCM" --vx "$VOXEL_UM" 2>&1) \
      || fail "patch cover failed: $(tail -n 1 <<< "$out")"
    echo "$out"; tim cover $(( $(date +%s) - t )) "$(tail -n 1 <<< "$out")"
  fi
  n=0 picks=()
  while IFS=$'\t' read -r name pick _; do
    [ "$name" = patch ] && continue
    [ -d "$PATCHES/$name" ] && { enqueue "$PATCHES/$name" "p$pick"; picks+=("$PATCHES/$name"); n=$((n + 1)); }
  done < "$ct"
  echo "cover patches queued: $n"
  ink_extra_seeds "${picks[@]}"
  if [ "$n" = 0 ] && [ -n "${RUN:-}" ]; then
    echo "$(date '+%F %T') WARNING: $(basename "$(dirname "$OUT")")/$(basename "$OUT"): no patch to cover ($(npatch) patches grown, MINCM $MINCM)" >> "$RUN/alerts.log"
  fi
  touch "$OUT/.stitched"
  echo "PROGRESS $T/$T cover queued for ink"
  tail -n +2 "$TIM"; du -sh "$OUT"; echo "end $(date -Is)"
  exit 0
fi
echo "PROGRESS 4/$T stitching"
export OMP_NUM_THREADS=$STITCH_THREADS
tp=$OUT/tracer_params.json
printf '{"flip_x": 1, "global_steps_per_window": 1, "step": 6, "consensus_default_th": 10, "consensus_limit_th": 2, "z_range": [%d, %d], "use_cuda": false, "same_surface_th": 4}\n' "$Z0" "$Z1" > "$tp"
kept=0 inked=()   # inked = this box's strips that went to the ink queue (MIN_NEW measures against them)
for k in $(seq 1 $((MAXTRY + nx))); do
  [ "$kept" -ge "$NTR" ] && break
  td=$TRACES/t$k
  # a stop that came after the stitcher finished but before .done: that trace is whole (VC3D renames a trace only when
  # it is complete), so it is checked and queued below instead of being stitched again from another start
  if [ ! -e "$td/.done" ] && compgen -G "$td/auto_trace_*" > /dev/null; then
    t=$(date +%s); start=$(cat "$td/start.txt" 2> /dev/null); rc=0
    echo "trace t$k: finished before a stop, kept"
  elif [ ! -e "$td/.done" ]; then
    mkdir -p "$td"
    cat "$TRACES"/t*/start.txt 2> /dev/null > "$OUT/used_starts.txt"
    done_traces=()
    for tr in "$TRACES"/t*/auto_trace_*; do [ -d "$tr" ] && done_traces+=("$tr"); done
    start=$("$PY" -I "$WORK/next_start.py" "$PATCHES" "${done_traces[@]}" --exclude "$OUT/used_starts.txt" --by overlaps \
        --max-covered "$START_MAX_COVERED" --tol "$START_TOL" --min-area "$START_MIN_AREA" "${first[@]}")
    [ -n "$start" ] || { echo "no uncovered start patch left"; rmdir "$td" 2> /dev/null; break; }
    echo "$start" > "$td/start.txt"
    t=$(date +%s)
    # a hung stitcher would keep the box (and the run) from ever finishing: TRACE_TIMEOUT stops it
    timeout -k 30 "$TRACE_TIMEOUT" nice -n "$GROW_NICE" "$VC" vc_grow_seg_from_segments --volume "$PRED" --src-dir "$PATCHES" --target-dir "$td" \
        --params "$tp" --src-segment "$start" < /dev/null > "$td/trace.log" 2>&1
    rc=$?
  fi
  if [ ! -e "$td/.done" ]; then
    # timeout's -k sends KILL to a stitcher that ignores TERM, and then exits 137, not 124
    if [ "$rc" = 124 ] || { [ "$rc" = 137 ] && [ $(( $(date +%s) - t )) -ge "$TRACE_TIMEOUT" ]; }; then
      echo "trace t$k stopped by TRACE_TIMEOUT (${TRACE_TIMEOUT}s)"
    elif [ "$rc" != 0 ]; then
      echo "trace t$k FAILED (exit $rc): $(tail -n 2 "$td/trace.log" | tr '\n' ' ' | cut -c1-200)"
    fi
    tr=   # VC3D writes a trace under a temporary name and renames it when complete, so one that exists is whole
    for x in "$td"/auto_trace_*; do [ -d "$x" ] && { tr=$x; break; }; done
    cm=0; [ -n "$tr" ] && cm=$(area "$tr")
    maxcm=$(awk -v a="${maxcm:-0}" -v b="$cm" 'BEGIN {print (b > a ? b : a)}')
    tim trace $(( $(date +%s) - t )) "t$k from $(basename "$start"): ${cm} cm2"
    if [ -n "$tr" ] && "$PY" -I -c "import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)" "$cm" "$MINCM"; then
      # MIN_NEW: a strip that adds too little new area to the box's inked strips is kept but not inked (and does not
      # count towards NTR); the decision is written before .done, so a stop in between cannot slip it into the queue
      pct=100
      if [ "$MIN_NEW" -gt 0 ] && [ "${#inked[@]}" -gt 0 ]; then
        read -r pct newcm _ < <("$PY" -I "$WORK/new_area.py" "$tr" "${inked[@]}" --vx "$VOXEL_UM")
      fi
      if [ "${pct:-100}" -lt "$MIN_NEW" ]; then
        echo "new ${pct} % = ${newcm} of ${cm} cm2" > "$td/.setaside"
        echo "trace t$k: ${newcm} of ${cm} cm2 new (${pct} %) < MIN_NEW ${MIN_NEW} %: kept, not inked"
        tim setaside 0 "t$k ${newcm} of ${cm} cm2 new (${pct} %)"
      else
        kept=$((kept + 1)); enqueue "$tr" "t$k"; inked+=("$tr")
      fi
    elif [ -n "$tr" ]; then
      mv "$tr" "$td/small_$(basename "$tr")"   # small strips are set aside, not searched
    fi
    touch "$td/.done"
  else
    [ -e "$td/.setaside" ] && continue   # kept, not inked (MIN_NEW)
    for x in "$td"/auto_trace_*; do [ -d "$x" ] && { kept=$((kept + 1)); enqueue "$x" "t$k"; inked+=("$x"); break; }; done
  fi
done
ink_extra_seeds "${inked[@]}"
echo "kept strips: $kept"
if [ "$kept" = 0 ] && [ -n "${RUN:-}" ]; then
  echo "$(date '+%F %T') WARNING: $(basename "$(dirname "$OUT")")/$(basename "$OUT"): no strip kept (largest ${maxcm:-0} cm2, MINCM $MINCM;" \
       "$(npatch) patches grown)" >> "$RUN/alerts.log"
fi
touch "$OUT/.stitched"
echo "PROGRESS $T/$T stitched; strips are in the ink queue"
tail -n +2 "$TIM"; du -sh "$OUT"; echo "end $(date -Is)"
