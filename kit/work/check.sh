#!/bin/bash
# check.sh [OUT] [CONFIG] — same-answer check before trusting a machine: render and ink a control strip whose maps are
# known, then compare (compare_maps.py). The control (kit/test/control/: a PHerc. 0343 strip over known letters,
# check.env, and reference maps made with this kit's pinned software, one set per model as
# ref/<prefix>_s<start>[_reverse].tif, all listed in ref/SHA256SUMS) is read with the RUN's ink model: CONFIG's, or
# MODEL_URL MODEL_SHA256 PREFIX from the environment (run.sh passes its config); with neither, Reader v2. It reads the
# windows and directions that model's reference maps have, raw (as inference writes them, before nodata.py).
# PASS = every reference map of that model reproduced with r >= CHECK_MIN_R (byte-identical on the reference GPU
# architecture; expect r > 0.99 on others). Prints PASS or FAIL. Exit 0 = PASS; 1 = FAIL; 2 = the control cannot check
# this model (no reference maps for its prefix, or they were made by another checkpoint: CHECK=0 runs without the
# check, knowingly); 3 = the model could not be installed. The render and ink commands match inkq.sh's.
# The check uses the run's render cache, batch size and data-loading workers, so it covers those settings too:
# CHECK_CACHE_GB, CHECK_BATCH, CHECK_NUM_WORKERS override them [config's RENDER_CACHE_GB BATCH_SIZE INK_NUM_WORKERS,
# else 8 16 0]. CHECK_RENDER_ONLY=1 renders the control strip and stops (run.sh uses it for the model preflight when
# CHECK=0).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
CTRL=${CTRL:-$HOME/kit/test/control}
OUT=${1:-$HOME/results/check}
if [ -n "${2:-}" ]; then load_config "$2" || exit 1; fi
[ -s "$CTRL/check.env" ] || { echo "no control in $CTRL"; exit 1; }
# shellcheck disable=SC1091
. "$CTRL/check.env"   # CHECK_VOL_URL CHECK_TRACE (relative to CTRL) CHECK_MIN_R, and per model that made reference
                      # maps CHECK_MODEL_SHA256_<prefix>=<its checkpoint sha256> (optional; enforced when present)
TRACE=$CTRL/${CHECK_TRACE:?}; REF=$CTRL/ref
mkdir -p "$OUT"
Z=$OUT/control_61.zarr
export TORCHDYNAMO_DISABLE=1 OMP_NUM_THREADS=${INK_OMP:-8} OPENBLAS_NUM_THREADS=1
CB=${CHECK_BATCH:-${BATCH_SIZE:-16}}; CW=${CHECK_NUM_WORKERS:-${INK_NUM_WORKERS:-0}}; CC=${CHECK_CACHE_GB:-${RENDER_CACHE_GB:-8}}
t=$(date +%s)
if [ ! -e "$Z/.done" ]; then
  "$VC" vc_render_tifxyz --volume "$CHECK_VOL_URL" --segmentation "$TRACE" --scale 1 --group-idx 0 --num-slices 61 \
      --slice-step 1 --cache-gb "$CC" --flip-normals --zarr-compressor zstd --timeout 180 --zarr-output "$Z" \
      < /dev/null > "$OUT/render.log" 2>&1 && touch "$Z/.done" || { echo "FAIL: control render failed"; tail -n 3 "$OUT/render.log"; exit 1; }
fi
echo "check render $(( $(date +%s) - t ))s (61 layers, cache ${CC} GB)"
[ "${CHECK_RENDER_ONLY:-0}" = 1 ] && exit 0
# the model, and the reference maps it has in the control
if [ -n "${PREFIX:-}" ] && [ -n "${MODEL_URL:-}" ] && [ -n "${MODEL_SHA256:-}" ]; then P=$PREFIX MU=$MODEL_URL MS=$MODEL_SHA256
else P=rv2 MU=$RV2_URL MS=$RV2_SHA256; fi
mapfile -t refs < <(cd "$REF" 2> /dev/null && for f in "${P}"_s*.tif; do [[ "$f" =~ ^${P}_s[0-9]+(_reverse)?\.tif$ ]] && echo "$f"; done)
if [ "${#refs[@]}" = 0 ]; then
  echo "CANNOT CHECK model $P: the control has no reference maps for it ($REF/${P}_s*.tif)"; exit 2
fi
made_by=CHECK_MODEL_SHA256_${P//-/_}   # a - in the prefix is _ in this name
if [ -n "${!made_by:-}" ] && [ "${!made_by}" != "$MS" ]; then
  echo "CANNOT CHECK model $P: the control's $P maps were made by checkpoint ${!made_by:0:12}..., this run uses ${MS:0:12}..."; exit 2
fi
# the reference maps must be the ones the control shipped with
listed=$(cd "$REF" && for f in "${refs[@]}"; do grep -E "^[0-9a-f]{64}  (\./)?$f\$" SHA256SUMS 2> /dev/null; done)
if [ "$(grep -c . <<< "$listed")" != "${#refs[@]}" ] || ! (cd "$REF" && sha256sum -c --quiet - <<< "$listed" > /dev/null 2>&1); then
  echo "FAIL: the $P reference maps do not match $REF/SHA256SUMS (a damaged or incomplete control)"; exit 1
fi
starts=$(printf '%s\n' "${refs[@]}" | sed -E "s/^${P}_s([0-9]+).*/\1/" | sort -un | tr '\n' ' ')
nrev=$(printf '%s\n' "${refs[@]}" | grep -c '_reverse'); nfwd=$(( ${#refs[@]} - nrev ))
dir=forward; [ "$nrev" -gt 0 ] && dir=reverse; [ "$nrev" -gt 0 ] && [ "$nfwd" -gt 0 ] && dir=both
MF=$(install_model "$MU" "$MS" "$P") || exit 3
t=$(date +%s)
(cd "$VILLA" && CUDA_VISIBLE_DEVICES=${CHECK_GPU:-0} "$PY" -I "$WORK/infer_windows.py" "$Z" "$MF" "$OUT" \
    --starts $starts --direction "$dir" --prefix "$P" --no-compile --overlap 0.5 --blend-mode hann \
    --batch-size "$CB" --num-workers "$CW" < /dev/null > "$OUT/infer.log" 2>&1)
echo "check ink $(( $(date +%s) - t ))s, $(count_maps "$OUT" "$P") maps (model $P, $dir, batch $CB, data-loading workers $CW)"
"$PY" -I "$WORK/compare_maps.py" "$REF" "$OUT" --glob "${P}_s*.tif" --min-r "${CHECK_MIN_R:-0.99}" | tee "$OUT/check.tsv"
exit "${PIPESTATUS[0]}"
