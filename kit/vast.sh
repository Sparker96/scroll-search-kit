#!/bin/bash
# vast.sh — your own machine's handle on a rented vast.ai machine (vast.ai REST API).
# The API key stays on your machine: $VAST_KEY_FILE (chmod 600), read into a 600 curl config, never printed, never
# copied to the rented machine. SSH uses only a key made for rented machines ($RENTAL_KEY; add its PUBLIC half on your
# vast.ai account's SSH keys page, which vast.ai copies into each new machine), with no agent or X forwarding.
#   vast.sh offers                 cheapest on-demand offers that fit (filters below, set by environment variables)
#   vast.sh create OFFER [LABEL] [DISK_GB]  rent it (vast.ai base image, disk [2000] GB, direct SSH); prints the id.
#                                  At start the machine also installs $RENTAL_KEY.pub itself (one plain key line, never
#                                  the private key) and reports its SSH setup in /root/kit-onstart.log and in its log
#   vast.sh status ID              state, address, price, machine id, image
#   vast.sh wait ID                until it runs and SSH answers (30 min at most)
#   vast.sh logs ID [LINES]        the machine's log, read through the API (no SSH needed) [last 1000 lines]
#   vast.sh ssh ID [CMD...]        run a command there (or log in)
#   vast.sh push ID DIR            copy DIR's contents to /root/kit there (tar over SSH, no user or group names)
#   vast.sh pull ID REMOTE LOCAL   copy REMOTE (a folder there) into LOCAL, skipping *.zarr (tar over SSH; only plain
#                                  files and folders are written, inside LOCAL)
#   vast.sh destroy ID             destroy the machine and its disk (billing stops)
#   vast.sh balance                remaining prepaid credit
# Offer filters (environment): MIN_GPUS [4], MIN_THREADS [96], MIN_DISK GB [2000], MIN_INET Mb/s [1000], MIN_REL
#   reliability [0.99], MIN_CUDA [13.0], MIN_GPU_RAM MB per GPU [12000], GEO regex on the location, e.g. 'US|CA' [any],
#   EXCLUDE_MACHINES machine ids to leave out, e.g. '12345,67890' [none].
# Other settings: IMAGE for create [vastai/base-image:@vastai-automatic-tag, the build vast.ai picks for the machine's
#   driver], e.g. a dated build of that image; DAEMON_LOGS=1 makes logs show vast.ai's own log of the machine instead.
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
onstart_body() {  # what the machine runs at each start; create puts k='<the public key line>' in front of it
  cat << 'EOF'
set +e; PATH=${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin; f=/root/.ssh/authorized_keys
{ echo "== kit onstart $(date -u '+%Y-%m-%d %H:%M:%S') UTC: install the rental key, report the SSH setup =="
  mkdir -p /root/.ssh; chmod 700 /root/.ssh
  if ! grep -qxF -- "$k" "$f" 2> /dev/null; then
    if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then echo >> "$f"; fi
    printf '%s\n' "$k" >> "$f"
  fi
  chmod 600 "$f"; chown -RH root:root /root/.ssh; chmod go-w /root
  touch /root/.no_auto_tmux
  ls -ld /root /root/.ssh "$f"
  for p in /root /root/.ssh "$f"; do [ -L "$p" ] && echo "$p is a link to $(readlink -f "$p")" && ls -ldL "$p"; done
  d=$(readlink -f "$f"); while [ -n "$d" ] && [ "$d" != / ]; do d=$(dirname "$d"); ls -ld "$d"; done   # sshd checks these
  ssh-keygen -lf "$f"
  echo "root's home: $(getent passwd root | cut -d: -f6)"; ssh -V
  o=$(sshd -T 2>&1); r=$?
  printf '%s\n' "$o" | grep -iE '^(strictmodes|authorizedkeysfile|pubkeyauthentication|permitrootlogin|authorizedkeyscommand|authenticationmethods|allowusers|denyusers|allowgroups|denygroups|pubkeyacceptedalgorithms) '
  [ "$r" = 0 ] || { echo "sshd -T exit $r:"; printf '%s\n' "$o" | head -n 5; }
  echo "== kit onstart end =="
} 2>&1 | tee -a /root/kit-onstart.log
EOF
}
case "${1:-}" in
  offers)
    q=$(printf '{"verified": {"eq": true}, "rentable": {"eq": true}, "num_gpus": {"gte": %s}, "cpu_cores_effective": {"gte": %s},
        "disk_space": {"gte": %s}, "inet_down": {"gte": %s}, "reliability2": {"gte": %s}, "cuda_max_good": {"gte": %s},
        "gpu_ram": {"gte": %s}, "type": "on-demand", "order": [["dph_total", "asc"]], "limit": 60}' "${MIN_GPUS:-4}" \
        "${MIN_THREADS:-96}" "${MIN_DISK:-2000}" "${MIN_INET:-1000}" "${MIN_REL:-0.99}" "${MIN_CUDA:-13.0}" "${MIN_GPU_RAM:-12000}")
    curl -sS -m 60 -G "$API/bundles/" --data-urlencode "q=$q" | python3 -I -c "
import json, re, sys
geo_re, disk_gb, exclude = sys.argv[1], float(sys.argv[2]), sys.argv[3]
try:
    skip = {str(int(m)) for m in exclude.replace(' ', '').split(',') if m}
except ValueError:
    sys.exit(f'EXCLUDE_MACHINES must be machine ids separated by commas, e.g. 12345,67890 (it is {exclude})')
left_out = 0
for o in json.load(sys.stdin).get('offers', []):
    geo = o.get('geolocation') or ''
    if geo_re and not re.search(geo_re, geo):
        continue
    if str(o.get('machine_id')) in skip:
        left_out += 1; continue
    disk_h = disk_gb * (o.get('storage_cost') or 0) / 730
    print(f\"{o['id']}\t{o['num_gpus']}x {o['gpu_name']}\t\${o['dph_total']:.2f}/h + disk \${disk_h:.2f}/h\t{o.get('cpu_cores_effective'):.0f} thr {(o.get('cpu_name') or '')[:22]}\t\"
          f\"{round((o.get('cpu_ram') or 0) / 1024)} GB RAM\t{round(o.get('disk_space') or 0)} GB disk\t{round(o.get('inet_down') or 0)} Mb/s \${(o.get('inet_down_cost') or 0):.4f}/GB\t\"
          f\"rel {o.get('reliability2', 0):.3f}\t{geo}\tmachine {o.get('machine_id')}\")
if left_out:
    print(f'({left_out} offers on EXCLUDE_MACHINES left out)', file=sys.stderr)
" "${GEO:-}" "${MIN_DISK:-2000}" "${EXCLUDE_MACHINES:-}" ;;
  create)
    offer=${2:?offer id}; label=${3:-scroll-search}; disk=${4:-2000}; pub=$SSHKEY.pub
    # the machine installs the rental key's PUBLIC half itself, in case vast.ai's copy of it does not arrive. Only a file
    # holding exactly one plain key line goes into the start-up script: no quotes, so the line cannot break out of k='...'
    body=$(python3 -I - "$label" "$disk" "$pub" "${IMAGE:-vastai/base-image:@vastai-automatic-tag}" "$(onstart_body)" << 'EOF'
import json, re, sys
label, disk, pub, image, onstart = sys.argv[1:6]
try:
    with open(pub, 'rb') as f:
        raw = f.read(20001)
except OSError as e:
    sys.exit(f'cannot read {pub} ({e.strerror}): make the key as in RENTING, or set RENTAL_KEY')
line = raw[:-1] if raw.endswith(b'\n') else raw
if not (len(raw) <= 20000 and all(32 <= c < 127 for c in line) and re.fullmatch(
        r"(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+( [^'\"]*)?", line.decode())):
    sys.exit(f'{pub} must hold exactly one public key line (ssh-ed25519, ecdsa-sha2-nistp256 or ssh-rsa; plain ASCII, '
             'no quotes in its comment): refusing')
print(json.dumps({'client_id': 'me', 'image': image, 'disk': int(disk), 'runtype': 'ssh_direct', 'label': label,
                  'onstart': f"k='{line.decode()}'\n{onstart}\n"}))
EOF
) || exit 1
    fp=$(ssh-keygen -lf "$pub" < /dev/null 2> /dev/null) || { echo "$pub is not a public key ssh-keygen can read: refusing" >&2; exit 1; }
    echo "the machine installs $fp itself at start" >&2
    api -X PUT -H 'Content-Type: application/json' -d "$body" "$API/asks/$offer/" | python3 -I -c "
import json, sys
d = json.load(sys.stdin); print(d.get('new_contract') or d)" ;;
  status)
    inst "${2:?id}" | python3 -I -c "
import json, sys
i = json.loads(sys.stdin.read() or '{}')
if not i: print('no such instance'); sys.exit(1)
print(i.get('id'), i.get('actual_status'), i.get('intended_status'), f\"\${(i.get('dph_total') or 0):.2f}/h\", i.get('num_gpus'), i.get('gpu_name'), i.get('public_ipaddr'), (i.get('ports') or {}).get('22/tcp'),
      f\"machine {i.get('machine_id')}\", f\"image {i.get('image_uuid') or i.get('image')}\", i.get('status_msg'))" ;;
  wait)
    id=${2:?id}
    for _ in $(seq 1 90); do
      s=$(inst "$id" | python3 -I -c "import json, sys; i = json.loads(sys.stdin.read() or '{}'); print(i.get('actual_status'))")
      if [ "$s" = running ] && sshto "$id" true 2> /dev/null; then echo "running, SSH answers"; exit 0; fi
      sleep 20
    done
    echo "not ready after 30 min (status $s)"; exit 1 ;;
  logs)
    id=${2:?id}; n=${3:-1000}
    case $n in ''|*[!0-9]*) echo "LINES must be a whole number" >&2; exit 1 ;; esac
    body=$(python3 -I -c "import json, sys; print(json.dumps({'tail': sys.argv[1], **({'daemon_logs': 'true'} if sys.argv[2] == '1' else {})}))" "$n" "${DAEMON_LOGS:-0}")
    # the API answers with a link to the log; the link needs no key, so the key is not sent with it
    url=$(api -X PUT -H 'Content-Type: application/json' -d "$body" "$API/instances/request_logs/$id/" | python3 -I -c "
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit('the API did not answer with JSON')
if not isinstance(d, dict):
    d = {'msg': d}
u = d.get('result_url') or ''
if not u.startswith('https://'):
    sys.exit(f\"no log from the API: {d.get('msg') or d.get('error') or d}\")
print(u)") || exit 1
    t=$(mktemp) || exit 1; trap 'rm -f "$t" "$t.h"' EXIT
    end=$((SECONDS + 120))
    while [ "$SECONDS" -lt "$end" ]; do   # the log takes a few seconds to appear behind the link
      sleep 2
      if curl -sf --connect-timeout 10 -m 30 -L --proto =https --proto-redir =https -D "$t.h" -o "$t" "$url"; then
        # the link may stay the same for a machine: its upload time tells an old log from the one just asked for
        lm=$(sed -n 's/^[Ll]ast-[Mm]odified: *\([A-Za-z0-9 ,:]*\).*/\1/p' "$t.h" | tail -n 1)
        echo "(the log as uploaded ${lm:-at an unknown time})" >&2
        # written on the rented machine: control characters (terminal escapes) are replaced before printing
        python3 -I -c "
import re, sys
s = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace').replace('\r\n', '\n').replace('\r', '\n')
s = re.sub(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]', '?', s)
sys.stdout.write(s if s.endswith('\n') or not s else s + '\n')" "$t"; exit $?
      fi
    done
    echo "the log was not ready after 2 minutes: run logs again" >&2; exit 1 ;;
  ssh) id=${2:?id}; shift 2; sshto "$id" "$@" ;;
  push) id=${2:?id}; dir=${3:?dir}; tar cf - --numeric-owner -C "$dir" . | sshto "$id" 'mkdir -p /root/kit && tar xf - -C /root/kit && du -sh /root/kit' ;;
  pull) id=${2:?id}; rem=${3:?remote}; loc=${4:?local}; mkdir -p "$loc"
        # what comes back is untrusted: only plain files and folders are written, never outside LOCAL and never through a
        # link (python, not tar, so this holds whatever tar your machine has); anything else is skipped and named
        sshto "$id" "cd '$rem' && tar cf - --exclude='*.zarr' ." | python3 -I -c "
import os, shutil, sys, tarfile
dest = os.path.realpath(sys.argv[1]); skipped = []; nfile = 0
def inside(p):
    return p == dest or p.startswith(dest + os.sep)
with tarfile.open(fileobj=sys.stdin.buffer, mode='r|') as t:
    for m in t:
        name = os.path.normpath(m.name.lstrip('/'))
        target = os.path.join(dest, name)
        if (name == '..' or name.startswith('..' + os.sep) or not (m.isfile() or m.isdir())
                or not inside(os.path.realpath(target if m.isdir() else os.path.dirname(target)))):
            skipped.append(m.name); continue
        if m.isdir():
            os.makedirs(target, exist_ok=True); continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.islink(target) or (os.path.lexists(target) and not os.path.isfile(target) and not os.path.isdir(target)):
            os.unlink(target)   # a link or special file already there is replaced, never written through
        if os.path.isdir(target):
            skipped.append(m.name); continue
        with t.extractfile(m) as src, open(target, 'wb') as out:
            shutil.copyfileobj(src, out, 1 << 20)
        os.utime(target, (m.mtime, m.mtime)); nfile += 1
print(nfile, 'files')
if skipped:
    print(f'WARNING: skipped {len(skipped)} entries that were not plain files or folders, or pointed outside {dest}:',
          ', '.join(skipped[:10]))
    sys.exit(1)
" "$loc" && du -sh "$loc" ;;
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
  *) sed -n '2,23p' "$0"; exit 1 ;;
esac
