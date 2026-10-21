#!/bin/bash
# inkq.sh — the run's ink queue. Every kept strip from every box of every band waits here; INK_PER_GPU workers per GPU
# each take the next strip, render 61 layers around it, work out the written side, read it with the ink model at depths
# -20..+20 and save the maps. No GPU waits for one slow box.
#   inkq.sh add RUN TRACE BOXDIR K     queue one strip (box.sh does this; a strip already known is left alone)
#   inkq.sh workers RUN                run the workers until the queue is closed and empty (run.sh starts this)
#   inkq.sh close RUN                  no more strips will come: workers finish what is queued, then exit
#   inkq.sh status RUN                 counts per state
#   inkq.sh retry RUN blank|failed|outside   put such strips back in the queue (blank ones get a fresh render;
#                                      outside ones get their mask check again)
# Queue: RUN/queue/{pending,running,done,blank,failed,outside}/<band>__<box>__<k>.job, one small text file per strip. A worker
# claims a strip by renaming its file into running/ (a rename is atomic, so two workers never take the same strip).
# A strip is BLANK when its render holds no papyrus (empty depth profile, or the ink step reports "No occupied
# blocks"); it gets RENDER_RETRIES fresh renders, then waits in blank/ with its trace kept for a later re-render.
# A strip whose sampled nodes all lie outside the scan's mask is not rendered at all (outside/, OUTSIDE-MASK).
# Settings from CONFIG (run.sh exports it; otherwise RUN/config.path names it). Alerts go to RUN/alerts.log.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
cmd=${1:-}; RUN=${2:-}
[ -n "$cmd" ] && [ -n "$RUN" ] || { sed -n '2,13p' "$0"; exit 1; }
Q=$RUN/queue
if [ "$cmd" = status ]; then [ -d "$Q" ] || { echo "no queue in $RUN"; exit 1; }   # a typo must not create a queue
else mkdir -p "$Q"/tmp "$Q"/pending "$Q"/running "$Q"/done "$Q"/blank "$Q"/failed "$Q"/outside; fi
alert() { echo "$(ts) $*" | tee -a "$RUN/alerts.log" >&2; }
known() { local st; for st in pending running "done" blank failed outside; do compgen -G "$Q/$st/$1.job*" > /dev/null && return 0; done; return 1; }
jobfile() {  # OUT TRACE BOXDIR K ATTEMPT
  printf 'TRACE=%s\nBOXDIR=%s\nK=%s\nATTEMPT=%s\n' "$2" "$3" "$4" "$5" > "$Q/tmp/${1##*/}.$$" && mv "$Q/tmp/${1##*/}.$$" "$1"
}
readjob() {  # FILE -> TRACE BOXDIR K ATTEMPT (plain KEY=VALUE lines, never executed)
  TRACE=; BOXDIR=; K=; ATTEMPT=0
  local key val
  while IFS='=' read -r key val; do
    case $key in TRACE|BOXDIR|K|ATTEMPT) printf -v "$key" '%s' "$val" ;; esac
  done < "$1"
}

case $cmd in
  add)
    TRACE=${3:?trace}; BOXDIR=${4:?box dir}; K=${5:?strip name}
    id="$(basename "$(dirname "$BOXDIR")")__$(basename "$BOXDIR")__$K"
    known "$id" && exit 0
    jobfile "$Q/pending/$id.job" "$TRACE" "$BOXDIR" "$K" 0 && echo "queued $id"
    exit ;;
  close) touch "$Q/.closed"; echo "queue closed"; exit ;;
  status)
    for st in pending running "done" blank failed outside; do
      n=0; for f in "$Q/$st"/*.job*; do [ -e "$f" ] && n=$((n + 1)); done; printf '%s %s  ' "$st" "$n"
    done
    [ -e "$Q/.closed" ] && printf '(closed)'; echo; exit ;;
  retry)
    from=${3:?blank, failed or outside}
    case $from in blank|failed|outside) ;; *) echo "retry RUN blank|failed|outside"; exit 1 ;; esac
    n=0
    for f in "$Q/$from"/*.job; do
      [ -e "$f" ] || continue
      readjob "$f"; a=$ATTEMPT; [ "$from" = blank ] && a=$((ATTEMPT + 1))
      jobfile "$Q/pending/$(basename "$f")" "$TRACE" "$BOXDIR" "$K" "$a" && rm -f -- "$f" && n=$((n + 1))
    done
    echo "$n $from strips queued again"; exit ;;
  workers) ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac

# ---- workers ----
CONFIG=${CONFIG:-$(cat "$RUN/config.path" 2> /dev/null)}
load_config "${CONFIG:?no CONFIG and no $RUN/config.path}" || exit 1
exec 9> "$Q/.workers.lock"
flock -n 9 || { echo "workers for $RUN are already running"; exit 1; }
# strips a stopped run left half-done go back to the queue
for f in "$Q"/running/*.job.w*; do
  [ -e "$f" ] || continue
  b=$(basename "$f"); mv "$f" "$Q/pending/${b%.w*}" && echo "requeued ${b%.job.w*}"
done
[ -e "$MODEL_FILE.safe" ] || MODEL_FILE=$(install_model "$MODEL_URL" "$MODEL_SHA256" "$PREFIX") || exit 3
D=$(model_depth "$MODEL_FILE") || exit 3
STARTS=$(window_starts "$D"); NSTART=$(wc -w <<< "$STARTS")
[ "$NSTART" -gt 0 ] || { echo "no window of depth $D fits in $NUM_SLICES layers"; exit 3; }
{ printf 'start\tcentre\tdepth\n'
  for s in $STARTS; do c=$(( s + (D - 1) / 2 )); printf '%s\t%s\t%+d\n' "$s" "$c" $(( c - (NUM_SLICES - 1) / 2 )); done
} > "$RUN/windows_$PREFIX.tsv"
NGPU=${NGPU:-$(nvidia-smi --query-gpu=index --format=csv,noheader 2> /dev/null | wc -l)}; [ "$NGPU" -ge 1 ] || NGPU=1
NW=$(( NGPU * INK_PER_GPU ))
echo "$NW" > "$Q/.nworkers"; rm -f "$Q"/.hb.w*
[ -s "$RUN/ink.tsv" ] || printf 'strip\tworker\tgpu\trender_s\tink_s\tmaps\tstate\treason\n' > "$RUN/ink.tsv"
export TORCHDYNAMO_DISABLE=1 OMP_NUM_THREADS=$INK_OMP OPENBLAS_NUM_THREADS=1
echo "$(ts) ink workers: $NW ($INK_PER_GPU per GPU, $NGPU GPUs), model $PREFIX depth $D, windows at $STARTS"

finish() {  # JOBFILE STATE REASON W G RENDER_S INK_S MAPS
  local id; id=$(basename "${1%.w*}" .job)
  printf 'STATE=%s\nREASON=%s\nWORKER=%s\nGPU=%s\n' "$2" "$3" "$4" "$5" >> "$1"
  mv "$1" "$Q/$2/$id.job"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$4" "$5" "$6" "$7" "$8" "$2" "$3" >> "$RUN/ink.tsv"
  echo "$(ts) w$4 $id: $2${3:+ ($3)}"
  LAST_STATE=$2; LAST_REASON=$3
}

again() {  # JOBFILE REASON W G RENDER_S ZARR FINAL_STATE: a fresh render while retries are left, then FINAL_STATE/
  readjob "$1"
  # maps from the bad render are moved aside (not deleted), or the next attempt would skip them as finished
  local d=$BOXDIR/render/$K f
  for f in "$d/$PREFIX"_s*.tif; do
    [ -e "$f" ] && mkdir -p "$d/blank_r$ATTEMPT" && mv -- "$f" "$d/blank_r$ATTEMPT/"
  done
  # a failed or blank render's temporary volume is useless; with DEL_ZARR=1 it goes, like a finished one
  if [ "$DEL_ZARR" = 1 ] && [ -n "${6:-}" ] && [[ "$6" == "$BOXDIR"/render/*.zarr ]]; then rm -rf -- "$6"; fi
  if [ "$ATTEMPT" -lt "$RENDER_RETRIES" ]; then
    local id; id=$(basename "${1%.w*}" .job)
    jobfile "$Q/pending/$id.job" "$TRACE" "$BOXDIR" "$K" $((ATTEMPT + 1)) && rm -f -- "$1"
    printf '%s\t%s\t%s\t%s\t\t0\tretry\t%s\n' "$id" "$3" "$4" "$5" "$2" >> "$RUN/ink.tsv"
    echo "$(ts) w$3 $id: $2, queued for a fresh render"
    LAST_STATE=retry; LAST_REASON=
  else
    finish "$1" "${7:-blank}" "$2" "$3" "$4" "$5" "" 0
  fi
}

scan_ok() { curl -fsS -o /dev/null --max-time 30 "${VOL_URL%/}/0/.zarray" 2> /dev/null || case $VOL_URL in file://*) [ -d "${VOL_URL#file://}" ] ;; *) false ;; esac; }

# while the scan is unreachable (RUN/queue/.net-down), workers check every minute instead of taking strips; after
# NET_DOWN_MAX seconds they stop the run (the meter keeps running while they wait)
net_wait() {
  local age
  [ -e "$Q/.net-down" ] || return 0
  if scan_ok; then rm -f "$Q/.net-down"; alert "NETWORK: the scan is reachable again"; return 0; fi
  age=$(( $(date +%s) - $(stat -c %Y "$Q/.net-down" 2> /dev/null || date +%s) ))
  if [ "$age" -gt "$NET_DOWN_MAX" ]; then
    alert "NETWORK: the scan unreachable for ${age}s: stopping the ink workers"; touch "$Q/.stop"; return 75
  fi
  sleep 60; return 1
}

# CACHE_EVICT=1 only: free disk by deleting the oldest VC3D download-cache files (renders fetch them again on demand).
# Off by default: deleting anything on the machine beyond the strips' own temporary volumes needs the operator's yes.
evict_cache() {
  local C=$HOME/.VC3D/remote_cache target=$(( MIN_FREE_GB + 50 )) n=0 files
  [ -d "$C" ] || return 1
  exec 8> "$Q/.evict.lock"; flock 8
  while [ "$(free_gb "$RUN")" -lt "$target" ]; do
    mapfile -t files < <(find "$C" -type f -mmin +30 -printf '%T@ %p\n' 2> /dev/null | sort -n | head -n 2000 | cut -d' ' -f2-)
    [ "${#files[@]}" -gt 0 ] || break
    rm -f -- "${files[@]}"; n=$((n + ${#files[@]}))
  done
  flock -u 8
  alert "CACHE_EVICT: removed $n VC3D download-cache files; $(free_gb "$RUN") GB free"
  [ "$n" -gt 0 ]
}

work_one() {  # JOBFILE W G -> 0, or 75 = stop (no disk), with the strip put back in the queue
  local jf=$1 w=$2 g=$3 d Z zn dep rl t rs is dir got want cm rc waits=0
  readjob "$jf"
  [ -d "$TRACE" ] || { finish "$jf" failed "trace missing" "$w" "$g" "" "" 0; return 0; }
  d=$BOXDIR/render/$K; mkdir -p "$d"
  zn=${K}_$NUM_SLICES; dep=$d/depth.tsv; rl=$d/render.log
  if [ "$ATTEMPT" -gt 0 ]; then zn=${zn}_r$ATTEMPT; dep=$d/depth_r$ATTEMPT.tsv; rl=$d/render_r$ATTEMPT.log; fi
  Z=$d/$zn.zarr
  if [ "$MASK_CHECK" = 1 ] && [ ! -e "$Z/.done" ]; then
    "$PY" -I "$WORK/mask_check.py" trace "$VOL_URL" "$TRACE" > "$d/mask.txt" 2>&1
    case $? in
      0) ;;
      3) finish "$jf" outside "OUTSIDE-MASK" "$w" "$g" "" "" 0; return 0 ;;
      *) echo "$(ts) w$w $K: mask check failed ($(tail -n 1 "$d/mask.txt" | cut -c1-100)), rendering anyway" ;;
    esac
  fi
  # free disk: wait (bounded), optionally evict the download cache, otherwise stop the run loudly
  while [ "$(free_gb "$RUN")" -lt "$MIN_FREE_GB" ]; do
    if [ "$CACHE_EVICT" = 1 ] && evict_cache; then continue; fi
    waits=$((waits + 1))
    if [ "$waits" -gt "$DISK_WAITS" ]; then
      alert "DISK FULL: $(free_gb "$RUN") GB free < MIN_FREE_GB $MIN_FREE_GB after $DISK_WAITS waits: stopping the ink workers"
      touch "$Q/.stop"
      mv "$jf" "$Q/pending/$(basename "${jf%.w*}")"
      return 75
    fi
    alert "DISK $(free_gb "$RUN") GB free < MIN_FREE_GB $MIN_FREE_GB: worker $w waits ($waits of $DISK_WAITS) before rendering $K of $BOXDIR"
    sleep 300
    [ -e "$Q/.stop" ] && { mv "$jf" "$Q/pending/$(basename "${jf%.w*}")"; return 75; }
  done
  cm=$(area "$TRACE")
  rs=0
  if [ ! -e "$Z/.done" ]; then
    # a volume without .done is a torn render from a stopped run: set it aside (deleted with DEL_ZARR=1)
    if [ -e "$Z" ]; then
      if [ "$DEL_ZARR" = 1 ]; then rm -rf -- "$Z"; else mv -- "$Z" "${Z%.zarr}.torn-$(date +%s).zarr"; fi   # *.zarr: pulls skip it
    fi
    t=$(date +%s)
    timeout -k 30 "$RENDER_TIMEOUT" "$VC" vc_render_tifxyz --volume "$VOL_URL" --segmentation "$TRACE" --scale 1 \
        --group-idx 0 --num-slices "$NUM_SLICES" --slice-step 1 --cache-gb "$RENDER_CACHE_GB" --flip-normals \
        --zarr-compressor zstd --timeout 180 --zarr-output "$Z" < /dev/null > "$rl" 2>&1
    rc=$?; rs=$(( $(date +%s) - t ))
    if [ "$rc" != 0 ]; then
      [ "$rc" = 124 ] || { [ "$rc" = 137 ] && [ "$rs" -ge "$RENDER_TIMEOUT" ]; } && echo "render stopped by RENDER_TIMEOUT (${RENDER_TIMEOUT}s)" >> "$rl"
      [ "$rc" = 137 ] && [ "$rs" -lt "$RENDER_TIMEOUT" ] && echo "render killed (signal 9: out of memory?)" >> "$rl"
      # the scan unreachable? Then it is not this strip's fault: put it back unchanged and make every worker wait,
      # instead of draining the queue into failed/
      if ! scan_ok; then
        [ -e "$Q/.net-down" ] || { touch "$Q/.net-down"; alert "NETWORK: the scan is not reachable; ink workers wait (up to ${NET_DOWN_MAX}s)"; }
        mv "$jf" "$Q/pending/$(basename "${jf%.w*}")"; LAST_STATE=netdown; LAST_REASON=
        return 0
      fi
      again "$jf" "render failed (exit $rc): $(tail -n 1 "$rl" | cut -c1-120)" "$w" "$g" "$rs" "$Z" failed; return 0
    fi
    touch "$Z/.done"
    printf 'render\t%s\t%s %s cm2, worker %s\n' "$rs" "$K" "$cm" "$w" >> "$BOXDIR/timing.tsv"
  fi
  [ -s "$d/side" ] || "$PY" -I "$WORK/reading_side.py" "$UMBILICUS" "$TRACE" --flip < /dev/null | cut -f5 > "$d/side"
  dir=$(cat "$d/side"); [ "$dir" = forward ] || [ "$dir" = reverse ] || dir=both
  [ -s "$dep" ] || "$PY" -I "$WORK/sheet_offset.py" "$dep" "$Z" < /dev/null > /dev/null
  if [ ! -s "$dep" ]; then again "$jf" "BLANK: empty depth profile" "$w" "$g" "$rs" "$Z" blank; return 0; fi
  mkdir -p "$d/mid"; "$PY" -I "$WORK/mid_layers.py" "$d/mid" "$Z" < /dev/null > /dev/null
  want=$NSTART; [ "$dir" = both ] && want=$(( 2 * NSTART ))
  t=$(date +%s)
  (cd "$VILLA" && CUDA_VISIBLE_DEVICES=$g timeout -k 60 "$INK_TIMEOUT" "$PY" -I "$WORK/infer_windows.py" "$Z" "$MODEL_FILE" \
      "$d" --starts $STARTS --direction "$dir" --prefix "$PREFIX" --no-compile --overlap 0.5 --blend-mode hann \
      --batch-size "$BATCH_SIZE" --num-workers "$INK_NUM_WORKERS" < /dev/null > "$d/infer_$PREFIX.log" 2>&1)
  rc=$?; is=$(( $(date +%s) - t ))
  got=$(count_maps "$d" "$PREFIX")
  printf 'ink\t%s\t%s %s cm2, %s of %s maps, GPU %s\n' "$is" "$K" "$cm" "$got" "$want" "$g" >> "$BOXDIR/timing.tsv"
  if grep -q 'No occupied blocks' "$d/infer_$PREFIX.log"; then again "$jf" "BLANK: no occupied blocks" "$w" "$g" "$rs" "$Z" blank; return 0; fi
  if [ "$got" -lt "$want" ]; then
    local why; why=$(grep -m 1 -E 'Error|error' "$d/infer_$PREFIX.log" | cut -c1-120)
    [ "$rc" = 124 ] || { [ "$rc" = 137 ] && [ "$is" -ge "$INK_TIMEOUT" ]; } && why="ink stopped by INK_TIMEOUT (${INK_TIMEOUT}s)"
    [ "$rc" = 137 ] && [ "$is" -lt "$INK_TIMEOUT" ] && why="ink killed (signal 9: out of memory?)"
    finish "$jf" failed "ink: $got of $want maps: $why" "$w" "$g" "$rs" "$is" "$got"
    return 0
  fi
  # whatever the model wrote where its input layers were all 0 (outside the mesh or the scan's mask) is not ink: set
  # it to 0 before anything looks at the maps (Reader V3 writes faint lines and a comb of strokes there)
  if [ "$NODATA" = 1 ]; then
    local nd; t=$(date +%s)
    nd=$("$PY" -I "$WORK/nodata.py" "$d" "$Z" "$PREFIX" "$D" --margin "$NODATA_MARGIN" < /dev/null 2>&1) \
      || { finish "$jf" failed "nodata: $(tail -n 1 <<< "$nd" | cut -c1-120)" "$w" "$g" "$rs" "$is" "$got"; return 0; }
    printf 'nodata\t%s\t%s %s\n' "$(( $(date +%s) - t ))" "$K" "$(tail -n 1 <<< "$nd")" >> "$BOXDIR/timing.tsv"
  fi
  # the right number of files is not enough: they must read, be finite, and not all be zero
  local mok; mok=$("$PY" -I "$WORK/maps_ok.py" "$d" "$PREFIX" 2>&1) \
    || { finish "$jf" failed "ink: maps not usable: $mok" "$w" "$g" "$rs" "$is" "$got"; return 0; }
  if [ "$DEL_ZARR" = 1 ] && [ -e "$Z/.done" ] && [[ "$Z" == "$BOXDIR"/render/*.zarr ]]; then
    rm -rf -- "$Z"   # the temporary 3D volume, once its maps are saved (DEL_ZARR=1)
  fi
  finish "$jf" "done" "" "$w" "$g" "$rs" "$is" "$got"
}

worker() {  # W -> exit 0 when the queue is closed and empty; 75 = stopped for disk; 76 = stopped after ink failures
  local w=$1 g=$(( $1 % NGPU )) f b claimed fails=0
  while :; do
    [ -e "$Q/.stop" ] && { echo "$(ts) worker $w: stop marker found"; return 75; }
    touch "$Q/.hb.w$w"   # heartbeat for watch.sh
    net_wait; case $? in 0) ;; 75) return 75 ;; *) continue ;; esac
    claimed=
    for f in "$Q"/pending/*.job; do
      [ -e "$f" ] || break
      b=$(basename "$f")
      if mv "$f" "$Q/running/$b.w$w" 2> /dev/null; then claimed=$Q/running/$b.w$w; break; fi
    done
    if [ -n "$claimed" ]; then
      LAST_STATE=; LAST_REASON=
      # a worker's whole time on the strip (mask check, side, depth profile, nodata, ... besides render and ink)
      readjob "$claimed"; local sbox=$BOXDIR sk=$K t0; t0=$(date +%s)
      work_one "$claimed" "$w" "$g"; rc=$?
      printf 'strip\t%s\t%s %s, worker %s\n' "$(( $(date +%s) - t0 ))" "$sk" "${LAST_STATE:-stopped}" "$w" >> "$sbox/timing.tsv"
      [ "$rc" = 0 ] || return "$rc"
      # strips whose ink step keeps failing on this GPU (none or only some of their maps): stop this worker before it
      # eats the queue. Render failures (network, CPU) do not count here.
      if [ "$LAST_STATE" = failed ] && [[ "$LAST_REASON" == ink:* ]]; then fails=$((fails + 1)); else fails=0; fi
      if [ "$fails" -ge "$GPU_FAIL_MAX" ]; then
        alert "GPU $g: $fails strips in a row failed in the ink step; worker $w stops (see $RUN/ink.tsv)"
        return 76
      fi
      continue
    fi
    if [ -e "$Q/.closed" ] && ! compgen -G "$Q/pending/*.job" > /dev/null; then break; fi
    sleep 10
  done
  echo "$(ts) worker $w (GPU $g) finished"
}

# a worker that died (killed, or a shell error) may have left its render or ink step running on its strip: stop those
# tools (their command lines hold the strip's folder), then put the strip back in the queue
orphans() {  # W
  local f pat
  for f in "$Q"/running/*.job.w"$1"; do
    [ -e "$f" ] || continue
    readjob "$f"
    pat=$(printf '%s' "$BOXDIR/render/$K/" | sed 's/[][\.*^$+?(){}|]/\\&/g')
    pkill -f -- "$pat" 2> /dev/null && { sleep 5; pkill -9 -f -- "$pat" 2> /dev/null; }
    mv "$f" "$Q/pending/$(basename "${f%.w*}")" && echo "$(ts) requeued $(basename "${f%.job.w*}") left by worker $1"
  done
}
queue_finished() { [ -e "$Q/.closed" ] && ! compgen -G "$Q/pending/*.job" > /dev/null && ! compgen -G "$Q/running/*.job.w*" > /dev/null; }

rm -f "$Q/.stop"
# supervisor: a worker that ends while the queue still has work starts again after a pause (WORKER_PAUSE x n s, at most
# WORKER_RESTARTS times): one the GPU breaker retired (76: a GPU can recover from a passing fault) or one that died.
# Workers that stopped on purpose (75: stop marker, full disk, scan down) or finished (0) are not restarted.
declare -A wpid=() wtry=() wdue=()
for w in $(seq 0 $((NW - 1))); do worker "$w" & wpid[$w]=$!; sleep 1; done
worst=0
while [ "${#wpid[@]}" -gt 0 ] || [ "${#wdue[@]}" -gt 0 ]; do
  sleep 5
  for w in "${!wpid[@]}"; do
    kill -0 "${wpid[$w]}" 2> /dev/null && continue
    wait "${wpid[$w]}"; rc=$?; unset "wpid[$w]"
    case $rc in 0) continue ;; 75) [ "$rc" -gt "$worst" ] && worst=$rc; continue ;; 76) ;; *) orphans "$w" ;; esac
    wtry[$w]=$(( ${wtry[$w]:-0} + 1 ))
    if [ ! -e "$Q/.stop" ] && [ "${wtry[$w]}" -le "$WORKER_RESTARTS" ]; then
      wdue[$w]=$(( $(date +%s) + WORKER_PAUSE * wtry[$w] ))
      alert "ink worker $w (GPU $((w % NGPU))) ended (exit $rc): it starts again in $(( WORKER_PAUSE * wtry[$w] ))s (restart ${wtry[$w]} of $WORKER_RESTARTS)"
    else
      alert "ink worker $w (GPU $((w % NGPU))) ended (exit $rc) and stays stopped"; [ "$rc" -gt "$worst" ] && worst=$rc
    fi
  done
  for w in "${!wdue[@]}"; do
    [ "$(date +%s)" -ge "${wdue[$w]}" ] || continue
    unset "wdue[$w]"
    { [ -e "$Q/.stop" ] || queue_finished; } && continue
    echo "$(ts) worker $w (GPU $((w % NGPU))) starts again"; worker "$w" & wpid[$w]=$!
  done
done
# the queue's state is what counts: every strip handled = 0, whatever single workers went through (alerts.log has it)
queue_finished && worst=0
echo "$(ts) all ink workers finished (exit $worst): $(bash "$0" status "$RUN")"
exit "$worst"
