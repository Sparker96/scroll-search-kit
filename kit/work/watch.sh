#!/bin/bash
# watch.sh RUN [STALL_MIN] — read-only health check of a search in progress. Prints one status line and an ALERT line
# for anything that needs attention, and exits 1 if there is any: a box still growing or stitching whose files have not
# changed for STALL_MIN minutes [45]; a strip being rendered or inked with no change for STALL_MIN; failed or blank
# strips; strips waiting with no ink worker alive; free disk below MIN_FREE_GB. Run it every few minutes from your own machine, e.g.
#   vast.sh ssh ID 'bash ~/work/watch.sh ~/results/<run>'
set -uo pipefail
RUN=${1:?usage: watch.sh RUN [STALL_MIN]}; STALL=${2:-45}
RUN=$(cd "$RUN" && pwd) || exit 2
now=$(date +%s); n_alert=0
alert() { echo "ALERT $*"; n_alert=$((n_alert + 1)); }
newest() { find "$@" -maxdepth 4 -printf '%T@\n' 2> /dev/null | sort -n | tail -n 1 | cut -d. -f1; }
age_min() { local m; m=$(newest "$@"); [ -n "$m" ] && echo $(( (now - m) / 60 )) || echo 0; }
min_free=$(sed -n 's/^MIN_FREE_GB=\([0-9]*\).*/\1/p' "$(cat "$RUN/config.path" 2> /dev/null)" 2> /dev/null | tail -n 1)
min_free=${min_free:-50}
grown=0; nband=0; active=0; stitched=0
for band in "$RUN"/band_z*; do
  [ -d "$band" ] || continue
  nband=$((nband + 1)); [ -e "$band/.grown" ] && grown=$((grown + 1))
  for b in "$band"/box_*; do
    [ -s "$b/seeds.tsv" ] || continue
    [ -e "$b/.failed" ] && alert "BOX FAILED ${b#"$RUN"/}: $(cat "$b/.failed") (run.sh tries the band again)"
    if [ -e "$b/.stitched" ]; then stitched=$((stitched + 1)); continue; fi
    [ -e "$b/run.log" ] || continue
    active=$((active + 1))
    a=$(age_min "$b/logs" "$b/patches" "$b/traces" "$b/run.log")
    [ "$a" -ge "$STALL" ] && alert "STALL ${b#"$RUN"/}: no change for $a min ($(grep 'PROGRESS' "$b/run.log" | tail -n 1))"
  done
done
for f in "$RUN"/queue/running/*.job.w*; do
  [ -e "$f" ] || continue
  boxdir=$(sed -n 's/^BOXDIR=//p' "$f"); k=$(sed -n 's/^K=//p' "$f")
  a=$(age_min "$boxdir/render/$k")
  [ "$a" -ge "$STALL" ] && alert "STALL ink ${f##*/}: no change for $a min"
done
cnt() { local n=0 f; for f in "$RUN/queue/$1"/*.job*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
nfail=$(cnt failed); nblank=$(cnt blank); npend=$(cnt pending); nrun=$(cnt running)
[ "$nfail" -gt 0 ] && alert "FAILED $nfail strips (see $RUN/queue/failed and $RUN/ink.tsv)"
[ "$nblank" -gt 0 ] && alert "BLANK $nblank strips rendered empty twice (queue/blank; inkq.sh retry RUN blank)"
# strips waiting but nobody inking them: the ink workers have stopped
if [ "$npend" -gt 0 ] && [ "$nrun" = 0 ] && ! pgrep -f "inkq.sh workers $RUN" > /dev/null; then
  alert "NO INK WORKERS: $npend strips pending and no worker running (see $RUN/ink.log, $RUN/alerts.log)"
fi
[ -e "$RUN/queue/.stop" ] && alert "STOPPED: the ink workers stopped themselves (queue/.stop; see $RUN/alerts.log)"
free=$(df -P -BG "$RUN" | awk 'NR == 2 {sub("G", "", $4); print $4}')
[ "${free:-0}" -lt "$min_free" ] && alert "DISK $free GB free (< $min_free)"
# is the run itself alive and writing?
state=$(cut -d' ' -f1 "$RUN/state" 2> /dev/null)
if [ "$state" = running ]; then
  pid=$(cat "$RUN/run.pid" 2> /dev/null)
  { [ -n "$pid" ] && kill -0 "$pid" 2> /dev/null; } || alert "RUN.SH NOT RUNNING although the run is not finished (pid ${pid:-?}): stop.sh RUN ends what it left running, then restart it"
  m=$(age_min "$RUN/metrics.tsv"); [ "$m" -ge 10 ] && alert "METRICS STALE: no metrics line for $m min"
  nw=$(cat "$RUN/queue/.nworkers" 2> /dev/null || echo 0); live=0
  for hb in "$RUN"/queue/.hb.w*; do [ -e "$hb" ] || continue; [ "$(age_min "$hb")" -lt "$STALL" ] && live=$((live + 1)); done
  if [ "$nw" -gt 0 ] && [ "$live" -lt "$nw" ] && [ -n "$(ls "$RUN"/queue/.hb.w* 2> /dev/null)" ]; then
    alert "INK WORKERS: $live of $nw have a recent heartbeat"
  fi
  [ -e "$RUN/queue/.net-down" ] && alert "NETWORK: the scan was unreachable (queue/.net-down); workers are waiting"
fi
q=$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/inkq.sh" status "$RUN" 2> /dev/null)
echo "$(date '+%F %T') ${state:-?}: bands grown $grown/$nband, boxes stitched $stitched (active $active), queue: $q, disk ${free} GB free"
[ "$n_alert" = 0 ]
