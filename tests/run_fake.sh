#!/bin/bash
# run_fake.sh — run the whole kit on stand-in tools (tests/fake) in a throw-away HOME: no GPU, no VC3D, no downloads,
# seconds per scenario. It tests the orchestration (config, bands, boxes, the ink queue and its states, resume, the
# same-answer check, the model safety check), not the science. usage: tests/run_fake.sh [PYTHON] [scenario...]
# Runs from a copy of itself: bash reads a script while running it, so editing this file mid-run would break the run.
if [ -z "${RUN_FAKE_COPY:-}" ]; then
  c=$(mktemp "${TMPDIR:-/tmp}/run_fake.XXXXXX.sh"); cp "$0" "$c"
  RUN_FAKE_COPY=1 RUN_FAKE_REPO=$(cd "$(dirname "$0")/.." && pwd) exec bash "$c" "$@"
fi
set -uo pipefail
R=${RUN_FAKE_REPO:-$(cd "$(dirname "$0")/.." && pwd)}
PYBIN=${1:-${PYBIN:-python3}}; shift || true
SCEN=${*:-happy nodata minnew cover nostrips reserve blank outside inkfail renderfail netdown gpufail restart diskfull tracetimeout noumb workerdeath boxfail resume stop orphans extraseeds check safety dryrun}
T=$(mktemp -d "${TMPDIR:-/tmp}/kit-test.XXXXXX")
export HOME=$T WORK=$T/work VC=$R/tests/fake/AppRun PY=$PYBIN FAKE_PY=$PYBIN VILLA=$T/villa MODELS=$T/models NGPU=2
mkdir -p "$WORK" "$VILLA"
cp "$R"/kit/work/*.sh "$R"/kit/work/*.py "$WORK/"; cp "$R"/tests/fake/work/*.py "$WORK/"
mkdir -p "$T/pred.zarr/0" "$T/vol.zarr/0"
echo '{"zarr_format": 2, "shape": [12000, 1000, 1000], "chunks": [128, 128, 128], "dtype": "|u1"}' > "$T/pred.zarr/0/.zarray"
cp "$T/pred.zarr/0/.zarray" "$T/vol.zarr/0/.zarray"   # the "scan" only has to be reachable (scan_ok)
"$PY" -I -c "
import json, sys
json.dump({'control_points': [{'x': 500, 'y': 500, 'z': z} for z in range(0, 12001, 1000)]}, open(sys.argv[1], 'w'))" "$T/umb.json"
"$PY" -I -c "
import sys, torch
torch.save({'config': {'model': {'crop_size': [17, 64, 64]}}, 'state_dict': {'w': torch.zeros(3)}}, sys.argv[1])" "$T/model.pth"
SHA=$(sha256sum "$T/model.pth" | cut -d' ' -f1)
export RV2_URL=file://$T/model.pth RV2_SHA256=$SHA
# a control strip for run.sh's model preflight (and check.sh), as make_kit.sh would put it in the kit
mkdir -p "$HOME/kit/test/control"
echo '{"mode": "seed"}' > "$T/seedp.json"
"$PY" -I "$R/tests/fake/fake_vc.py" grow "$T/pred.zarr" "$T/ctrlp" "$T/seedp.json" 500 500 10000 > /dev/null
mv "$T"/ctrlp/auto_grown_* "$HOME/kit/test/control/trace"
printf 'CHECK_VOL_URL=file://%s/vol.zarr\nCHECK_MIN_R=0.99\nCHECK_TRACE=trace\n' "$T" > "$HOME/kit/test/control/check.env"
fails=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
config() {  # NAME [extra lines...]
  local f=$T/$1.env; shift
  { echo "S=FAKE"; echo "VOL_URL=file://$T/vol.zarr"; echo "PRED_URL=file://$T/pred.zarr"; echo "VOXEL_UM=8.64"
    echo "UMBILICUS=$T/umb.json"; echo 'BANDS="9000:10000 10000:11000"'; echo "MODEL_URL=file://$T/model.pth"
    echo "MODEL_SHA256=$SHA"; echo "PREFIX=rv2"; echo "CHECK=0"; echo "NEXP1=4"; echo "NEXP2=4"; echo "NTR=2"
    echo "MAXTRY=3"; echo "GRID=2"; echo "MIN_FREE_GB=1"; echo "RESULTS=$T/results"; echo "RUN_NAME=${f##*/}"; echo "FAKE_SEEDS=6"
    # stand-in strips are ~0.9-1.8 cm2, depending on the start patch that random growth makes: keep them all, so the
    # scenarios that act on a box's first strip (blank, outside, renderfail) find it (nostrips tests MINCM itself)
    echo "MINCM=0.5"
    for l in "$@"; do echo "$l"; done; } > "$f"
  echo "$f"
}
count() { local n=0 f; for f in "$1"/*.job*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }

for s in $SCEN; do
  echo "== $s"
  case $s in
    happy)
      c=$(config happy "DEL_ZARR=1")
      timeout 600 bash "$WORK/run.sh" "$c" > "$T/happy.log" 2>&1; rc=$?
      Q=$T/results/happy.env/queue
      [ "$rc" = 0 ] && ok "run.sh exit 0" || bad "run.sh exit $rc (see $T/happy.log)"
      d=$(count "$Q/done"); n=$(ls -d "$T"/results/happy.env/band_*/box_*/traces/t*/auto_trace_* 2> /dev/null | wc -l)
      [ "$d" -gt 0 ] && [ "$d" = "$n" ] && ok "$d of $n strips done" || bad "$d done of $n strips; $(bash "$WORK/inkq.sh" status "$T/results/happy.env")"
      for st in pending running blank failed outside; do [ "$(count "$Q/$st")" = 0 ] || bad "$st not empty"; done
      grep -h 'seeds dropped' "$T"/results/happy.env/band_*/seeds_mask.log | head -n 1 | grep -q '^1 of 6' && ok "mask filter dropped the outside seed" || bad "mask filter"
      m=1; for r in "$T"/results/happy.env/band_*/box_*/render/t*; do
        k=$(find "$r" -maxdepth 1 -regextype egrep -regex '.*/rv2_s[0-9]+(_reverse)?\.tif' | wc -l); side=$(cat "$r/side")
        want=11; [ "$side" = both ] && want=22; [ "$k" = "$want" ] || { m=0; bad "$r: $k maps, side $side"; }
        ls -d "$r"/*.zarr > /dev/null 2>&1 && { m=0; bad "DEL_ZARR left $(ls -d "$r"/*.zarr)"; }
      done; [ "$m" = 1 ] && ok "every strip has its maps, temporary volumes removed"
      [ "$(cut -f1 "$T/results/happy.env/windows_rv2.tsv" | tail -n +2 | tr '\n' ' ')" = "2 6 10 14 18 22 26 30 34 38 42 " ] \
        && ok "window starts 2..42 for depth 17" || bad "windows: $(cat "$T/results/happy.env/windows_rv2.tsv")"
      grep -q 'searched' "$T/results/happy.env/summary.txt" && ok "summary written" || bad "no summary"
      grep -q 'phase  strip' "$T/results/happy.env/summary.txt" && ok "each strip's whole worker time is counted (phase strip)" \
        || bad "no strip phase in summary.txt"
      [ "$(sort "$T"/results/happy.env/ink.tsv | cut -f1 | uniq -d | wc -l)" = 0 ] && ok "no strip inked twice" || bad "a strip was inked twice"
      ;;
    nodata)
      # renders with no-data areas, and an ink step that writes a comb of strokes there (as Reader V3 does)
      c=$(config nodata 'BANDS="9000:10000"')
      FAKE_RENDER_HOLES=1 FAKE_INK_COMB=1 timeout 600 bash "$WORK/run.sh" "$c" > "$T/nodata.log" 2>&1; rc=$?
      [ "$rc" = 0 ] && ok "run.sh exit 0" || bad "run.sh exit $rc (see $T/nodata.log)"
      read -r nm nb nr < <("$PY" -I "$R/tests/nodata_verify.py" "$T/results/nodata.env" rv2 17)
      [ "${nm:-0}" -gt 0 ] && [ "$nb" = 0 ] && ok "$nm maps: 0 where their input layers had no data, unchanged elsewhere" \
        || bad "nodata: $nm maps, $nb wrong"
      [ "${nr:-0}" -gt 0 ] && ok "nodata_rv2.tsv files: $nr comb pixels set to 0" || bad "nodata: nothing removed"
      grep -q 'phase  nodata' "$T/results/nodata.env/summary.txt" && ok "summary counts the nodata step" || bad "no nodata phase in summary.txt"
      c=$(config nodataoff 'BANDS="9000:10000"' NODATA=0)
      FAKE_RENDER_HOLES=1 FAKE_INK_COMB=1 timeout 600 bash "$WORK/run.sh" "$c" > "$T/nodataoff.log" 2>&1; rc=$?
      read -r nm nb nr < <("$PY" -I "$R/tests/nodata_verify.py" "$T/results/nodataoff.env" rv2 17)
      [ "$rc" = 0 ] && [ "${nm:-0}" -gt 0 ] && [ "${nb:-0}" -gt 0 ] && ok "NODATA=0 keeps the raw maps (comb in $nb of $nm)" \
        || bad "NODATA=0: rc $rc, $nm maps, $nb with comb"
      c=$(config nodatabad NODATA_MARGIN=x)
      bash "$WORK/run.sh" "$c" > "$T/nodatabad.log" 2>&1; rc=$?
      [ "$rc" = 1 ] && grep -q 'NODATA_MARGIN must be' "$T/nodatabad.log" && ok "a bad NODATA_MARGIN stops the run at once" \
        || bad "bad margin: rc $rc $(tail -n 2 "$T/nodatabad.log")"
      ;;
    minnew)
      # strips that add little new area to their box's inked strips are kept but not inked (MIN_NEW)
      c=$(config minnew 'BANDS="9000:10000"' "MIN_NEW=95" "MAXTRY=4")
      FAKE_TRACE_SAME=1 timeout 600 bash "$WORK/run.sh" "$c" > "$T/minnew.log" 2>&1; rc=$?   # strips on one sheet: overlap
      RN=$T/results/minnew.env; n=0 leak=0
      for m in "$RN"/band_*/box_*/traces/t*/.setaside; do
        [ -e "$m" ] || continue; n=$((n + 1)); td=$(dirname "$m"); k=$(basename "$td"); b=$(dirname "$(dirname "$td")")
        grep -rqs -- "$td/" "$RN/queue" && leak=$((leak + 1))
        [ -e "$b/render/$k" ] && leak=$((leak + 1))
      done
      [ "$rc" = 0 ] && [ "$n" -ge 1 ] && [ "$leak" = 0 ] && ok "$n strips set aside (kept, not queued, not rendered)" \
        || bad "minnew: rc $rc, $n set aside, $leak leaked into the queue"
      grep -q "kept, not inked" "$RN"/band_*/box_*/run.log && grep -q 'strips setaside' "$RN/summary.txt" \
        && ok "logged, and counted in the summary" || bad "minnew: no log line or summary row"
      ;;
    cover)
      # COVER mode: a greedy cover of the grown patches is inked instead of stitched strips
      c=$(config cover 'BANDS="9000:10000"' COVER=1 COVER_FRAC=0.8 MINCM=0.1)   # stand-in patches are < 1 cm2
      timeout 600 bash "$WORK/run.sh" "$c" > "$T/cover.log" 2>&1; rc=$?
      RN=$T/results/cover.env
      nt=$(awk 'FNR > 1' "$RN"/band_*/box_*/cover.tsv 2> /dev/null | wc -l)
      np=$(grep -l '/patches/auto_grown_' "$RN"/queue/done/*.job 2> /dev/null | wc -l)
      ntr=$(ls -d "$RN"/band_*/box_*/traces/t* 2> /dev/null | wc -l)
      [ "$rc" = 0 ] && [ "$nt" -ge 1 ] && [ "$np" = "$nt" ] && [ "$ntr" = 0 ] \
        && ok "COVER: $np picked patches inked, no strip stitched" || bad "cover: rc $rc, $nt picks, $np inked, $ntr strip dirs"
      low=$(for f in "$RN"/band_*/box_*/cover.tsv; do tail -n 1 "$f" | cut -f4; done | awk '$1 < 80' | wc -l)
      [ "$low" = 0 ] && ok "every box's picks reach COVER_FRAC 0.8 of its patch union" || bad "$low boxes below 80 %"
      # a picked patch lost from the queue comes back on the next start (band.sh reconcile)
      lost=$(ls "$RN"/queue/done/*.job | head -n 1); rm -f "$lost"
      timeout 600 bash "$WORK/run.sh" "$c" > "$T/cover2.log" 2>&1; rc=$?
      [ "$rc" = 0 ] && [ -e "$lost" ] && [ "$(grep -l '/patches/auto_grown_' "$RN"/queue/done/*.job | wc -l)" = "$nt" ] \
        && ok "a resumed COVER run queues its picked patches again" || bad "cover resume: rc $rc, $(basename "$lost") back: $([ -e "$lost" ] && echo yes || echo no)"
      # with the mask check (MASK_CHECK=1, the default), patches mostly outside the scan's mask are left out of the cover:
      # the stand-in mask ends at z 10300, which leaves expansion patches (z 9400-10600) 0.6-1.0 inside
      c=$(config covermask 'BANDS="9000:10000"' COVER=1 COVER_FRAC=0.8 MINCM=0.1)
      FAKE_MASK_ZMAX=10300 timeout 600 bash "$WORK/run.sh" "$c" > "$T/covermask.log" 2>&1; rc=$?
      RN=$T/results/covermask.env
      nout=$(awk 'FNR > 1' "$RN"/band_*/box_*/cover.outside.tsv 2> /dev/null | wc -l)
      badout=$(awk -F'\t' 'FNR > 1 && $2 >= 0.8' "$RN"/band_*/box_*/cover.outside.tsv 2> /dev/null | wc -l)
      lowpick=$(awk -F'\t' 'FNR > 1 && $7 < 0.8' "$RN"/band_*/box_*/cover.tsv 2> /dev/null | wc -l)
      inked=$(for n in $(awk -F'\t' 'FNR > 1 {print $1}' "$RN"/band_*/box_*/cover.outside.tsv 2> /dev/null); do grep -l "/$n\$" "$RN"/queue/*/*.job* 2> /dev/null; done | wc -l)
      [ "$rc" = 0 ] && [ "$nout" -ge 1 ] && [ "$badout" = 0 ] && [ "$lowpick" = 0 ] && [ "$inked" = 0 ] \
        && ok "MASK_CHECK in COVER mode: $nout patches mostly outside the scan left out, none queued, every pick >= 0.8 inside" \
        || bad "cover mask: rc $rc, $nout left out ($badout of them >= 0.8 inside), $lowpick picks < 0.8, $inked left-out patches queued"
      grep -qE "^  strips masked +$nout " "$RN/summary.txt" && grep -q 'outside the scan mask left out' "$RN"/band_*/box_*/run.log \
        && ok "the box logs and the summary count them" || bad "cover mask counts: $(grep masked "$RN/summary.txt")"
      # --drop-single on made-up patches: two that overlap, one far from both
      "$PY" -I -c "
import json, sys, numpy as np, tifffile
from pathlib import Path
for name, x0 in (('auto_grown_a', 1000), ('auto_grown_b', 1100), ('auto_grown_c', 5000)):
    d = Path(sys.argv[1]) / name; d.mkdir(parents=True)
    r, c = np.mgrid[0:20, 0:20].astype(np.float32)
    for k, v in (('x', x0 + 20 * c), ('y', 3000 + 0 * c), ('z', 9000 + 20 * r)):
        tifffile.imwrite(d / f'{k}.tif', v.astype(np.float32))
    (d / 'meta.json').write_text(json.dumps({'area_cm2': 0.14}))" "$T/dsp"
      "$PY" -I "$WORK/cover.py" "$T/dsp" "$T/ds0.tsv" --frac 1 --min-cm2 0 --vx 9.362 > /dev/null
      "$PY" -I "$WORK/cover.py" "$T/dsp" "$T/ds1.tsv" --frac 1 --min-cm2 0 --vx 9.362 --drop-single > /dev/null
      grep -q auto_grown_c "$T/ds0.tsv" && ! grep -q auto_grown_c "$T/ds1.tsv" && grep -q auto_grown_a "$T/ds1.tsv" \
        && [ "$(awk -F'\t' '$1 == "auto_grown_c" {print $5}' "$T/ds0.tsv")" = 1 ] \
        && ok "DROP_SINGLE leaves out the patch no other comes near (marked single_seen 1)" \
        || bad "drop-single: $(cut -f1,5 "$T/ds0.tsv" | tr '\n' ' ') / $(cut -f1 "$T/ds1.tsv" | tr '\n' ' ')"
      ;;
    nostrips)
      # no strip big enough to keep anywhere: the run must not end "done"
      c=$(config nostrips 'BANDS="9000:10000"' MINCM=1000)
      timeout 600 bash "$WORK/run.sh" "$c" > "$T/nostrips.log" 2>&1; rc=$?
      RN=$T/results/nostrips.env
      [ "$rc" = 6 ] && grep -q 'NOTHING SEARCHED' "$T/nostrips.log" && ok "a run that inked nothing ends with exit 6, NOTHING SEARCHED" \
        || bad "nostrips: rc $rc, $(tail -n 1 "$T/nostrips.log")"
      [ "$(grep -c 'no strip kept (largest' "$RN/alerts.log")" -ge 1 ] && grep -q 'WARNING: .*no strip kept' "$RN/summary.txt" \
        && ok "each such box warns, with its largest strip, and the summary shows it" || bad "nostrips: no box warning"
      ;;
    reserve)
      # the default RAM reserve is capped at 40 % of RAM, so a small machine still gets growers
      c=$(config reserve)
      got=$( . "$WORK/common.sh"; load_config "$c" > /dev/null; THREADS=1000 NGPU=1 grower_slots 2> /dev/null)
      exp=$( . "$WORK/common.sh"; load_config "$c" > /dev/null; m=$(mem_total_gb)
             awk -v m="$m" -v f=$(( 16 + (RENDER_CACHE_GB + 5) + (INK_NUM_WORKERS + 1) / 2 )) -v g="$GROWER_GB" \
               'BEGIN {c = int(m * 2 / 5); r = (f > c ? c : f); n = int((m - r) / g); print (n < 2 ? 2 : n)}')
      [ -n "$got" ] && [ "$got" = "$exp" ] && [ "$got" -gt 2 ] && ok "grower slots by RAM: $got (reserve capped at 40 % of RAM)" \
        || bad "reserve: got '$got', expected '$exp'"
      ;;
    blank)
      c=$(config blank "FAKE_RENDER_BLANK=box_00/traces/t1/" "RENDER_RETRIES=1")
      FAKE_RENDER_BLANK=box_00/traces/t1/ timeout 600 bash "$WORK/run.sh" "$c" > "$T/blank.log" 2>&1
      Q=$T/results/blank.env/queue; b=$(count "$Q/blank")
      [ "$b" -ge 1 ] && ok "$b blank strips set aside" || bad "no blank strip ($(bash "$WORK/inkq.sh" status "$T/results/blank.env"))"
      grep -q 'retry' "$T/results/blank.env/ink.tsv" && ok "blank strip got a fresh render first" || bad "no retry recorded"
      ls -d "$T"/results/blank.env/band_*/box_00/traces/t1/auto_trace_* > /dev/null 2>&1 && ok "blank strip's trace kept" || bad "trace gone"
      ls -d "$T"/results/blank.env/band_*/box_00/render/t1/t1_61_r1.zarr > /dev/null 2>&1 && ok "retry used a fresh volume name" || bad "no _r1 render"
      bash "$WORK/inkq.sh" retry "$T/results/blank.env" blank | grep -q 'queued again' && [ "$(count "$Q/pending")" = "$b" ] \
        && ok "retry blank puts them back" || bad "retry blank"
      ;;
    outside)
      c=$(config outside)
      FAKE_OUTSIDE=box_01/traces/t1/ timeout 600 bash "$WORK/run.sh" "$c" > "$T/outside.log" 2>&1
      o=$(count "$T/results/outside.env/queue/outside")
      [ "$o" -ge 1 ] && ok "$o strips skipped as OUTSIDE-MASK" || bad "no outside strip"
      ls "$T"/results/outside.env/band_*/box_01/render/t1/*.zarr > /dev/null 2>&1 && bad "outside strip was rendered" || ok "outside strip not rendered"
      out=$(bash "$WORK/inkq.sh" retry "$T/results/outside.env" outside 2>&1)
      [ "$(count "$T/results/outside.env/queue/pending")" = "$o" ] && [ "$(count "$T/results/outside.env/queue/outside")" = 0 ] \
        && ok "retry outside puts them back in the queue ($out)" || bad "retry outside: $out"
      ;;
    inkfail)
      c=$(config inkfail)
      FAKE_INK_FAIL=box_00/render/t2/ timeout 600 bash "$WORK/run.sh" "$c" > "$T/inkfail.log" 2>&1
      f=$(count "$T/results/inkfail.env/queue/failed")
      [ "$f" -ge 1 ] && ok "$f failed strips recorded" || bad "no failed strip"
      grep -q 'COMPLETE WITH FAILED STRIPS' "$T/inkfail.log" && ok "run.sh reports the failed strips (exit 6)" || bad "no failed-strips report"
      grep -q 'out of memory' "$T"/results/inkfail.env/queue/failed/*.job && ok "failure reason kept" || bad "no reason"
      bash "$WORK/watch.sh" "$T/results/inkfail.env" > "$T/watch.out"; [ $? = 1 ] && grep -q 'ALERT FAILED' "$T/watch.out" \
        && ok "watch.sh alerts on failed strips" || bad "watch.sh: $(cat "$T/watch.out")"
      ;;
    renderfail)
      c=$(config renderfail "RENDER_RETRIES=1")
      FAKE_RENDER_FAIL=box_00/traces/t1/ timeout 600 bash "$WORK/run.sh" "$c" > "$T/renderfail.log" 2>&1
      Q=$T/results/renderfail.env/queue
      [ "$(count "$Q/failed")" -ge 1 ] && grep -q 'render failed' "$Q"/failed/*.job && ok "a failed render ends in failed/, not blank/" \
        || bad "renderfail: $(bash "$WORK/inkq.sh" status "$T/results/renderfail.env")"
      [ "$(count "$Q/blank")" = 0 ] && ok "nothing filed as blank" || bad "render failure filed as blank"
      ;;
    netdown)
      c=$(config netdown "VOL_URL=file://$T/no-such-scan.zarr" "NET_DOWN_MAX=5")
      FAKE_RENDER_FAIL=/band_z timeout 600 bash "$WORK/run.sh" "$c" > "$T/netdown.log" 2>&1; rc=$?
      Q=$T/results/netdown.env/queue
      [ "$rc" != 0 ] && ok "run.sh ends with an error (exit $rc) when the scan stays unreachable" || bad "netdown: exit 0"
      grep -q 'the scan is not reachable' "$T/results/netdown.env/alerts.log" && ok "alert: scan not reachable" || bad "no network alert"
      [ "$(count "$Q/failed")" = 0 ] && [ "$(count "$Q/pending")" -ge 1 ] && ok "the queue was not drained into failed/" \
        || bad "queue: $(bash "$WORK/inkq.sh" status "$T/results/netdown.env")"
      ;;
    gpufail)
      c=$(config gpufail "GPU_FAIL_MAX=2" "WORKER_RESTARTS=0")
      FAKE_INK_FAIL=. timeout 600 bash "$WORK/run.sh" "$c" > "$T/gpufail.log" 2>&1; rc=$?
      [ "$rc" != 0 ] && ok "run.sh ends with an error (exit $rc) when every worker's GPU fails" || bad "gpufail: exit 0"
      grep -q 'in a row failed in the ink step' "$T/results/gpufail.env/alerts.log" && ok "alert: strips in a row failed" || bad "no GPU alert"
      f=$(count "$T/results/gpufail.env/queue/failed")
      [ "$f" -le 4 ] && ok "the workers stopped after $f failed strips instead of eating the queue" || bad "$f strips failed"
      ;;
    restart)
      # a passing GPU fault: the first 4 strip inks fail, both workers are retired, start again and finish the queue
      c=$(config restart 'BANDS="9000:10000"' "GPU_FAIL_MAX=2" "WORKER_RESTARTS=2" "WORKER_PAUSE=1")
      FAKE_INK_FAIL_FIRST=4 FAKE_INK_FAIL_DIR=$T/failfirst timeout 600 bash "$WORK/run.sh" "$c" > "$T/restart.log" 2>&1; rc=$?
      Q=$T/results/restart.env/queue
      grep -q 'starts again in' "$T/results/restart.env/alerts.log" && grep -q 'starts again$' "$T/results/restart.env/ink.log" \
        && ok "retired workers start again after the pause" || bad "no restart: $(tail -n 3 "$T/results/restart.env/alerts.log")"
      [ "$rc" = 6 ] && [ "$(count "$Q/failed")" = 4 ] && [ "$(count "$Q/pending")" = 0 ] \
        && ok "the queue is finished: $(count "$Q/done") strips done, the 4 failed ones reported (exit 6)" \
        || bad "restart: rc $rc, done $(count "$Q/done"), failed $(count "$Q/failed"), pending $(count "$Q/pending")"
      # a worker that dies mid-strip (kill -9): its tools are stopped, its strip requeued, the worker started again
      c=$(config restart2 'BANDS="9000:10000"' "WORKER_PAUSE=1")
      FAKE_INK_SLEEP=4 bash "$WORK/run.sh" "$c" > "$T/restart2.log" 2>&1 &
      rp=$!; ip=
      for _ in $(seq 240); do ip=$(pgrep -f -- "$T/work/infer_windows.py $T/results/restart2.env/band_z" | head -n 1); [ -n "$ip" ] && break; sleep 0.5; done
      main=$(pgrep -of -- "$T/work/inkq.sh workers"); p=$ip
      while [ -n "$p" ]; do pp=$(ps -o ppid= -p "$p" | tr -d ' '); [ "$pp" = "$main" ] && break; [ -z "$pp" ] || [ "$pp" = 1 ] && p=; p=${p:+$pp}; done
      if [ -n "$p" ] && [ -n "$ip" ]; then kill -9 "$p"; else bad "no worker found to kill (infer $ip, main $main)"; fi
      sleep 2; kill -0 "$ip" 2> /dev/null && orphan=1 || orphan=0
      for _ in $(seq 300); do kill -0 "$rp" 2> /dev/null || break; sleep 1; done
      wait "$rp"; rc=$?; Q=$T/results/restart2.env/queue
      [ "$orphan" = 1 ] && ok "the killed worker's ink step outlived it (an orphan)" || ok "(the ink step ended with its worker)"
      grep -q 'left by worker' "$T/results/restart2.env/ink.log" && grep -q 'ended (exit 137)' "$T/results/restart2.env/alerts.log" \
        && ok "the dead worker's strip went back to the queue" || bad "no requeue: $(tail -n 3 "$T/results/restart2.env/ink.log")"
      [ "$rc" = 0 ] && [ "$(count "$Q/failed")" = 0 ] && [ "$(count "$Q/pending")" = 0 ] && [ "$(count "$Q/running")" = 0 ] \
        && ok "run.sh exit 0: every strip done ($(count "$Q/done"))" || bad "restart2: rc $rc, done $(count "$Q/done"), failed $(count "$Q/failed")"
      sleep 1; [ "$(ps -eo args | grep -c "[k]it-test.*${T##*.}/work/")" = 0 ] && ok "nothing left running" || bad "processes left"
      ;;
    diskfull)
      c=$(config diskfull "MIN_FREE_GB=999999" "DISK_WAITS=0")
      timeout 600 bash "$WORK/run.sh" "$c" > "$T/diskfull.log" 2>&1; rc=$?
      Q=$T/results/diskfull.env/queue
      [ "$rc" != 0 ] && ok "run.sh ends with an error (exit $rc) when the disk stays full" || bad "diskfull: exit 0"
      grep -q 'DISK FULL' "$T/results/diskfull.env/alerts.log" && ok "alert: DISK FULL" || bad "no DISK FULL alert"
      [ "$(count "$Q/running")" = 0 ] && [ "$(count "$Q/pending")" -ge 1 ] && ok "strips kept in the queue for a restart" \
        || bad "queue after the stop: $(bash "$WORK/inkq.sh" status "$T/results/diskfull.env")"
      ;;
    tracetimeout)
      c=$(config tracetimeout "TRACE_TIMEOUT=2")
      FAKE_TRACE_SLEEP=6 FAKE_TRACE_HANG=box_00/ timeout 600 bash "$WORK/run.sh" "$c" > "$T/tracetimeout.log" 2>&1; rc=$?
      grep -q 'stopped by TRACE_TIMEOUT' "$T"/results/tracetimeout.env/band_*/box_00/run.log && ok "a hung stitcher is stopped" \
        || bad "no TRACE_TIMEOUT line"
      [ "$rc" = 0 ] && ok "the run still finishes (exit 0; the other boxes' strips are inked)" || bad "tracetimeout: exit $rc"
      ;;
    noumb)
      c=$(config noumb "UMBILICUS=$T/missing_umbilicus.json")
      timeout 60 bash "$WORK/run.sh" "$c" > "$T/noumb.log" 2>&1; rc=$?
      [ "$rc" != 0 ] && grep -q 'scroll axis' "$T/noumb.log" && ok "a missing axis file stops the run at once" || bad "noumb: rc $rc"
      ;;
    workerdeath)
      c=$(config workerdeath)
      FAKE_SLEEP=0.5 bash "$WORK/run.sh" "$c" > "$T/workerdeath.log" 2>&1 &
      rp=$!
      for _ in $(seq 60); do pgrep -f "$T/work/inkq.sh workers" > /dev/null && break; sleep 0.5; done
      sleep 8; pkill -f "$T/work/inkq.sh workers"
      for _ in $(seq 90); do kill -0 "$rp" 2> /dev/null || break; sleep 1; done
      if kill -0 "$rp" 2> /dev/null; then bad "run.sh still running 90 s after its ink workers died"; kill "$rp"
      else wait "$rp"; rc=$?; [ "$rc" = 4 ] && ok "run.sh stops (exit 4) when its ink workers die" || bad "workerdeath: exit $rc"; fi
      sleep 2
      [ "$(ps -eo args | grep -c "[k]it-test.*${T##*.}/work/")" = 0 ] && ok "and leaves nothing running" || bad "processes left"
      ;;
    boxfail)
      c=$(config boxfail "PASS_PAUSE=1" "BAND_TRIES=2" "BAND_PAUSE=1")
      FAKE_GROW_FAIL=band_z09000-10000/box_00/ timeout 900 bash "$WORK/run.sh" "$c" > "$T/boxfail.log" 2>&1; rc=$?
      grep -q 'only 0 patches from' "$T"/results/boxfail.env/band_z09000-10000/box_00/run.log && ok "a failing growth pass is detected and retried" \
        || bad "no pass-failure line"
      [ ! -e "$T/results/boxfail.env/band_z09000-10000/.grown" ] && ok "the band is not marked grown" || bad "band marked grown"
      grep -q 'try 2 of 2' "$T/boxfail.log" && ok "run.sh tried the band again" || bad "no band retry"
      [ "$rc" = 5 ] && grep -q 'NOT COMPLETE: bands not grown' "$T/boxfail.log" && ok "the run ends NOT COMPLETE naming the band (exit 5)" \
        || bad "boxfail: exit $rc"
      [ -e "$T/results/boxfail.env/band_z10000-11000/.grown" ] && ok "the other band still finished" || bad "other band not grown"
      ;;
    resume)
      c=$(config resume)
      FAKE_SLEEP=0.5 timeout 9 bash "$WORK/run.sh" "$c" > "$T/resume1.log" 2>&1
      pkill -f "$T/work/" 2> /dev/null; sleep 2
      before=$(count "$T/results/resume.env/queue/done")
      timeout 900 bash "$WORK/run.sh" "$c" > "$T/resume2.log" 2>&1; rc=$?
      Q=$T/results/resume.env/queue; d=$(count "$Q/done")
      n=$(ls -d "$T"/results/resume.env/band_*/box_*/traces/t*/auto_trace_* 2> /dev/null | wc -l)
      [ "$before" -lt "$n" ] || bad "the stop came too late to test resuming ($before of $n already done)"
      [ "$rc" = 0 ] && [ "$d" = "$n" ] && [ "$d" -gt 0 ] && ok "resumed: $before done after the stop, $d of $n at the end" \
        || bad "resume: rc $rc, $d done of $n ($(bash "$WORK/inkq.sh" status "$T/results/resume.env"))"
      [ "$(count "$Q/running")" = 0 ] && ok "no strip left running" || bad "strips left in running/"
      ;;
    stop)
      # a stop mid-ink, then a restart at once: rc-test-3 found the restart refused, because the stopped run's tools (the
      # real stitcher can ignore TERM) still held the run's lock. Here every stand-in tool ignores TERM.
      c=$(config stop); L=$T/results/stop.env/.run.lock; Q=$T/results/stop.env/queue
      export FAKE_SLEEP=0.5 FAKE_INK_SLEEP=30 FAKE_IGNORE_TERM=1
      bash "$WORK/run.sh" "$c" > "$T/stop1.log" 2>&1 &
      rp=$!
      for _ in $(seq 120); do [ "$(count "$Q/running")" -gt 0 ] && break; sleep 0.5; done
      [ "$(count "$Q/running")" -gt 0 ] && ok "ink running when the stop comes" || bad "no ink running before the stop"
      t=$(date +%s); timeout 60 bash "$WORK/run.sh" "$c" > "$T/stop0.log" 2>&1; rc=$?
      [ "$rc" = 1 ] && grep -q 'already using' "$T/stop0.log" && [ $(( $(date +%s) - t )) -lt 10 ] \
        && ok "a second run.sh while one runs is refused at once" || bad "second run.sh: exit $rc after $(( $(date +%s) - t ))s: $(tail -n 1 "$T/stop0.log")"
      # TERM straight to run.sh (kill, Ctrl-C) and a new run.sh at once: it waits for the first one to finish stopping
      kill -TERM "$rp"; sleep 0.5
      bash "$WORK/run.sh" "$c" > "$T/stop2.log" 2>&1 &
      rp2=$!
      wait "$rp" 2> /dev/null
      for _ in $(seq 120); do grep -q requeued "$T/results/stop.env/ink.log" && [ "$(count "$Q/running")" -gt 0 ] && break; sleep 0.5; done
      grep -q 'waiting up to 120 s' "$T/stop2.log" && grep -q requeued "$T/results/stop.env/ink.log" \
        && ok "a run.sh started while the first was stopping waited for it, then resumed" || bad "stopping wait: $(head -n 2 "$T/stop2.log")"
      grep -q 'sent KILL' "$T/stop1.log" && ok "tools that ignore TERM got KILL ($(grep -o 'process(es) still running.*' "$T/stop1.log" | head -n 1))" \
        || bad "no KILL line in stop1.log"
      t=$(date +%s); bash "$WORK/stop.sh" "$T/results/stop.env" > "$T/stop.log" 2>&1; rc=$?
      [ "$rc" = 0 ] && grep -q 'no process of the run is left' "$T/stop.log" \
        && ok "stop.sh returned after $(( $(date +%s) - t ))s with nothing of the run left" || bad "stop.sh: exit $rc: $(tail -n 2 "$T/stop.log")"
      wait "$rp2" 2> /dev/null
      left=$( . "$WORK/common.sh"; x=$(holders "$L"); wc -w <<< "$x")
      n=$(ps -eo args | grep -cE "[k]it-test\.${T##*.}/(work/|results/stop\.env)")
      [ "$left" = 0 ] && [ "$n" = 0 ] && ok "a stop leaves no kit process behind" \
        || bad "$left holders of the lock, $n kit processes left after the stop: $(ps -eo pid,args | grep -E "[k]it-test\.${T##*.}/(work/|results/stop\.env)" | head -n 3)"
      grep -q '^stopping' "$T/stop1.log" && grep -q '^stopping' "$T/stop2.log" && ok "run.sh logged both stops" || bad "a stop line is missing"
      unset FAKE_SLEEP FAKE_INK_SLEEP FAKE_IGNORE_TERM
      timeout 900 bash "$WORK/run.sh" "$c" > "$T/stop3.log" 2>&1; rc=$?   # right after stop.sh: no pause
      d=$(count "$Q/done"); n=$(ls -d "$T"/results/stop.env/band_*/box_*/traces/t*/auto_trace_* 2> /dev/null | sed 's|/auto_trace_[^/]*$||' | sort -u | wc -l)
      [ "$rc" = 0 ] && [ "$d" = "$n" ] && ok "restart right after stop.sh finished: $d of $n strips" || bad "restart: exit $rc, $d of $n: $(head -n 3 "$T/stop3.log")"
      ;;
    orphans)
      # run.sh killed with -9 cannot stop what it started: stop.sh ends those processes. A process that still holds the
      # lock (a stopped run's tool) makes run.sh wait, then start.
      c=$(config orphans); L=$T/results/orphans.env/.run.lock
      FAKE_SLEEP=0.5 FAKE_INK_SLEEP=8 bash "$WORK/run.sh" "$c" > "$T/orphans1.log" 2>&1 &
      rp=$!
      for _ in $(seq 120); do [ "$(count "$T/results/orphans.env/queue/running")" -gt 0 ] && break; sleep 0.5; done
      { kill -9 "$rp"; wait "$rp"; } 2> /dev/null
      n0=$( . "$WORK/common.sh"; x=$(holders "$L"); wc -w <<< "$x")
      [ "$n0" -gt 0 ] && ok "$n0 processes of the run outlive a run.sh killed with -9" || bad "no processes left to test stop.sh with"
      bash "$WORK/stop.sh" "$T/results/orphans.env" > "$T/orphans-stop.log" 2>&1; rc=$?
      n1=$( . "$WORK/common.sh"; x=$(holders "$L"); wc -w <<< "$x")
      [ "$rc" = 0 ] && [ "$n1" = 0 ] && grep -q 'left by the run' "$T/orphans-stop.log" && ok "stop.sh ended them" \
        || bad "orphans: stop.sh exit $rc, $n1 left: $(tr '\n' ' ' < "$T/orphans-stop.log")"
      flock "$L" sleep 6 &   # holds the run's lock for 6 s, as a stopped run's tool can
      sleep 1
      t=$(date +%s); timeout 900 bash "$WORK/run.sh" "$c" > "$T/orphans2.log" 2>&1; rc=$?
      grep -q 'waiting up to 120 s' "$T/orphans2.log" && ok "run.sh waited for the process holding the lock" \
        || bad "no wait: $(head -n 2 "$T/orphans2.log")"
      d=$(count "$T/results/orphans.env/queue/done"); n=$(ls -d "$T"/results/orphans.env/band_*/box_*/traces/t*/auto_trace_* 2> /dev/null | sed 's|/auto_trace_[^/]*$||' | sort -u | wc -l)
      [ "$rc" = 0 ] && [ "$d" = "$n" ] && [ "$d" -gt 0 ] && ok "then finished the search: $d of $n strips in $(( $(date +%s) - t ))s" \
        || bad "after the wait: exit $rc, $d of $n: $(head -n 3 "$T/orphans2.log")"
      ;;
    check)
      C=$T/ctrl; mkdir -p "$C/ref"
      echo '{"mode": "seed"}' > "$T/p.json"
      "$PY" -I "$R/tests/fake/fake_vc.py" grow "$T/pred.zarr" "$C/patches" "$T/p.json" 500 500 10000 > /dev/null
      mv "$C"/patches/auto_grown_* "$C/trace"
      printf 'CHECK_VOL_URL=file://%s/vol.zarr\nCHECK_MIN_R=0.99\nCHECK_TRACE=trace\n' "$T" > "$C/check.env"
      CTRL=$C bash "$WORK/check.sh" "$T/check0" > "$T/check0.log" 2>&1; rc=$?
      [ "$rc" = 2 ] && grep -q 'CANNOT CHECK model rv2' "$T/check0.log" && ok "no reference maps for the model: exit 2" \
        || bad "no refs: rc $rc $(tail -n 2 "$T/check0.log")"
      # reference maps as a trusted machine would make them (windows 2 6 10, forward), and another model's map next to them
      "$PY" -I "$WORK/infer_windows.py" "$T/check0/control_61.zarr" x "$C/ref" --starts 2 6 10 --direction forward --prefix rv2 > /dev/null
      "$PY" -I -c "
import sys, numpy as np, tifffile
tifffile.imwrite(sys.argv[2], 255 - tifffile.imread(sys.argv[1]))" "$C/ref/rv2_s2.tif" "$C/ref/rv3_s2.tif"
      (cd "$C/ref" && sha256sum rv2_s*.tif rv3_s*.tif > SHA256SUMS)
      CTRL=$C bash "$WORK/check.sh" "$T/check2" > "$T/check2.log" 2>&1 && grep -q PASS "$T/check2.log" && ok "check PASS on identical maps" \
        || bad "check: $(tail -n 3 "$T/check2.log")"
      [ "$(grep -c '^rv' "$T/check2/check.tsv")" = 3 ] && grep -q 'model rv2, forward' "$T/check2.log" \
        && ok "only the run's model's maps compared, at the reference windows" || bad "compared: $(cut -f1 "$T/check2/check.tsv" | tr '\n' ' ')"
      cc=$(config checkcfg "BATCH_SIZE=3")
      CTRL=$C bash "$WORK/check.sh" "$T/check2b" "$cc" > "$T/check2b.log" 2>&1 && grep -q 'batch 3' "$T/check2b.log" \
        && ok "with a config, the check uses its model and batch size" || bad "config check: $(tail -n 3 "$T/check2b.log")"
      echo "CHECK_MODEL_SHA256_rv2=$(printf '0%.0s' {1..64})" >> "$C/check.env"
      CTRL=$C bash "$WORK/check.sh" "$T/check2c" > "$T/check2c.log" 2>&1; rc=$?
      [ "$rc" = 2 ] && grep -q 'made by checkpoint' "$T/check2c.log" && ok "reference maps from another checkpoint: exit 2" \
        || bad "checkpoint mismatch: rc $rc $(tail -n 2 "$T/check2c.log")"
      sed -i '$d' "$C/check.env"; echo "CHECK_MODEL_SHA256_rv2=$SHA" >> "$C/check.env"
      "$PY" -I -c "
import sys, numpy as np, tifffile
a = tifffile.imread(sys.argv[1]); a[:10] = 255 - a[:10]; tifffile.imwrite(sys.argv[1], a)" "$C/ref/rv2_s6.tif"
      CTRL=$C bash "$WORK/check.sh" "$T/check3" > "$T/check3.log" 2>&1; rc=$?
      [ "$rc" = 1 ] && grep -q 'do not match' "$T/check3.log" && ok "a reference map that does not match SHA256SUMS: FAIL" \
        || bad "damaged ref: rc $rc $(tail -n 2 "$T/check3.log")"
      (cd "$C/ref" && sha256sum rv2_s*.tif rv3_s*.tif > SHA256SUMS)
      CTRL=$C bash "$WORK/check.sh" "$T/check4" > "$T/check4.log" 2>&1; rc=$?
      [ "$rc" = 1 ] && grep -q '^FAIL' "$T/check4.log" && grep -q $'rv2_s6.tif\tno' "$T/check4/check.tsv" \
        && ok "check FAIL on a changed map" || bad "check did not fail: $(tail -n 4 "$T/check4.log")"
      ;;
    safety)
      "$PY" -I -c "
import argparse, sys, torch
torch.save({'config': {'model': {'crop_size': [17]}}, 'args': argparse.Namespace(x=1)}, sys.argv[1])" "$T/unsafe.pth"
      us=$(sha256sum "$T/unsafe.pth" | cut -d' ' -f1)
      ( . "$WORK/common.sh"; install_model "file://$T/unsafe.pth" "$us" unsafe ) > "$T/safety.log" 2>&1; rc=$?
      [ "$rc" = 3 ] && grep -q 'SAFETY STOP' "$T/safety.log" && ok "a checkpoint holding objects is refused" || bad "safety: rc $rc $(cat "$T/safety.log")"
      ( . "$WORK/common.sh"; install_model "file://$T/model.pth" "deadbeef" bad ) > "$T/sha.log" 2>&1; rc=$?
      [ "$rc" = 2 ] && grep -q MISMATCH "$T/sha.log" && ok "a wrong checksum is refused" || bad "checksum: rc $rc"
      ( . "$WORK/common.sh"; f=$(install_model "file://$T/model.pth" "$SHA" good) && model_depth "$f" ) > "$T/depth.log" 2>&1
      [ "$(tail -n 1 "$T/depth.log")" = 17 ] && ok "crop depth 17 read from the checkpoint" || bad "depth: $(cat "$T/depth.log")"
      ;;
    extraseeds)
      # SEEDS_EXTRA: the config's own seed points in a band join its seeds, and the box holding one starts its first
      # strip at the patch grown there; a point outside the band is ignored. Every tracer started at a seed patch stalls
      # here (as 5 of 6 did at known letters on the real control), so the patch grown at the point is inked itself.
      # MAXTRY 1: the try started at the point comes on top, so the box still gets one try of its own rule
      printf 'l01\t200\t200\t9400\t-1\t-1\t-1\t0.0\nl99\t200\t200\t5000\t-1\t-1\t-1\t0.0\n' > "$T/extra.tsv"
      c=$(config extraseeds 'BANDS="9000:10000"' "SEEDS_EXTRA=$T/extra.tsv" "MAXTRY=1")
      FAKE_TRACE_FAIL_META='"mode": "seed"' timeout 600 bash "$WORK/run.sh" "$c" > "$T/extraseeds.log" 2>&1; rc=$?
      B=$T/results/extraseeds.env/band_z09000-10000
      grep -q '^x_l01'$'\t' "$B/seeds_all.tsv" && ! grep -q 'l99' "$B/seeds_all.tsv" \
        && [ "$(grep -l '^x_l01' "$B"/box_*/seeds.tsv | xargs -n 1 dirname | xargs -n 1 basename | tr '\n' ' ')" = "box_00 " ] \
        && ok "the in-band seed point joined the band's seeds (box_00 only), the other did not" \
        || bad "extra seeds: $(grep -h '^x_' "$B/seeds_all.tsv" | cut -f1 | tr '\n' ' ')"
      st=$(cat "$B/box_00/traces/t1/start.txt" 2> /dev/null)
      seed=$("$PY" -I -c "import json, sys; print(*[round(v) for v in json.load(open(sys.argv[1] + '/meta.json'))['seed']])" "$st" 2> /dev/null)
      [ "$rc" = 0 ] && [ "$seed" = "200 200 9400" ] && ok "box_00's first strip started at the patch grown at it" \
        || bad "extra seeds: exit $rc, box_00 start ${st##*/} grown at '$seed'"
      st2=$(cat "$B/box_00/traces/t2/start.txt" 2> /dev/null)
      [ -n "$st2" ] && [ "$st2" != "$st" ] && [ ! -e "$B/box_00/traces/t3" ] && [ ! -e "$B/box_01/traces/t2" ] \
        && ok "the try at the seed point did not use up MAXTRY 1: box_00 got one more (t2), box_01 none" \
        || bad "tries: box_00 t2 '${st2##*/}', t3 $([ -e "$B/box_00/traces/t3" ] && echo exists), box_01 t2 $([ -e "$B/box_01/traces/t2" ] && echo exists)"
      grep -q "SEEDS_EXTRA=$T/extra.tsv" "$T/results/extraseeds.env/machine.txt" && ok "machine.txt records it" || bad "SEEDS_EXTRA not in machine.txt"
      x=$(awk -F'\t' '$1 == "x_l01" {print $2, $3}' "$B/box_00/seeds_extra.ink.tsv" 2> /dev/null)
      [ "$x" = "ink $st" ] && [ -e "$T/results/extraseeds.env/queue/done/band_z09000-10000__box_00__x_l01.job" ] \
        && [ "$(find "$B/box_00/render/x_l01" -maxdepth 1 -name 'rv2_s*.tif' | wc -l)" -ge 11 ] \
        && ok "the stitcher stalled there, so the patch grown at the point was inked itself (x_l01)" \
        || bad "seed patch: '$x' (start ${st##*/}); $(bash "$WORK/inkq.sh" status "$T/results/extraseeds.env")"
      [ "$(find "$B" -name seeds_extra.ink.tsv | wc -l)" = 1 ] \
        && grep -q 'seed points (SEEDS_EXTRA, each counted once): 0 reached by what was inked, 1 inked as their own patch, 0 where' \
          "$T/results/extraseeds.env/summary.txt" && ok "only box_00 lists seed points; the summary counts the inked one" \
        || bad "seed point lists: $(find "$B" -name seeds_extra.ink.tsv | wc -l); $(grep 'seed points' "$T/results/extraseeds.env/summary.txt")"
      # overlapping boxes can both hold a point: one that another box inked counts once and gets no warning; one that
      # no box inked or reached is warned about once, with the boxes that hold it
      printf 'x_l01\tnopatch\t-\nx_l07\tnopatch\t-\n' > "$B/box_01/seeds_extra.ink.tsv"
      "$PY" -I "$WORK/summary.py" "$T/results/extraseeds.env" > "$T/extraseeds.sum2" 2>&1
      grep -q 'seed points (SEEDS_EXTRA, each counted once): 0 reached by what was inked, 1 inked as their own patch, 1 where' \
          "$T/extraseeds.sum2" && grep -q 'WARNING: seed point x_l07: no patch grew there (band_z09000-10000/box_01)$' \
          "$T/extraseeds.sum2" && ! grep -q 'seed point x_l01' "$T/extraseeds.sum2" \
        && ok "a point inked in one box and missed in another counts once, as inked; one missed everywhere is warned about" \
        || bad "dedupe: $(grep 'seed point' "$T/extraseeds.sum2" | tr '\n' ' ')"
      # a strip that reaches the point: the patch is not inked again
      c=$(config extraseeds2 'BANDS="9000:10000"' "SEEDS_EXTRA=$T/extra.tsv")
      FAKE_TRACE_AT_START=1 timeout 600 bash "$WORK/run.sh" "$c" > "$T/extraseeds2.log" 2>&1; rc=$?
      x=$(cut -f1,2 "$T/results/extraseeds2.env/band_z09000-10000/box_00/seeds_extra.ink.tsv" 2> /dev/null | tr '\t' ' ')
      [ "$rc" = 0 ] && [ "$x" = "x_l01 reached" ] && [ -z "$(find "$T/results/extraseeds2.env/queue" -name '*__x_l01.job*')" ] \
        && ok "a strip that reaches the point: its patch is not inked as well" || bad "reached: exit $rc, '$x'"
      ;;
    dryrun)
      c=$(config dryrun)
      out=$( . "$WORK/common.sh"; load_config "$c" && DRYRUN=1 bash "$WORK/band.sh" 9000 10000 2>&1)
      echo "$out" | grep -q 'boxes; growers share' && ok "DRYRUN plans boxes: $(echo "$out" | grep 'boxes; ')" || bad "dryrun: $out"
      ;;
  esac
done
echo "test HOME: $T"
[ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
