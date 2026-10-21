#!/bin/bash
# stop.sh RUN — stop a running search cleanly: sends TERM to its run.sh, which stops everything it started (growers,
# renders, ink workers) and ends once none of them is left; interrupted strips go back to the queue when run.sh is
# started again. stop.sh returns when no process of the run is left, so run.sh can start again at once. Processes left
# by a run.sh that died without stopping them (killed with -9, say) it ends itself: TERM, then KILL after 10 s.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
RUN=${1:?usage: stop.sh RUN}
L=$RUN/.run.lock
[ -e "$L" ] || { echo "no run in $RUN (no .run.lock)"; exit 1; }
pid=$(cat "$RUN/run.pid" 2> /dev/null); left=$(holders "$L")
# run.pid's process only if it still holds the run's lock (after a reboot the number may belong to anything)
if [ -n "$pid" ] && grep -qx -- "$pid" <<< "$left"; then
  kill -TERM "$pid" && echo "sent TERM to run.sh ($pid)"
  for _ in $(seq 90); do kill -0 "$pid" 2> /dev/null || break; sleep 1; done
  kill -0 "$pid" 2> /dev/null && { echo "run.sh ($pid) still running after 90 s"; exit 1; }
  left=$(holders "$L")
else
  echo "run.sh (${pid:-?}) is not running"
fi
if [ -n "$left" ]; then
  echo "ending $(wc -w <<< "$left") process(es) left by the run: $(pnames "$left")"
  end_holders "$L" 10 || exit 1
fi
echo "stopped: no process of the run is left"
