#!/bin/bash
# metrics.sh RUN — one line a minute into RUN/metrics.tsv until RUN/.stop-metrics exists (run.sh starts and stops it):
# epoch, VC3D download cache (KB), load averages, memory used/total (GB), per GPU "utilisation %, MiB used;", free disk
# (GB). usage.py turns it into CPU/GPU busy time and cost. The cache is measured every 10th line (du walks every file of
# a cache that can hold millions; at most 2 minutes), the lines between repeat the last value.
RUN=${1:?RUN}
i=0 cache=
while [ ! -e "$RUN/.stop-metrics" ]; do
  if [ $(( i % 10 )) = 0 ]; then cache=$(timeout 120 du -sk "$HOME/.VC3D/remote_cache" 2> /dev/null | cut -f1); fi
  i=$((i + 1))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$cache" \
    "$(cut -d' ' -f1-3 /proc/loadavg)" "$(free -g | awk '/Mem:/ {print $3 "/" $2}')" \
    "$(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2> /dev/null | tr '\n' ';')" \
    "$(df -P -BG "$RUN" | awk 'NR == 2 {sub("G", "", $4); print $4}')" >> "$RUN/metrics.tsv"
  for _ in $(seq 12); do [ -e "$RUN/.stop-metrics" ] && break; sleep 5; done
done
