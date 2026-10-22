#!/bin/bash
# vast_offline.sh — kit/vast.sh's API commands against a stand-in vast.ai (tests/fake/vast_api.py in place of curl, a
# stand-in ssh that refuses): no account, no network, no rental, seconds. Checks offers (machine ids, EXCLUDE_MACHINES),
# create (the request it sends, IMAGE, the checks on the public key), the start-up script itself (run in a user
# namespace with /root on a test folder, if this machine allows that), status, logs, destroy, balance and the usage text.
# usage: tests/vast_offline.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/vast-test.XXXXXX") || exit 1
export FAKE_VAST_STATE=$T/state HOME=$T/home
mkdir -p "$FAKE_VAST_STATE" "$HOME" "$T/bin"
printf '#!/bin/sh\nexec python3 -I %s "$@"\n' "$R/tests/fake/vast_api.py" > "$T/bin/curl"
printf '#!/bin/sh\necho "stand-in ssh: there is no rented machine in this test" >&2; exit 255\n' > "$T/bin/ssh"
chmod 755 "$T/bin/curl" "$T/bin/ssh"
SYSPATH=$PATH; export PATH=$T/bin:$PATH
export VAST_KEY_FILE=$T/api-key RENTAL_KEY=$T/rental RENTAL_KNOWN_HOSTS=$T/known_hosts
(umask 077; echo test-api-key > "$VAST_KEY_FILE")
ssh-keygen -q -t ed25519 -N '' -C 'test rental (offline) -> nowhere' -f "$RENTAL_KEY"
ssh-keygen -q -t ed25519 -N '' -C 'a key vast.ai put there' -f "$T/other"
V="bash $R/kit/vast.sh"
fails=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
ncalls() { grep -c "${1:-.}" "$FAKE_VAST_STATE/calls.jsonl" 2> /dev/null || true; }
lastcall() {  # URL-REGEX -> the last recorded call to it, as "METHOD AUTH DATA"
  python3 -I -c "
import json, re, sys
hit = [c for c in map(json.loads, open(sys.argv[1])) if re.search(sys.argv[2], c['url'] or '')]
print(*(hit[-1]['method'], hit[-1]['auth'], hit[-1]['data']) if hit else ('none',))" "$FAKE_VAST_STATE/calls.jsonl" "$1"
}

echo "== usage"
out=$($V 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(head -n 1 <<< "$out")" = "# vast.sh — your own machine's handle on a rented vast.ai machine (vast.ai REST API)." ] \
  && grep -q 'vast.sh logs ID' <<< "$out" && grep -q 'EXCLUDE_MACHINES' <<< "$out" && tail -n 1 <<< "$out" | grep -q 'DAEMON_LOGS=1' \
  && ! grep -q '^set ' <<< "$out" && ok "no command: the whole header is printed, and nothing after it" || bad "usage (exit $rc): $out"

echo "== offers"
out=$($V offers 2> "$T/offers.err"); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c . <<< "$out")" = 3 ] && [ "$(grep -c $'\tmachine 111$' <<< "$out")" = 2 ] \
  && grep -q $'^9003\t.*\tmachine 222$' <<< "$out" && ok "3 offers, each line ending with its machine id" || bad "offers (exit $rc): $out"
[ "$(lastcall /bundles/ | cut -d' ' -f2)" = False ] && ok "offers sends no API key" || bad "offers sent the key: $(lastcall /bundles/)"
out=$(EXCLUDE_MACHINES=111 $V offers 2> "$T/offers.err"); rc=$?
[ "$rc" = 0 ] && [ "$(grep -c . <<< "$out")" = 1 ] && grep -q '^9003' <<< "$out" \
  && grep -qx '(2 offers on EXCLUDE_MACHINES left out)' "$T/offers.err" \
  && ok "EXCLUDE_MACHINES=111 leaves out both offers on machine 111, and says so" || bad "exclude (exit $rc): $out $(cat "$T/offers.err")"
out=$(EXCLUDE_MACHINES='111, 222' $V offers 2> "$T/offers.err"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && grep -qx '(3 offers on EXCLUDE_MACHINES left out)' "$T/offers.err" \
  && ok "a list with a space: both machines left out" || bad "exclude list (exit $rc): $out $(cat "$T/offers.err")"
out=$(EXCLUDE_MACHINES='111;x' $V offers 2> "$T/offers.err"); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && grep -q 'EXCLUDE_MACHINES must be machine ids' "$T/offers.err" \
  && ok "a malformed EXCLUDE_MACHINES stops offers (exit $rc)" || bad "malformed exclude (exit $rc): $out"

echo "== create"
id=$($V create 9003 kit-test 400 2> "$T/create.err"); rc=$?
fp=$(ssh-keygen -lf "$RENTAL_KEY.pub" | cut -d' ' -f2)
[ "$rc" = 0 ] && [ "$id" = 4242 ] && ok "create prints only the new id on stdout" || bad "create (exit $rc): '$id' $(cat "$T/create.err")"
grep -q "the machine installs 256 $fp .*(ED25519) itself at start" "$T/create.err" \
  && ok "create names the key it installs (fingerprint, on stderr)" || bad "create stderr: $(cat "$T/create.err")"
[ "$(lastcall /asks/9003/ | cut -d' ' -f1-2)" = "PUT True" ] && ok "create goes to the API with the key" || bad "create call: $(lastcall /asks/)"
B=$FAKE_VAST_STATE/create-9003.json
python3 -I - "$B" "$RENTAL_KEY.pub" "$RENTAL_KEY" << 'EOF' && ok "request: image, disk, runtype, label, and an onstart that starts with k='<the .pub line>'" \
  || bad "request body: $(cat "$B")"
import json, sys
d = json.load(open(sys.argv[1])); pub = open(sys.argv[2]).read().rstrip('\n')
private = ''.join(open(sys.argv[3]).read().split('\n')[1:-2])
want = {'client_id': 'me', 'image': 'vastai/base-image:@vastai-automatic-tag', 'disk': 400, 'runtype': 'ssh_direct',
        'label': 'kit-test'}
o = d.pop('onstart')
assert d == want, d
assert o.startswith(f"k='{pub}'\n"), o[:200]
for s in ('touch /root/.no_auto_tmux', 'chmod go-w /root', 'chown -RH root:root /root/.ssh', 'tee -a /root/kit-onstart.log',
          'grep -qxF -- "$k" "$f"'):
    assert s in o, s
assert private[:40] not in o and 'PRIVATE' not in o
EOF
IMAGE=example/image:tag-2026-10-13 $V create 9001 kit-test 400 > /dev/null 2>&1
python3 -I -c "import json, sys; assert json.load(open(sys.argv[1]))['image'] == 'example/image:tag-2026-10-13'" \
  "$FAKE_VAST_STATE/create-9001.json" && ok "IMAGE replaces the image" || bad "IMAGE: $(cat "$FAKE_VAST_STATE/create-9001.json")"
publine=$(cat "$RENTAL_KEY.pub")
refuse() {  # NAME WHAT: create with RENTAL_KEY=$T/NAME (its .pub made by the caller) must stop before any API call
  local n0 out rc; n0=$(ncalls /asks/)
  out=$(RENTAL_KEY=$T/$1 $V create 9003 kit-test 400 2> "$T/refuse.err"); rc=$?
  [ "$rc" != 0 ] && [ -z "$out" ] && [ -s "$T/refuse.err" ] && [ "$(ncalls /asks/)" = "$n0" ] \
    && ! grep -q 'PRIVATE\|AAAA' "$T/refuse.err" && ok "refused before any API call, the reason on stderr: $2" \
    || bad "not refused ($2): exit $rc, stdout '$out', stderr $(cat "$T/refuse.err")"
}
refuse missing "no .pub file"
printf '%s\n%s\n' "$publine" "$publine" > "$T/twolines.pub"; refuse twolines "two lines"
sed "s/test rental/test 'rental/" "$RENTAL_KEY.pub" > "$T/squote.pub"; refuse squote "a single quote in the comment"
sed 's/test rental/test "rental/' "$RENTAL_KEY.pub" > "$T/dquote.pub"; refuse dquote "a double quote in the comment"
sed $'s/test rental/test\trental/' "$RENTAL_KEY.pub" > "$T/tab.pub"; refuse tab "a tab in the comment"
printf '%s\r\n' "$publine" > "$T/crlf.pub"; refuse crlf "a Windows line end"
cp "$RENTAL_KEY" "$T/private.pub"; refuse private "the private key in the .pub file"
sed 's/^ssh-ed25519/ssh-dss/' "$RENTAL_KEY.pub" > "$T/dss.pub"; refuse dss "a key type outside the list"
echo 'ssh-ed25519 AAAAnotakeyatall comment' > "$T/notakey.pub"; refuse notakey "a line of the right shape that is not a key"
{ printf 'ssh-rsa '; head -c 30000 /dev/zero | tr '\0' 'A'; echo; } > "$T/huge.pub"; refuse huge "a file over 20 kB"

echo "== the start-up script, run as root of a test folder"
if unshare -rm true 2> /dev/null; then
  python3 -I -c "import json, sys; sys.stdout.write(json.load(open(sys.argv[1]))['onstart'])" "$B" > "$T/onstart.sh"
  other=$(cat "$T/other.pub")
  for sh in sh bash; do
    for layout in plain link nopath; do   # nopath: started with an empty PATH
      H=$T/root-$sh-$layout; mkdir -p "$H"; chmod 777 "$H"
      if [ "$layout" = link ]; then   # as vast.ai's base image does when it keeps homes on a volume: .ssh is a link
        mkdir -p "$T/ssh-$sh"; chmod 755 "$T/ssh-$sh"; ln -s "$T/ssh-$sh" "$H/.ssh"; A=$T/ssh-$sh/authorized_keys
      else mkdir -m 755 "$H/.ssh"; A=$H/.ssh/authorized_keys; fi
      printf '%s' "$other" > "$A"; chmod 664 "$A"   # a key already there, its line not ended
      np=; [ "$layout" = nopath ] && np=1
      for boot in 1 2; do
        PATH=$SYSPATH unshare -rm sh -c 'mount --bind "$1" /root && exec ${4:+env PATH=} "$2" "$3"' _ "$H" \
          "$(command -v "$sh")" "$T/onstart.sh" "$np" \
          > "$T/onstart-$sh-$layout-$boot.out" 2>&1
      done
      out=$T/onstart-$sh-$layout-1.out; D=$(dirname "$A")
      [ "$(sed -n 1p "$A")" = "$other" ] && [ "$(sed -n 2p "$A")" = "$publine" ] && [ "$(wc -l < "$A")" = 2 ] \
        && ok "$sh, $layout: the key that was there kept, the rental key added on its own line, once after two boots" \
        || bad "$sh, $layout: authorized_keys: $(cat -A "$A")"
      [ "$(stat -c %a "$D")" = 700 ] && [ "$(stat -c %a "$A")" = 600 ] && [ "$(stat -c %a "$H")" = 755 ] && [ -e "$H/.no_auto_tmux" ] \
        && ok "$sh, $layout: .ssh 700, authorized_keys 600, home no longer group/world-writable, .no_auto_tmux" \
        || bad "$sh, $layout: modes $(stat -c '%n %a' "$D" "$A" "$H")"
      L=$H/kit-onstart.log
      grep -q '^== kit onstart .* UTC: install the rental key' "$out" && grep -q "$fp" "$out" && grep -q '^== kit onstart end ==' "$out" \
        && grep -qE '^(sshd -T exit|strictmodes )' "$out" && [ "$(grep -c '^== kit onstart end ==' "$L")" = 2 ] \
        && ok "$sh, $layout: the report (date, modes, fingerprints, sshd -T) on stdout and in kit-onstart.log, once per boot" \
        || bad "$sh, $layout: report: $(cat "$out")"
      if [ "$layout" = link ]; then
        grep -q "^/root/.ssh is a link to $T/ssh-$sh$" "$out" && grep -q " $T$" "$out" && grep -q ' /$' "$out" \
          && ok "$sh: the report names where the .ssh link goes, and every folder above the real key file" \
          || bad "$sh: link not reported: $(cat "$out")"
      fi
    done
  done
else
  echo "  skip: this machine does not allow user namespaces (unshare -rm), so the script is not run here"
fi

echo "== status"
out=$($V status 4242); rc=$?
[ "$rc" = 0 ] && [ "$(cut -d' ' -f1-3 <<< "$out")" = "4242 running running" ] \
  && grep -q ' machine 111 image vastai/base-image:cuda-13.4.2-auto success, running$' <<< "$out" \
  && ok "status: state first, then the machine id and the image" || bad "status (exit $rc): $out"
out=$($V status 999); rc=$?
[ "$rc" = 1 ] && [ "$out" = "no such instance" ] && ok "status of an unknown id: 'no such instance', exit 1" || bad "status 999 (exit $rc): $out"

echo "== logs"
out=$($V logs 4242 2> "$T/logs.err"); rc=$?
[ "$rc" = 0 ] && grep -qx '== kit onstart 2026-10-22 14:00:00 UTC: install the rental key, report the SSH setup ==' <<< "$out" \
  && grep -qx 'progress 100%' <<< "$out" && grep -qxF '?]0;evil title??[31mred?[0m' <<< "$out" && grep -qx 'nul? c1?2J end' <<< "$out" \
  && ! LC_ALL=C grep -q $'[\x01-\x08\x0b-\x1f\x7f]' <<< "$out" \
  && grep -qxF '(the log as uploaded Thu, 22 Oct 2026 14:00:05 GMT)' "$T/logs.err" \
  && ok "logs prints the machine's log, control characters replaced; its upload time on stderr" \
  || bad "logs (exit $rc): $(cat -A <<< "$out") $(cat "$T/logs.err")"
[ "$(lastcall request_logs/4242/)" = 'PUT True {"tail": "1000"}' ] && ok "log request: PUT with the key, last 1000 lines" \
  || bad "log request: $(lastcall request_logs)"
[ "$(lastcall logs.invalid | cut -d' ' -f1-2)" = "GET False" ] && [ "$(cat "$FAKE_VAST_STATE/log-fetches")" -ge 2 ] \
  && ok "the log link is fetched without the key, again until the log is there" || bad "log fetch: $(lastcall logs.invalid)"
$V logs 4242 50 > /dev/null 2>&1; DAEMON_LOGS=1 $V logs 4242 > /dev/null 2>&1
grep -q '"data": "{\\"tail\\": \\"50\\"}"' "$FAKE_VAST_STATE/calls.jsonl" \
  && [ "$(lastcall request_logs/4242/)" = 'PUT True {"tail": "1000", "daemon_logs": "true"}' ] \
  && ok "LINES and DAEMON_LOGS=1 reach the request" || bad "logs options: $(grep request_logs "$FAKE_VAST_STATE/calls.jsonl")"
n0=$(ncalls); out=$($V logs 4242 ten 2> "$T/logs.err"); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && grep -q 'LINES must be a whole number' "$T/logs.err" && [ "$(ncalls)" = "$n0" ] \
  && ok "LINES that is not a number: refused on stderr, no API call" || bad "logs ten (exit $rc): $out $(cat "$T/logs.err")"
out=$(FAKE_VAST_LOGS_FAIL=1 $V logs 4242 2> "$T/logs.err"); rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && grep -q 'no log from the API: no such instance' "$T/logs.err" \
  && ok "a refused log request: the API's reason on stderr, nothing on stdout, exit $rc" || bad "refused logs (exit $rc): $out"

echo "== destroy, balance"
out=$($V destroy 4242); rc=$?
[ "$rc" = 0 ] && grep -qx 'instance 4242 destroyed' <<< "$out" && ok "destroy confirms the machine is gone" || bad "destroy (exit $rc): $out"
out=$($V balance); grep -q "'credit': 12.34" <<< "$out" && ok "balance" || bad "balance: $out"

echo "== the API key"
! grep -q test-api-key "$FAKE_VAST_STATE/calls.jsonl" && [ "$(stat -c %a "$T/vastai-auth.curl")" = 600 ] \
  && ok "the key went only into the 600 curl config, never into a request's arguments" || bad "the API key leaked into a call"

echo "test folder: $T"
[ "$fails" = 0 ] && { echo "ALL PASSED"; rm -rf "${T:?}"; } || { echo "$fails FAILED"; exit 1; }
