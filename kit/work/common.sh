#!/bin/bash
# common.sh — settings and helpers shared by setup.sh, run.sh, band.sh, box.sh, inkq.sh, check.sh and stop.sh. Sourced, not run.
# load_config FILE reads one scroll's settings (config/*.env), fills in the defaults and checks the required ones.
# Nothing in the kit holds keys or tokens: everything it downloads is public.

WORK=${WORK:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}   # the kit's scripts (setup.sh copies kit/work to ~/work)
VC=${VC:-$HOME/tools/vc3d/squashfs-root/AppRun}      # VC3D, always through its AppRun (bundled glibc + loader)
PY=${PY:-$HOME/envs/ink/bin/python}
VILLA=${VILLA:-$HOME/code/villa/vesuvius}            # villa's ink inference runs from inside this folder
MODELS=${MODELS:-$HOME/models}
export WORK VC PY VILLA MODELS
# Reader v2 (Domenico Russo), pinned revision: the model when none is configured (setup.sh or check.sh without a config)
RV2_URL=${RV2_URL:-https://huggingface.co/domenicor046/reader-v2/resolve/72633d8aa6d40e9e737ccea4c9928fbc624dab45/reader-v2-step040000.pth}
RV2_SHA256=${RV2_SHA256:-654ec5acec2b6c4788d9cb326e2f0b8c2c730584949a934ef775db7f6ab5d3a6}

load_config() {
  local f=${1:?config file} v miss=
  [ -s "$f" ] || { echo "config $f is missing or empty" >&2; return 1; }
  CONFIG=$(readlink -f "$f")
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG"
  # the scroll (required: S VOL_URL PRED_URL VOXEL_UM UMBILICUS BANDS)
  NORMAL_GRIDS_URL=${NORMAL_GRIDS_URL:-${PRED_URL%.zarr}.normal-grids}
  RUN_NAME=${RUN_NAME:-${S:-run}}; RESULTS=${RESULTS:-$HOME/results}; RUN=${RUN:-$RESULTS/$RUN_NAME}
  # seeds and boxes (band.sh)
  GRID=${GRID:-3}; MARGIN=${MARGIN:-150}; RAYS=${RAYS:-16}; FRACS=${FRACS:-0.15 0.35 0.55 0.75 0.9}
  # SEEDS_EXTRA: a tsv of name x y z rows (a path relative to the config's folder). Those in a band's z range join its
  # seeds, and each box starts its first strips from the patches grown at them (e.g. at known letters: a positive control);
  # a point that no inked strip reaches gets the patch grown at it inked as it is (box.sh)
  SEEDS_EXTRA=${SEEDS_EXTRA:-}
  # growth and stitching (box.sh)
  # defaults = the settings of the measured rented run (docs/COSTS.md): 300 + 300 launches, capped at 40 + 30 min
  GENS=${GENS:-48}; NEXP1=${NEXP1:-300}; NEXP2=${NEXP2:-300}; GROW1_MAX=${GROW1_MAX:-2400}; GROW2_MAX=${GROW2_MAX:-1800}
  GROW_TIMEOUT=${GROW_TIMEOUT:-1800}; NTR=${NTR:-6}; MAXTRY=${MAXTRY:-12}; MINCM=${MINCM:-1.0}
  # a strip whose new area (vs the box's inked strips, 10 vx) is below MIN_NEW % is kept but not inked; 0 = off
  MIN_NEW=${MIN_NEW:-0}
  # COVER=1 inks a greedy cover of the grown patches (up to COVER_FRAC of their union) instead of stitched strips;
  # DROP_SINGLE=1 first leaves out patches that no other patch comes within 10 vx of
  COVER=${COVER:-0}; COVER_FRAC=${COVER_FRAC:-0.8}; DROP_SINGLE=${DROP_SINGLE:-0}
  TRACE_TIMEOUT=${TRACE_TIMEOUT:-3600}   # seconds before one stitcher run is stopped
  STITCH_THREADS=${STITCH_THREADS:-16}   # OpenMP threads per stitcher run
  BANDS_IN_FLIGHT=${BANDS_IN_FLIGHT:-2}  # bands growing at once (they share the run's grower slots)
  BAND_TRIES=${BAND_TRIES:-3}; BAND_PAUSE=${BAND_PAUSE:-300}   # a failed band is tried again, BAND_PAUSE x try later
  PASS_PAUSE=${PASS_PAUSE:-60}           # pause before a growth pass whose growers mostly failed is tried again
  PREFLIGHT=${PREFLIGHT:-1}              # one window of the configured model on the control strip before searching
  # growers and the stitcher run at this nice level, so the ink workers' busy Python thread gets the CPU first
  GROW_NICE=${GROW_NICE:-10}
  # coverage: how next_start.py picks each new strip's start patch (more strips per area = lower max-covered / tol)
  START_MAX_COVERED=${START_MAX_COVERED:-0.2}; START_TOL=${START_TOL:-8}; START_MIN_AREA=${START_MIN_AREA:-0.5}
  # render and ink (inkq.sh; the ink model is required: MODEL_URL MODEL_SHA256 PREFIX)
  NUM_SLICES=${NUM_SLICES:-61}; CENTRES=${CENTRES:-10 14 18 22 26 30 34 38 42 46 50}
  BATCH_SIZE=${BATCH_SIZE:-16}; MODEL_DEPTH=${MODEL_DEPTH:-}; RENDER_CACHE_GB=${RENDER_CACHE_GB:-8}
  INK_PER_GPU=${INK_PER_GPU:-1}; INK_OMP=${INK_OMP:-8}; INK_NUM_WORKERS=${INK_NUM_WORKERS:-4}; RENDER_RETRIES=${RENDER_RETRIES:-1}
  RENDER_TIMEOUT=${RENDER_TIMEOUT:-3600}; INK_TIMEOUT=${INK_TIMEOUT:-7200}   # seconds per strip, then failed/
  GPU_FAIL_MAX=${GPU_FAIL_MAX:-3}        # a worker stops after this many strips in a row ended with no maps
  # ... and starts again after WORKER_PAUSE x n seconds, at most WORKER_RESTARTS times (likewise a worker that died)
  WORKER_RESTARTS=${WORKER_RESTARTS:-3}; WORKER_PAUSE=${WORKER_PAUSE:-300}
  # maps are set to 0 where the model's input layers are all 0 (no data: outside the mesh or the scan's mask), where
  # a model can write strokes that are not ink (Reader V3 does); NODATA=0 keeps the model's raw maps
  NODATA=${NODATA:-1}; NODATA_MARGIN=${NODATA_MARGIN:-0}   # margin: also this many pixels around no-data areas
  # guard rails
  # MIN_FREE_GB is checked before each render, and several renders can start at once: keep it well above one render
  DEL_ZARR=${DEL_ZARR:-0}; MIN_FREE_GB=${MIN_FREE_GB:-150}; CHECK=${CHECK:-1}; MASK_CHECK=${MASK_CHECK:-1}
  DISK_WAITS=${DISK_WAITS:-6}            # 5-minute waits for free disk before the run stops (loudly)
  CACHE_EVICT=${CACHE_EVICT:-0}          # 1 = delete VC3D download-cache files when disk is low: ONLY with the operator's approval
  NET_TRIES=${NET_TRIES:-8}              # tries (pauses 30 s doubling to 5 min, ~30 min in all) for network steps
  NET_DOWN_MAX=${NET_DOWN_MAX:-3600}     # seconds the scan may stay unreachable before the ink workers stop the run
  # RAM per grower for the grower cap: the rented run used at most 34 GB with ~119 growers (~0.3 GB each beyond what
  # they share); 0.5 leaves a margin
  GROWER_GB=${GROWER_GB:-0.5}; RESERVE_GB=${RESERVE_GB:-}; RESERVE_THREADS=${RESERVE_THREADS:-}
  set +a
  for v in S VOL_URL PRED_URL VOXEL_UM UMBILICUS BANDS MODEL_URL MODEL_SHA256 PREFIX; do
    [ -n "${!v:-}" ] || miss="$miss $v"
  done
  [ -z "$miss" ] || { echo "config $f: missing$miss" >&2; return 1; }
  [[ $PREFIX =~ ^[A-Za-z0-9_-]+$ ]] || { echo "config $f: PREFIX may hold only letters, digits, - and _" >&2; return 1; }
  case $NODATA in 0|1) ;; *) echo "config $f: NODATA must be 0 or 1" >&2; return 1 ;; esac
  [[ $NODATA_MARGIN =~ ^[0-9]+$ ]] || { echo "config $f: NODATA_MARGIN must be a whole number of pixels" >&2; return 1; }
  [[ $GROW_NICE =~ ^[0-9]+$ ]] && [ "$GROW_NICE" -le 19 ] || { echo "config $f: GROW_NICE must be 0-19" >&2; return 1; }
  [[ $MIN_NEW =~ ^[0-9]+$ ]] && [ "$MIN_NEW" -le 100 ] || { echo "config $f: MIN_NEW must be 0-100 (percent)" >&2; return 1; }
  case "$COVER$DROP_SINGLE" in 00|01|10|11) ;; *) echo "config $f: COVER and DROP_SINGLE must be 0 or 1" >&2; return 1 ;; esac
  awk -v x="$COVER_FRAC" 'BEGIN {exit !(x + 0 > 0 && x + 0 <= 1 && x ~ /^[0-9.]+$/)}' \
    || { echo "config $f: COVER_FRAC must be a fraction in (0, 1]" >&2; return 1; }
  # a relative umbilicus path is relative to the config file's folder; UMBILICUS_URL (+ UMBILICUS_SHA256) fetches it
  case $UMBILICUS in /*) ;; *) UMBILICUS=$(dirname "$CONFIG")/$UMBILICUS ;; esac
  if [ ! -s "$UMBILICUS" ] && [ -n "${UMBILICUS_URL:-}" ]; then
    mkdir -p "$(dirname "$UMBILICUS")"
    curl -fsSL --retry 3 -o "$UMBILICUS.part" "$UMBILICUS_URL" || { echo "umbilicus download FAILED: $UMBILICUS_URL" >&2; return 1; }
    if [ -n "${UMBILICUS_SHA256:-}" ]; then
      echo "$UMBILICUS_SHA256  $UMBILICUS.part" | sha256sum -c --quiet - || { echo "umbilicus checksum MISMATCH" >&2; return 1; }
    fi
    mv "$UMBILICUS.part" "$UMBILICUS"
  fi
  [ -s "$UMBILICUS" ] || { echo "config $f: scroll axis file $UMBILICUS is missing (and no UMBILICUS_URL)" >&2; return 1; }
  if [ -n "$SEEDS_EXTRA" ]; then
    case $SEEDS_EXTRA in /*) ;; *) SEEDS_EXTRA=$(dirname "$CONFIG")/$SEEDS_EXTRA ;; esac
    [ -s "$SEEDS_EXTRA" ] || { echo "config $f: SEEDS_EXTRA file $SEEDS_EXTRA is missing or empty" >&2; return 1; }
  fi
  MODEL_FILE=${MODEL_FILE:-$(model_path "$MODEL_URL" "$PREFIX")}
  export CONFIG RUN UMBILICUS MODEL_FILE SEEDS_EXTRA
}

# where a model downloaded from URL lives: MODELS/PREFIX/<file name in the URL>
model_path() { local u=${1%%\?*}; echo "$MODELS/$2/${u##*/}"; }

# install_model URL SHA256 PREFIX: download once, verify the checksum, then load it with torch's weights-only loader
# (plain tensors and containers only, no code in the pickle). A checkpoint that fails that check is never used.
# Writes FILE.depth (the model's crop depth in layers, or "none" if its config does not say).
install_model() {
  local url=$1 sha=$2 f; f=$(model_path "$url" "$3")
  mkdir -p "$(dirname "$f")"
  if [ ! -s "$f" ] || ! echo "$sha  $f" | sha256sum -c --quiet - 2> /dev/null; then
    curl -fsSL --retry 3 -o "$f.part" "$url" || { echo "model download FAILED: $url" >&2; return 2; }
    echo "$sha  $f.part" | sha256sum -c --quiet - || { echo "model checksum MISMATCH: $url" >&2; return 2; }
    mv "$f.part" "$f"; rm -f "$f.safe" "$f.depth"
  fi
  if [ ! -e "$f.safe" ]; then
    "$PY" -I "$WORK/model_check.py" "$f" > "$f.depth.part" 2> "$f.safety.log" \
      || { echo "SAFETY STOP: $f does not load with weights_only=True; not used (see $f.safety.log)" >&2; return 3; }
    mv "$f.depth.part" "$f.depth"; touch "$f.safe"
  fi
  echo "$f"
}

# model_depth FILE: crop depth from FILE.depth, else MODEL_DEPTH from the config
model_depth() {
  local d; d=$(cat "$1.depth" 2> /dev/null)
  [[ "$d" =~ ^[0-9]+$ ]] || d=${MODEL_DEPTH:-}
  [[ "$d" =~ ^[0-9]+$ ]] || { echo "unknown crop depth for $1: set MODEL_DEPTH in the config" >&2; return 1; }
  echo "$d"
}

# window_starts DEPTH: one window start per centre in CENTRES (start = centre - (depth - 1) / 2), keeping only windows
# that fit in the NUM_SLICES-layer render. Reader v2 (depth 17) gives starts 2 6 ... 42, i.e. depths -20..+20 around the
# centre layer; another model gets the same centres.
window_starts() {
  local d=$1 c s out=
  for c in $CENTRES; do
    s=$(( c - (d - 1) / 2 ))
    [ "$s" -ge 0 ] && [ $(( s + d )) -le "$NUM_SLICES" ] && out="$out $s"
  done
  echo "${out# }"
}

free_gb() { df -P -BG "${1:-$HOME}" 2> /dev/null | awk 'NR == 2 {sub("G", "", $4); print $4}'; }

# usable RAM in GB: the smaller of the host's MemTotal and the container's cgroup memory limit
mem_total_gb() {
  local host lim
  host=$(awk '/^MemTotal:/ {print int($2 / 1048576)}' /proc/meminfo)
  lim=$(cat /sys/fs/cgroup/memory.max 2> /dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2> /dev/null)
  if [[ "$lim" =~ ^[0-9]+$ ]] && [ $(( lim / 1073741824 )) -lt "$host" ]; then echo $(( lim / 1073741824 )); else echo "$host"; fi
}

# grower_slots: how many growers the whole run may have at once (every box of every band shares them). CPU threads
# minus RESERVE_THREADS for the ink workers, capped by RAM (GROWER_GB each after RESERVE_GB) and by the container's
# thread limit (pids.max; ~110 threads per grower even with 1-thread BLAS/OpenMP pools). Messages go to stderr.
grower_slots() {
  local ngpu nink rt rg n ramcap pidmax pidcap
  ngpu=${NGPU:-$(nvidia-smi --query-gpu=index --format=csv,noheader 2> /dev/null | wc -l)}; [ "$ngpu" -ge 1 ] || ngpu=1
  nink=$(( ngpu * INK_PER_GPU ))
  # leave CPU threads and RAM for the ink workers: each renders with RENDER_CACHE_GB of chunk cache, runs a ~3 GB
  # python, and keeps one core plus its INK_NUM_WORKERS data-loading processes (~0.5 GB each, estimated) busy
  rt=${RESERVE_THREADS:-$(( 8 + (2 + INK_NUM_WORKERS) * nink ))}
  rg=${RESERVE_GB:-$(( 16 + (RENDER_CACHE_GB + 5) * nink + (INK_NUM_WORKERS * nink + 1) / 2 ))}
  # the default reserve is a worst case (full render caches); on a small machine it would leave no RAM for growth
  # (a 31 GB desktop: 2 growers, no strip big enough to keep), so it is capped at 40 % of RAM unless RESERVE_GB is set
  [ -z "${RESERVE_GB:-}" ] && [ "$rg" -gt $(( $(mem_total_gb) * 2 / 5 )) ] && rg=$(( $(mem_total_gb) * 2 / 5 ))
  n=${THREADS:-$(( $(nproc) - rt ))}
  ramcap=$(awk -v m="$(mem_total_gb)" -v g="$GROWER_GB" -v r="$rg" 'BEGIN {n = int((m - r) / g); print (n < 2 ? 2 : n)}')
  if [ "$n" -gt "$ramcap" ]; then echo "RAM ($(mem_total_gb) GB) caps growers at $ramcap (of $n)" >&2; n=$ramcap; fi
  pidmax=$(cat /sys/fs/cgroup/pids.max 2> /dev/null); pidcap=$n
  [[ "$pidmax" =~ ^[0-9]+$ ]] && pidcap=$(( (pidmax - 4000) / 150 ))
  if [ "$n" -gt "$pidcap" ]; then echo "thread limit $pidmax caps growers at $pidcap (of $n)" >&2; n=$pidcap; fi
  [ "$n" -ge 2 ] || n=2
  echo "$n"
}

# retry TRIES CMD...: run CMD until it succeeds, pausing 30 s, 60 s, 120 s, 240 s, then 300 s between tries
retry() {
  local n=$1 i=1 p=30; shift
  until "$@"; do
    [ "$i" -ge "$n" ] && { echo "failed after $n tries: $*" >&2; return 1; }
    echo "try $i of $n failed, again in ${p}s: $1" >&2; sleep "$p"; i=$((i + 1)); p=$((p * 2)); [ "$p" -gt 300 ] && p=300
  done
}

# strip area in cm2: valid nodes x 400 voxels per node (tifxyz grid every 20 voxels) x voxel area
area() {
  "$PY" -I -c "
import sys, tifffile
x = tifffile.imread(sys.argv[1] + '/x.tif'); print(round(float((x > 0).sum()) * 400 * (float(sys.argv[2]) * 1e-4) ** 2, 2))" "$1" "$VOXEL_UM"
}

# count_maps DIR PREFIX: finished ink maps of that model in DIR
count_maps() {
  local n=0 f
  for f in "$1/$2"_s*.tif; do
    [ -e "$f" ] || continue
    [[ "$f" =~ /${2}_s[0-9]+(_reverse)?\.tif$ ]] && n=$((n + 1))
  done
  echo "$n"
}

ts() { date '+%F %T'; }

# holders FILE: PIDs of the live processes, other than this shell, that hold FILE open, oldest first (so parents come
# before their children). Every process run.sh starts inherits its lock (RUN/.run.lock), so this finds what is left of a
# run even after their parents have died. Call it as VAR=$(holders FILE), not in a pipeline: a pipe's other commands
# hold FILE too. (find sees itself and this function's subshells as well; they have ended when the list is filtered.)
holders() {
  local f p live=()
  f=$(readlink -f -- "$1" | sed 's/[][*?\\]/\\&/g')
  for p in $(find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -lname "$f" 2> /dev/null | cut -d/ -f3 | sort -un); do
    [ "$p" != "$$" ] && [ "$p" != "$BASHPID" ] && kill -0 "$p" 2> /dev/null && live+=("$p")
  done
  [ "${#live[@]}" -gt 0 ] || return 0
  ps -o pid= --sort=start_time -p "$(IFS=,; echo "${live[*]}")" | tr -d ' '
}

# pnames PIDS: their program names with counts, e.g. "bash x3, python x1"
pnames() { ps -o comm= -p "$(echo $1 | tr ' ' ,)" | sort | uniq -c | awk '{printf "%s%s x%s", (NR > 1 ? ", " : ""), $2, $1}'; }

# end_holders FILE GRACE: TERM to the processes holding FILE, then KILL to those still there after GRACE seconds (tools
# that ignore TERM: the stitcher does). Returns 1, listing them, if any is left 20 s after the KILL.
end_holders() {
  local left i
  left=$(holders "$1"); [ -n "$left" ] || return 0
  kill $left 2> /dev/null
  for i in $(seq "$2"); do sleep 1; left=$(holders "$1"); [ -n "$left" ] || return 0; done
  echo "$(ts) $(wc -w <<< "$left") process(es) still running ${2}s after TERM, sent KILL: $(pnames "$left")"
  kill -9 $left 2> /dev/null
  for i in $(seq 20); do sleep 1; left=$(holders "$1"); [ -n "$left" ] || return 0; done
  echo "$(ts) still running 20 s after KILL:"; ps -o pid=,etime=,args= -p "${left//$'\n'/,}" | cut -c1-200
  return 1
}
