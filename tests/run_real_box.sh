#!/bin/bash
# run_real_box.sh — CPU-only integration test with the REAL VC3D tools and real public data (PHerc. 0343): seed
# planning and the mask filter on the real prediction and scan, one small box grown and stitched, its strips rendered
# from the real scan. Only the ink step is a stand-in (no GPU needed). Downloads ~1-2 GB of public data into TEST_HOME.
# usage: UMB_0343=/path/PHerc0343_umbilicus.json tests/run_real_box.sh PYTHON VC3D_APPRUN TEST_HOME
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
PYBIN=${1:?python}; VCRUN=${2:?VC3D AppRun}; T=${3:?test home}
mkdir -p "$T"; T=$(cd "$T" && pwd)
export HOME=$T WORK=$T/work VC=$VCRUN PY=$PYBIN VILLA=$T/villa MODELS=$T/models NGPU=1
mkdir -p "$WORK" "$VILLA"
cp "$R"/kit/work/* "$WORK/"; cp "$R/tests/fake/work/infer_windows.py" "$WORK/"   # stand-in ink step only
"$PY" -I -c "
import sys, torch
torch.save({'config': {'model': {'crop_size': [17, 64, 64]}}, 'state_dict': {'w': torch.zeros(3)}}, sys.argv[1])" "$T/model.pth"
SHA=$(sha256sum "$T/model.pth" | cut -d' ' -f1)
B=https://vesuvius-challenge-open-data.s3.us-east-1.amazonaws.com
cat > "$T/real.env" << EOF
S=PHerc0343
VOL_URL=$B/PHerc0343/volumes/20250521140437-8.640um-1.2m-116keV-masked.zarr
PRED_URL=$B/PHerc0343/representations/predictions/surfaces/20250521140437-surface-20260413222639-surface-m7-L0-th0.2.zarr
VOXEL_UM=8.64
UMBILICUS=${UMB_0343:?UMB_0343=path to a PHerc0343 umbilicus json}
BANDS="10000:10400"
MODEL_URL=file://$T/model.pth
MODEL_SHA256=$SHA
PREFIX=rv2
CHECK=0
GENS=32
NEXP1=10
NEXP2=10
NTR=2
MAXTRY=3
MINCM=0.2
MIN_FREE_GB=5
RESULTS=$T/results
RUN_NAME=real
EOF
. "$WORK/common.sh"; load_config "$T/real.env" || exit 1
mkdir -p "$RUN"; echo "$CONFIG" > "$RUN/config.path"
OUT=$RUN/band_z10000-10400; mkdir -p "$OUT/box_00"
t=$(date +%s)
echo "== seed plan (real prediction)"
[ -s "$OUT/seeds_all.tsv" ] || "$PY" -I "$WORK/seed_plan.py" "$PRED_URL" "$UMBILICUS" "$OUT/seeds_all.tsv" --z 10200 --rays 8 --fracs 0.3 0.5 --prefix b
echo "== mask filter (real scan)"
"$PY" -I "$WORK/mask_check.py" seeds "$VOL_URL" "$OUT/seeds_all.tsv" "$OUT/seeds.tsv"
read -r name x y z _ < <(head -n 1 "$OUT/seeds.tsv")
[ -n "${name:-}" ] || { echo "FAIL no seed"; exit 1; }
BOX="10000 10400 $((y - 300)) $((y + 300)) $((x - 300)) $((x + 300))"
awk -F'\t' -v x0=$((x - 280)) -v x1=$((x + 280)) -v y0=$((y - 280)) -v y1=$((y + 280)) \
  '$2 >= x0 && $2 < x1 && $3 >= y0 && $3 < y1' "$OUT/seeds.tsv" > "$OUT/box_00/seeds.tsv"
echo "box $BOX with $(wc -l < "$OUT/box_00/seeds.tsv") seeds ($(( $(date +%s) - t ))s so far)"
echo "== box.sh (real VC3D growth + stitching, CPU)"
BOX="$BOX" SEEDS="$OUT/box_00/seeds.tsv" OUT="$OUT/box_00" PAR=6 nice -n 10 bash "$WORK/box.sh" > "$OUT/box_00/run.log" 2>&1
tail -n 8 "$OUT/box_00/run.log"
echo "== ink queue (real render, stand-in ink)"
bash "$WORK/inkq.sh" close "$RUN"
nice -n 10 bash "$WORK/inkq.sh" workers "$RUN" > "$RUN/ink.log" 2>&1
tail -n 4 "$RUN/ink.log"
bash "$WORK/inkq.sh" status "$RUN"
for d in "$OUT"/box_00/render/t*; do
  [ -d "$d" ] || continue
  echo "$(basename "$d"): side $(cat "$d/side" 2> /dev/null), depth tiles $(wc -l < "$d/depth.tsv" 2> /dev/null), maps $(count_maps "$d" rv2)," \
       "render $(grep -h render "$OUT/box_00/timing.tsv" | grep -w "$(basename "$d")" | cut -f2)s"
done
"$PY" -I "$WORK/summary.py" "$RUN" | tail -n 4
echo "total $(( $(date +%s) - t ))s; test HOME $T ($(du -sh "$T" | cut -f1))"
