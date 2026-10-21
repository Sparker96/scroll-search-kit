#!/bin/bash
# band.sh Z0 Z1 — one z band of one scroll: seed rings around the scroll axis, a grid of boxes over the scan's x/y
# extent, and box.sh (growth + stitching) on every box that has seeds, all at once. The boxes put their strips into the
# run's ink queue; band.sh returns when every box has finished stitching (it does not wait for the ink).
# Settings from CONFIG (config/*.env): GRID boxes per side [3], MARGIN box overlap in voxels [150], RAYS [16], FRACS,
#   plus everything box.sh reads; growers are limited by the run's grower slots (common.sh grower_slots). DRYRUN=1 plans seeds and boxes only. Output: RUN/band_z<Z0>-<Z1>/.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_config "${CONFIG:?CONFIG required}" || exit 1
Z0=${1:?Z0}; Z1=${2:?Z1}
OUT=$RUN/$(printf 'band_z%05d-%05d' "$Z0" "$Z1")
# growers share the run's grower slots (run.sh sets GROWER_SLOTS and RUN/slots/; a band run alone makes its own)
GROWER_SLOTS=${GROWER_SLOTS:-$(grower_slots)}; export GROWER_SLOTS
mkdir -p "$OUT"
# every kept strip must be in the ink queue, even if a box stopped between stitching a strip and queueing it
reconcile() {
  local tr f name pick
  for tr in "$OUT"/box_*/traces/t*/auto_trace_*; do
    [ -d "$tr" ] || continue
    [ -e "$(dirname "$tr")/.setaside" ] && continue   # kept, not inked (MIN_NEW)
    bash "$WORK/inkq.sh" add "$RUN" "$tr" "${tr%/traces/*}" "$(basename "$(dirname "$tr")")" > /dev/null
  done
  for f in "$OUT"/box_*/cover.tsv; do   # COVER mode: the picked patches
    [ -s "$f" ] || continue
    while IFS=$'\t' read -r name pick _; do
      [ "$name" = patch ] && continue
      tr=$(dirname "$f")/patches/$name
      [ -d "$tr" ] && bash "$WORK/inkq.sh" add "$RUN" "$tr" "$(dirname "$f")" "p$pick" > /dev/null
    done < "$f"
  done
}
if [ -e "$OUT/.grown" ]; then reconcile; echo "band z $Z0-$Z1 already grown and stitched"; exit 0; fi
t=$(date +%s)
ZM=$(( (Z0 + Z1) / 2 ))
# network steps are retried (NET_TRIES, growing pauses): one blip must not lose the band
if [ ! -s "$OUT/seeds_all.tsv" ]; then
  retry "$NET_TRIES" "$PY" -I "$WORK/seed_plan.py" "$PRED_URL" "$UMBILICUS" "$OUT/seeds.part" --z "$ZM" --rays "$RAYS" \
      --fracs $FRACS --prefix b || { echo "seed planning FAILED"; exit 1; }
  # the config's own seed points in this band (SEEDS_EXTRA), named x_<name>: box.sh starts strips at their patches
  if [ -n "$SEEDS_EXTRA" ]; then
    awk -F'\t' -v OFS='\t' -v z0="$Z0" -v z1="$Z1" 'NF >= 4 && $4 + 0 >= z0 && $4 + 0 < z1 {$1 = "x_" $1; print}' \
      "$SEEDS_EXTRA" >> "$OUT/seeds.part"
  fi
  mv "$OUT/seeds.part" "$OUT/seeds_all.tsv"
fi
# drop seeds outside the scan's mask: the masked scan has no data there although the surface prediction may show
# surfaces, and strips grown there render all-zero
if [ ! -e "$OUT/seeds.tsv" ]; then
  if [ "$MASK_CHECK" = 1 ]; then
    retry "$NET_TRIES" "$PY" -I "$WORK/mask_check.py" seeds "$VOL_URL" "$OUT/seeds_all.tsv" "$OUT/seeds.part" > "$OUT/seeds_mask.log" \
      && mv "$OUT/seeds.part" "$OUT/seeds.tsv" || { echo "seed mask check FAILED"; exit 1; }
    cat "$OUT/seeds_mask.log"
  else
    cp "$OUT/seeds_all.tsv" "$OUT/seeds.tsv"
  fi
fi
echo "band z $Z0-$Z1: $(grep -c . "$OUT/seeds.tsv") seeds ($(( $(date +%s) - t ))s)"
shape() { "$PY" -I -c "
import json, sys, urllib.request
m = json.loads(urllib.request.urlopen(sys.argv[1] + '/0/.zarray', timeout=60).read()); print(*m['shape'])" "$PRED_URL" > "$OUT/.shape"; }
retry "$NET_TRIES" shape || { echo "could not read the prediction's shape"; exit 1; }
read -r _ SY SX < "$OUT/.shape"
[[ "${SX:-}" =~ ^[0-9]+$ ]] || { echo "could not read the prediction's shape"; exit 1; }
# boxes: GRID x GRID over the x/y extent, each widened by MARGIN; keep the ones that hold seeds
boxes=()
for gy in $(seq 0 $((GRID - 1))); do
  for gx in $(seq 0 $((GRID - 1))); do
    y0=$(( gy * SY / GRID - MARGIN )); y1=$(( (gy + 1) * SY / GRID + MARGIN ))
    x0=$(( gx * SX / GRID - MARGIN )); x1=$(( (gx + 1) * SX / GRID + MARGIN ))
    [ "$y0" -lt 0 ] && y0=0; [ "$x0" -lt 0 ] && x0=0; [ "$y1" -gt "$SY" ] && y1=$SY; [ "$x1" -gt "$SX" ] && x1=$SX
    b=$OUT/box_${gy}${gx}; mkdir -p "$b"
    awk -F'\t' -v y0="$y0" -v y1="$y1" -v x0="$x0" -v x1="$x1" -v z0="$Z0" -v z1="$Z1" \
      '$3 >= y0 + 20 && $3 < y1 - 20 && $2 >= x0 + 20 && $2 < x1 - 20 && $4 >= z0 && $4 < z1' "$OUT/seeds.tsv" > "$b/seeds.tsv"
    if [ -s "$b/seeds.tsv" ]; then boxes+=("$b|$Z0 $Z1 $y0 $y1 $x0 $x1"); fi
  done
done
nb=${#boxes[@]}
# a band with no seed inside the scan's mask (e.g. above or below the scroll) has nothing to grow: done, not failed
[ "$nb" -gt 0 ] || { echo "no box has seeds inside the scan's mask: nothing to grow"; touch "$OUT/.grown"; exit 0; }
echo "$nb boxes; growers share the run's $GROWER_SLOTS grower slots"
if [ "${DRYRUN:-0}" = 1 ]; then for e in "${boxes[@]}"; do echo "  ${e#*|}  $(grep -c . "${e%%|*}/seeds.tsv") seeds"; done; exit 0; fi
for e in "${boxes[@]}"; do
  b=${e%%|*}; box=${e#*|}
  echo "$(basename "$b") box $box: $(grep -c . "$b/seeds.tsv") seeds"
  [ -e "$b/.stitched" ] && continue
  BOX="$box" SEEDS="$b/seeds.tsv" OUT="$b" bash "$WORK/box.sh" < /dev/null >> "$b/run.log" 2>&1 &
done
wait
reconcile
# the band counts as grown only if every box finished; otherwise run.sh tries it again (boxes resume where they stopped)
nfail=0
for e in "${boxes[@]}"; do
  b=${e%%|*}
  if [ -e "$b/.failed" ] || [ ! -e "$b/.stitched" ]; then
    nfail=$((nfail + 1)); echo "$(basename "$b") FAILED: $(cat "$b/.failed" 2> /dev/null || echo 'did not finish')"
  fi
done
[ "$nfail" = 0 ] || { echo "band z $Z0-$Z1 NOT grown: $nfail of $nb boxes failed"; exit 3; }
touch "$OUT/.grown"
echo "band z $Z0-$Z1 grown and stitched in $(( $(date +%s) - t ))s"
for e in "${boxes[@]}"; do b=${e%%|*}; echo "== $(basename "$b")"; tail -n 1 "$b/run.log"; tail -n +2 "$b/timing.tsv" 2> /dev/null; done
