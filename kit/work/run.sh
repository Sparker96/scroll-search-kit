#!/bin/bash
# run.sh CONFIG — search the bands listed in one scroll's config on this machine, unattended.
# 1 records the run in RUN/ (config, software versions, machine); 2 starts a metrics line per minute (RUN/metrics.tsv,
# read by usage.py); 3 runs the same-answer check on the control strip (check.sh) and stops unless it passes (CHECK=0
# skips it); 4 starts the ink workers (inkq.sh, INK_PER_GPU per GPU); 5 grows and stitches the bands (band.sh,
# BANDS_IN_FLIGHT at once, all growers sharing one slot pool), every box queueing its strips for ink as it goes, so the
# GPUs work while bands grow; 6 closes the queue, waits for the last maps and writes RUN/summary.txt (summary.py).
# Resumable: run the same command again and it continues where it stopped. Nothing is deleted, except that DEL_ZARR=1
# removes each strip's temporary 61-layer volume once its maps are saved.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_config "${1:?usage: run.sh CONFIG}" || exit 1
mkdir -p "$RUN"
# one run.sh per results folder: a second one would reopen the queue and stop the first one's metrics. Every process
# run.sh starts inherits this lock, so it is free only once nothing of an earlier run is left: a stopped run's tools can
# take seconds to end. Wait for those (up to 2 min), not for a run.sh that is still running. The wait does not open
# the lock file: a stopping run.sh, or stop.sh, ends every process that holds it open.
left=$(holders "$RUN/.run.lock")
if [ -n "$left" ]; then
  old=$(cat "$RUN/run.pid" 2> /dev/null)
  still_running() { grep -qx -- "$old" <<< "$(holders "$RUN/.run.lock")" && [ "$(cut -d' ' -f1 "$RUN/state" 2> /dev/null)" = running ]; }
  # (looked at twice, 2 s apart: a run.sh sent TERM a moment ago may not have marked itself "stopping" yet)
  if [ -n "$old" ] && still_running && sleep 2 && still_running; then
    echo "another run.sh ($old) is already using $RUN (bash $WORK/stop.sh $RUN stops it)"; exit 1
  fi
  echo "$(ts) waiting up to 120 s for the last run in $RUN to end ($(wc -w <<< "$left") process(es) left)"
  for _ in $(seq 120); do sleep 1; left=$(holders "$RUN/.run.lock"); [ -z "$left" ] && break; done
  if [ -n "$left" ]; then
    echo "processes of the last run still use $RUN after 120 s:"; ps -o pid=,etime=,args= -p "${left//$'\n'/,}" | cut -c1-200
    echo "end them with: bash $WORK/stop.sh $RUN, then start run.sh again"; exit 1
  fi
fi
exec 7> "$RUN/.run.lock"
flock -n 7 || { echo "another run.sh is already using $RUN"; exit 1; }
echo $$ > "$RUN/run.pid"; echo running > "$RUN/state"   # for watch.sh and stop.sh
echo "$CONFIG" > "$RUN/config.path"
cp "$CONFIG" "$RUN/config-$(date +%Y%m%d-%H%M%S).env"
{
  echo "start $(date -Is) on $(hostname): $(nproc) CPU threads, $(free -g | awk '/Mem:/ {print $2}') GB RAM," \
       "$(df -P -BG "$RUN" | awk 'NR == 2 {print $2}') disk, pids.max $(cat /sys/fs/cgroup/pids.max 2> /dev/null || echo none)"
  nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader 2> /dev/null
  cat "$HOME/.kit-versions" 2> /dev/null
  echo "kit files:"; (cd "$WORK" && sha256sum ./*.sh ./*.py 2> /dev/null; cat "$HOME/kit/VERSION" 2> /dev/null)
  echo "effective settings (config + defaults):"
  for v in S VOL_URL PRED_URL NORMAL_GRIDS_URL VOXEL_UM UMBILICUS SEEDS_EXTRA BANDS MODEL_URL MODEL_SHA256 PREFIX BATCH_SIZE \
           MODEL_DEPTH GRID MARGIN RAYS FRACS GENS NEXP1 NEXP2 GROW1_MAX GROW2_MAX GROW_TIMEOUT NTR MAXTRY MINCM \
           START_MAX_COVERED START_TOL START_MIN_AREA TRACE_TIMEOUT STITCH_THREADS BANDS_IN_FLIGHT NUM_SLICES CENTRES \
           INK_PER_GPU INK_OMP INK_NUM_WORKERS RENDER_CACHE_GB RENDER_RETRIES RENDER_TIMEOUT INK_TIMEOUT GPU_FAIL_MAX \
           DEL_ZARR MIN_FREE_GB DISK_WAITS CACHE_EVICT NET_TRIES CHECK MASK_CHECK GROWER_GB RESERVE_GB RESERVE_THREADS \
           BAND_TRIES BAND_PAUSE PASS_PAUSE PREFLIGHT NODATA NODATA_MARGIN WORKER_RESTARTS WORKER_PAUSE GROW_NICE MIN_NEW COVER COVER_FRAC DROP_SINGLE; do
    printf '  %s=%s\n' "$v" "${!v:-}"
  done
} >> "$RUN/machine.txt"
echo "start $(date +%s)" >> "$RUN/times.txt"   # wall-clock segments for summary.py (a resumed run adds one)
rm -f "$RUN/.stop-metrics"
bash "$WORK/metrics.sh" "$RUN" &
MPID=$!
stop_metrics() { touch "$RUN/.stop-metrics"; }
# stopping run.sh stops everything it started (growers, renders, ink workers), so no orphan keeps the queue locked
# parents first: a worker killed after its render would see the render die and file the strip as failed; killed
# first, it leaves the strip in running/, and the next start puts it back in the queue
descendants() { local c; for c in $(pgrep -P "$1"); do echo "$c"; descendants "$c"; done; }
kill_tree() { local all; all="$1 $(descendants "$1")"; kill $all 2> /dev/null; }
kill_children() { local c; for c in $(pgrep -P $$); do kill_tree "$c"; done; }
on_stop() { trap - INT TERM; echo "stopping $(date -Is)"; exit 130; }
# any exit (a stop or an error included) takes everything run.sh started with it: TERM to each child's tree, then TERM
# and, after 10 s, KILL to whatever still holds the run's lock (the stitcher ignores TERM; a tool started while the
# trees were being listed is in none of them). run.sh ends when nothing of the run is left, so it can start again at
# once. Then it closes this wall-clock segment.
on_exit() {
  trap '' INT TERM   # a second stop signal must not cut the clean-up short
  echo "stopping $1 $(date -Is)" > "$RUN/state"
  stop_metrics; kill_children; end_holders "$RUN/.run.lock" 10
  echo "end $(date +%s)" >> "$RUN/times.txt"; echo "finished $1 $(date -Is)" > "$RUN/state"
}
trap 'on_exit $?' EXIT
trap on_stop INT TERM
nb=$(wc -w <<< "$BANDS")
# the ink model first: a download, checksum, safety or depth problem must stop the run now, not after hours of growth
MODEL_FILE=$(install_model "$MODEL_URL" "$MODEL_SHA256" "$PREFIX") || { echo "ink model not usable: not searching"; exit 3; }
D=$(model_depth "$MODEL_FILE") || exit 3
[ -n "$(window_starts "$D")" ] || { echo "no ink window of depth $D fits in $NUM_SLICES layers"; exit 3; }
echo "PROGRESS 0/$((nb + 2)) same-answer check"
# the check's reference maps are 61-layer renders: with other settings it would not describe this run
if [ "$CHECK" = 1 ] && [ "$NUM_SLICES" != 61 ]; then
  echo "NUM_SLICES=$NUM_SLICES but the same-answer check covers 61-layer renders only: use 61, or CHECK=0 knowingly"; exit 2
fi
# the check reads the control with this run's model, render cache, batch size and data-loading workers
if [ "$CHECK" = 1 ] && [ ! -e "$RUN/.check-passed" ]; then
  # in the background + wait, so a stop signal is handled at once; the exit code is check.sh's, not tee's
  ( bash "$WORK/check.sh" "$RUN/check" "$CONFIG" 2>&1 | tee "$RUN/check.log"; exit "${PIPESTATUS[0]}" ) &
  wait $!; rc=$?
  case $rc in
    0) touch "$RUN/.check-passed" ;;
    2) echo "same-answer check NOT POSSIBLE for model $PREFIX: not searching (the control needs reference maps made by" \
            "this checkpoint; CHECK=0 in the config runs without the check, knowingly)"; exit 2 ;;
    3) echo "ink model not usable: not searching"; exit 3 ;;
    *) echo "same-answer check FAILED: not searching (see $RUN/check/check.tsv; CHECK=0 in the config skips it)"; exit 2 ;;
  esac
fi
# model preflight: one window of the configured model, with the run's batch size and data-loading workers, through the
# same inference path, on the control strip; its depth must match the kit's. A model that cannot run fails here, now.
if [ "$PREFLIGHT" != 1 ]; then
  echo "WARNING: model preflight skipped (PREFLIGHT=0)" | tee -a "$RUN/alerts.log"
elif [ ! -e "$RUN/.preflight-ok" ]; then
  if [ ! -e "$RUN/check/control_61.zarr/.done" ]; then
    CHECK_RENDER_ONLY=1 bash "$WORK/check.sh" "$RUN/check" > "$RUN/preflight-render.log" 2>&1 &
    wait $!
  fi
  mid=$(window_starts "$D" | tr ' ' '\n' | awk '{a[NR] = $1} END {print a[int((NR + 1) / 2)]}')
  mkdir -p "$RUN/preflight"
  (cd "$VILLA" && CUDA_VISIBLE_DEVICES=0 timeout -k 60 "$INK_TIMEOUT" "$PY" -I "$WORK/infer_windows.py" \
      "$RUN/check/control_61.zarr" "$MODEL_FILE" "$RUN/preflight" --starts "$mid" --direction forward --prefix "$PREFIX" \
      --no-compile --overlap 0.5 --blend-mode hann --batch-size "$BATCH_SIZE" --num-workers "$INK_NUM_WORKERS" \
      < /dev/null > "$RUN/preflight/infer.log" 2>&1) &
  wait $!
  got_d=$(sed -n 's/^input_depth \([0-9]*\)$/\1/p' "$RUN/preflight/infer.log" | head -n 1)
  if [ "$(count_maps "$RUN/preflight" "$PREFIX")" -lt 1 ] || [ "$got_d" != "$D" ]; then
    echo "MODEL PREFLIGHT FAILED: $PREFIX made $(count_maps "$RUN/preflight" "$PREFIX") map(s); inference depth '${got_d:-?}' vs kit depth $D"
    tail -n 5 "$RUN/preflight/infer.log"; exit 3
  fi
  touch "$RUN/.preflight-ok"; echo "model preflight OK: $PREFIX, depth $D, windows at $(window_starts "$D")"
fi
rm -f "$RUN/queue/.closed"
bash "$WORK/inkq.sh" workers "$RUN" >> "$RUN/ink.log" 2>&1 &
WPID=$!
sleep 5 & wait $!   # (pauses in the background + wait, here and below: bash runs a trap only between commands)
kill -0 "$WPID" 2> /dev/null || { echo "ink workers did not start:"; tail -n 5 "$RUN/ink.log"; exit 3; }
i=0
# growers of every box of every band share one pool of slots, so CPU threads never sit in a finished box
GROWER_SLOTS=$(grower_slots); export GROWER_SLOTS
mkdir -p "$RUN/slots"
echo "grower slots: $GROWER_SLOTS (shared by all boxes), up to $BANDS_IN_FLIGHT bands growing at once"
if [ "$GROWER_SLOTS" -lt 8 ]; then
  echo "$(date '+%F %T') WARNING: only $GROWER_SLOTS grower slots ($(nproc) CPU threads, $(mem_total_gb) GB RAM): growth will be" \
       "slow and the patch clouds thin, so strips may be too small to keep (RESERVE_THREADS / RESERVE_GB set the reserve)" \
    | tee -a "$RUN/alerts.log"
fi
# bands run BANDS_IN_FLIGHT at a time; a band that fails is tried again later (BAND_TRIES in all, 5 min apart per try:
# its boxes resume where they stopped); one that keeps failing is reported at the end, never dropped silently
declare -A bpid=() btry=() nbefore=()   # "=()": empty but set, which set -u needs
read -r -a todo <<< "$BANDS"
failed_bands=()
alive_bands() { echo "${#bpid[@]}"; }
# the ink workers must stay alive while bands grow, or hours of growth would end with no maps
check_workers() {
  kill -0 "$WPID" 2> /dev/null && return 0
  echo "ink workers stopped (see $RUN/ink.log and alerts.log): stopping the run $(date -Is)"
  local p; for p in "${bpid[@]}"; do kill_tree "$p"; done; exit 4
}
while [ "${#todo[@]}" -gt 0 ] || [ "$(alive_bands)" -gt 0 ]; do
  check_workers
  for b in "${!bpid[@]}"; do
    kill -0 "${bpid[$b]}" 2> /dev/null && continue
    wait "${bpid[$b]}"; rc=$?; unset "bpid[$b]"
    if [ "$rc" = 0 ]; then echo "band z ${b/:/-} grown ($(date +%T))"; continue; fi
    btry[$b]=$(( ${btry[$b]:-1} + 1 ))
    if [ "${btry[$b]}" -le "$BAND_TRIES" ]; then
      echo "band z ${b/:/-} failed (exit $rc, see band-${b/:/-}.log): try ${btry[$b]} of $BAND_TRIES in $(( BAND_PAUSE * (btry[$b] - 1) ))s"
      nbefore[$b]=$(( $(date +%s) + BAND_PAUSE * (btry[$b] - 1) )); todo+=("$b")
    else
      echo "band z ${b/:/-} FAILED $BAND_TRIES times: given up (see band-${b/:/-}.log)" | tee -a "$RUN/alerts.log"
      failed_bands+=("$b")
    fi
  done
  while [ "${#todo[@]}" -gt 0 ] && [ "$(alive_bands)" -lt "$BANDS_IN_FLIGHT" ] && [ "$(date +%s)" -ge "${nbefore[${todo[0]}]:-0}" ]; do
    b=${todo[0]}; todo=("${todo[@]:1}"); z0=${b%%:*}; z1=${b##*:}
    i=$((i + 1))
    echo "PROGRESS $i/$((nb + 2)) band z $z0-$z1 started ($(date +%T)); queue: $(bash "$WORK/inkq.sh" status "$RUN")"
    # in the background (+ the loop's waits), so that a stop signal is handled at once: bash runs traps between commands
    bash "$WORK/band.sh" "$z0" "$z1" >> "$RUN/band-$z0-$z1.log" 2>&1 &
    bpid[$b]=$!
    sleep 5 & wait $!
  done
  sleep 20 & wait $!
done
echo "PROGRESS $((nb + 1))/$((nb + 2)) last strips in the ink queue ($(date +%T))"
bash "$WORK/inkq.sh" close "$RUN" > /dev/null
wait "$WPID"; wrc=$?
stop_metrics; wait "$MPID" 2> /dev/null
echo "end $(date +%s)" >> "$RUN/times.txt"
"$PY" -I "$WORK/summary.py" "$RUN" | tee "$RUN/summary.txt"
left=$(bash "$WORK/inkq.sh" status "$RUN")
if [ "$wrc" != 0 ] || ! [[ "$left" =~ pending\ 0\ \ running\ 0 ]]; then
  echo "NOT COMPLETE: ink workers exit $wrc; queue: $left (see alerts.log; restart run.sh to continue)"; exit 5
fi
if [ "${#failed_bands[@]}" -gt 0 ]; then
  echo "NOT COMPLETE: bands not grown after $BAND_TRIES tries: ${failed_bands[*]} (restart run.sh to try them again)"; exit 5
fi
# nothing inked at all is not a finished search, whatever the queue says
if [ "$(find "$RUN/queue/done" -name '*.job' 2> /dev/null | wc -l)" = 0 ]; then
  echo "NOTHING SEARCHED: no strip was inked. $(grep -h 'WARNING' "$RUN/alerts.log" 2> /dev/null | tail -n 5 | sed -E 's/^[0-9-]{10} [0-9:]{8} //' | tr '\n' ' ')"; exit 6
fi
if ! [[ "$left" =~ failed\ 0 ]]; then
  echo "COMPLETE WITH FAILED STRIPS: $left (reasons in queue/failed and ink.tsv; inkq.sh retry RUN failed)"; exit 6
fi
echo "PROGRESS $((nb + 2))/$((nb + 2)) done $(date -Is)"
