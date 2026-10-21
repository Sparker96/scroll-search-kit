#!/bin/bash
# vast.sh — your own machine's handle on a rented vast.ai machine (vast.ai REST API).
# The API key stays on your machine: $VAST_KEY_FILE (chmod 600), read into a 600 curl config, never printed, never
# copied to the rented machine. SSH uses only a key made for rented machines ($RENTAL_KEY; add its PUBLIC half on your
# vast.ai account's SSH keys page, which vast.ai copies into each new machine), with no agent or X forwarding.
#   vast.sh offers                 cheapest on-demand offers that fit (filters below, set by environment variables)
#   vast.sh create OFFER [LABEL] [DISK_GB]  rent it (vast.ai base image, disk [2000] GB, direct SSH); prints the id
#   vast.sh status ID              state, address, price;   vast.sh wait ID  (until running and SSH answers)
#   vast.sh ssh ID [CMD...]        run a command there (or log in)
#   vast.sh push ID DIR            copy DIR's contents to /root/kit there (tar over SSH)
#   vast.sh pull ID REMOTE LOCAL   copy REMOTE (a folder there) into LOCAL, skipping *.zarr (tar over SSH)
#   vast.sh destroy ID             destroy the machine and its disk (billing stops)
#   vast.sh balance                remaining prepaid credit
# Offer filters (environment): MIN_GPUS [4], MIN_THREADS [96], MIN_DISK GB [2000], MIN_INET Mb/s [1000], MIN_REL
#   reliability [0.99], MIN_CUDA [13.0], MIN_GPU_RAM MB per GPU [12000], GEO regex on the location, e.g. 'US|CA' [any].
set -uo pipefail
API=https://console.vast.ai/api/v0
KEY=${VAST_KEY_FILE:-$HOME/.config/vesuvius/vastai-key}
AUTH=$(dirname "$KEY")/vastai-auth.curl
KNOWN=${RENTAL_KNOWN_HOSTS:-$HOME/.ssh/known_hosts_rental}
SSHKEY=${RENTAL_KEY:-$HOME/.ssh/vesuvius_rental}
need_auth() {
  [ -s "$KEY" ] || { echo "no API key in $KEY"; exit 1; }
  if [ ! -s "$AUTH" ] || [ "$KEY" -nt "$AUTH" ]; then
    (umask 077; printf 'header = "Authorization: Bearer %s"\n' "$(tr -d ' \n\r' < "$KEY")" > "$AUTH")
  fi
}
api() { need_auth; curl -sS -m 60 -K "$AUTH" "$@"; }
inst() {  # ID -> JSON of that instance
  api "${API%/v0}/v1/instances/?owner=me" | python3 -I -c "
import json, sys
d = json.load(sys.stdin); want = int(sys.argv[1])
for i in d.get('instances', []):
    if i.get('id') == want:
        print(json.dumps(i)); break
" "$1"
}
addr() {  # ID -> "IP PORT" for direct SSH (falls back to the proxy)
  inst "$1" | python3 -I -c "
import json, sys
i = json.loads(sys.stdin.read() or '{}')
p = (i.get('ports') or {}).get('22/tcp')
if p and i.get('public_ipaddr'):
    print(i['public_ipaddr'].strip(), p[0]['HostPort'])
elif i.get('ssh_host'):
    print(i['ssh_host'], i['ssh_port'])
"
}
sshto() {  # ID, then ssh arguments
  local id=$1; shift; read -r ip port < <(addr "$id"); [ -n "${ip:-}" ] || { echo "no address yet"; return 1; }
  ssh -i "$SSHKEY" -o IdentitiesOnly=yes -o ForwardAgent=no -o ForwardX11=no -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$KNOWN" -o ServerAliveInterval=30 -o ConnectTimeout=20 -p "$port" "root@$ip" "$@"
}
case "${1:-}" in
  offers)
    q=$(printf '{"verified": {"eq": true}, "rentable": {"eq": true}, "num_gpus": {"gte": %s}, "cpu_cores_effective": {"gte": %s},
        "disk_space": {"gte": %s}, "inet_down": {"gte": %s}, "reliability2": {"gte": %s}, "cuda_max_good": {"gte": %s},
        "gpu_ram": {"gte": %s}, "type": "on-demand", "order": [["dph_total", "asc"]], "limit": 60}' "${MIN_GPUS:-4}" \
        "${MIN_THREADS:-96}" "${MIN_DISK:-2000}" "${MIN_INET:-1000}" "${MIN_REL:-0.99}" "${MIN_CUDA:-13.0}" "${MIN_GPU_RAM:-12000}")
    curl -sS -m 60 -G "$API/bundles/" --data-urlencode "q=$q" | python3 -I -c "
import json, re, sys
geo_re, disk_gb = sys.argv[1], float(sys.argv[2])
for o in json.load(sys.stdin).get('offers', []):
    geo = o.get('geolocation') or ''
    if geo_re and not re.search(geo_re, geo):
        continue
    disk_h = disk_gb * (o.get('storage_cost') or 0) / 730
    print(f\"{o['id']}\t{o['num_gpus']}x {o['gpu_name']}\t\${o['dph_total']:.2f}/h + disk \${disk_h:.2f}/h\t{o.get('cpu_cores_effective'):.0f} thr {(o.get('cpu_name') or '')[:22]}\t\"
          f\"{round((o.get('cpu_ram') or 0) / 1024)} GB RAM\t{round(o.get('disk_space') or 0)} GB disk\t{round(o.get('inet_down') or 0)} Mb/s \${(o.get('inet_down_cost') or 0):.4f}/GB\t\"
          f\"rel {o.get('reliability2', 0):.3f}\t{geo}\")
" "${GEO:-}" "${MIN_DISK:-2000}" ;;
  create)
    offer=${2:?offer id}; label=${3:-scroll-search}; disk=${4:-2000}
    body=$(python3 -I -c "import json, sys; print(json.dumps({'client_id': 'me', 'image': 'vastai/base-image:@vastai-automatic-tag', 'disk': int(sys.argv[2]), 'runtype': 'ssh_direct', 'label': sys.argv[1], 'onstart': 'touch /root/.no_auto_tmux'}))" "$label" "$disk")
    api -X PUT -H 'Content-Type: application/json' -d "$body" "$API/asks/$offer/" | python3 -I -c "
import json, sys
d = json.load(sys.stdin); print(d.get('new_contract') or d)" ;;
  status)
    inst "${2:?id}" | python3 -I -c "
import json, sys
i = json.loads(sys.stdin.read() or '{}')
if not i: print('no such instance'); sys.exit(1)
print(i.get('id'), i.get('actual_status'), i.get('intended_status'), f\"\${(i.get('dph_total') or 0):.2f}/h\", i.get('num_gpus'), i.get('gpu_name'), i.get('public_ipaddr'), (i.get('ports') or {}).get('22/tcp'), i.get('status_msg'))" ;;
  wait)
    id=${2:?id}
    for _ in $(seq 1 90); do
      s=$(inst "$id" | python3 -I -c "import json, sys; i = json.loads(sys.stdin.read() or '{}'); print(i.get('actual_status'))")
      if [ "$s" = running ] && sshto "$id" true 2> /dev/null; then echo "running, SSH answers"; exit 0; fi
      sleep 20
    done
    echo "not ready after 30 min (status $s)"; exit 1 ;;
  ssh) id=${2:?id}; shift 2; sshto "$id" "$@" ;;
  push) id=${2:?id}; dir=${3:?dir}; tar cf - -C "$dir" . | sshto "$id" 'mkdir -p /root/kit && tar xf - -C /root/kit && du -sh /root/kit' ;;
  pull) id=${2:?id}; rem=${3:?remote}; loc=${4:?local}; mkdir -p "$loc"
        sshto "$id" "cd '$rem' && tar cf - --exclude='*.zarr' ." | tar xf - -C "$loc" && du -sh "$loc" ;;
  destroy)
    id=${2:?id}
    api -X DELETE "$API/instances/$id/"; echo
    # billing stops only when the machine is really gone: confirm it, and fail loudly if it is still listed
    for _ in $(seq 1 12); do
      # 0 = not listed any more, 1 = still listed, 2 = the listing could not be read (keep asking)
      api "${API%/v0}/v1/instances/?owner=me" | python3 -I -c "
import json, sys
try:
    d = json.load(sys.stdin)
    ids = [i.get('id') for i in d['instances']]
except Exception:
    sys.exit(2)
sys.exit(1 if int(sys.argv[1]) in ids else 0)" "$id"
      [ $? = 0 ] && { echo "instance $id destroyed"; exit 0; }
      sleep 10
    done
    echo "instance $id is STILL LISTED after 2 min: destroy it in the vast.ai console now (it keeps billing)"; exit 1 ;;
  balance)
    api "$API/users/current/" | python3 -I -c "
import json, sys
d = json.load(sys.stdin); print({k: d.get(k) for k in ('credit', 'balance', 'total_spend') if k in d})" ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
