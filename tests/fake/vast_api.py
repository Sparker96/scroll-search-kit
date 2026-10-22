#!/usr/bin/env python3
"""Stand-in for curl in tests/vast_offline.sh: answers the vast.ai API calls that kit/vast.sh makes from canned data and
records each call (method, URL, whether the curl config with the API key was passed, the data sent) in
$FAKE_VAST_STATE/calls.jsonl. Switches: FAKE_VAST_LOGS_FAIL=1 (the log request is refused), FAKE_VAST_LOG_READY=N (the
log link answers from its Nth fetch on, default 2)."""
import json
import os
import re
import sys

STATE = os.environ['FAKE_VAST_STATE']
API = 'https://console.vast.ai/api'
LOG_URL = 'https://logs.invalid/instance_logs/0123abcd.log'
INSTANCE = {'id': 4242, 'machine_id': 111, 'actual_status': 'running', 'intended_status': 'running',
            'dph_total': 1.23, 'num_gpus': 4, 'gpu_name': 'RTX 4070S Ti', 'public_ipaddr': '203.0.113.7',
            'ports': {'22/tcp': [{'HostIp': '0.0.0.0', 'HostPort': '40022'}]},
            'image_uuid': 'vastai/base-image:cuda-13.4.2-auto', 'status_msg': 'success, running'}
OFFERS = [{'id': 9001, 'machine_id': 111, 'num_gpus': 4, 'gpu_name': 'RTX 4070S Ti', 'dph_total': 1.11,
           'storage_cost': 0.1, 'cpu_cores_effective': 48, 'cpu_name': 'Example CPU 48', 'cpu_ram': 131072,
           'disk_space': 1000, 'inet_down': 1000, 'inet_down_cost': 0.01, 'reliability2': 0.99,
           'geolocation': 'Region A, US'},
          {'id': 9002, 'machine_id': 111, 'num_gpus': 2, 'gpu_name': 'RTX 4070S Ti', 'dph_total': 0.56,
           'storage_cost': 0.1, 'cpu_cores_effective': 24, 'cpu_name': 'Example CPU 48', 'cpu_ram': 64400,
           'disk_space': 500, 'inet_down': 1000, 'inet_down_cost': 0.01, 'reliability2': 0.99,
           'geolocation': 'Region A, US'},
          {'id': 9003, 'machine_id': 222, 'num_gpus': 4, 'gpu_name': 'RTX 3090', 'dph_total': 1.22,
           'storage_cost': 0.1, 'cpu_cores_effective': 96, 'cpu_name': 'Example CPU 96', 'cpu_ram': 262144,
           'disk_space': 2000, 'inet_down': 1000, 'inet_down_cost': 0.01, 'reliability2': 0.99,
           'geolocation': 'Region B, CA'}]
# what the machine's log holds: the kit's onstart report, plus what a hostile machine could add (terminal escapes, a
# carriage return, a NUL, a C1 control character)
LOG = ('== kit onstart 2026-10-22 14:00:00 UTC: install the rental key, report the SSH setup ==\r\n'
       'strictmodes yes\n\x1b]0;evil title\x07\x1b[31mred\x1b[0m\nprogress 10%\rprogress 100%\nnul\x00 c1\u009b2J end\n')


def answer(obj):
    sys.stdout.write(json.dumps(obj))


def main():
    args = sys.argv[1:]
    method, data, out, heads, url, auth, i = 'GET', None, None, None, None, False, 0
    while i < len(args):
        a = args[i]
        if a == '-X':
            method = args[i + 1]
        elif a in ('-d', '--data-urlencode'):
            data = args[i + 1]
        elif a == '-K':
            auth = True
        elif a == '-o':
            out = args[i + 1]
        elif a == '-D':
            heads = args[i + 1]
        elif a in ('-m', '-H', '--proto', '--proto-redir', '--connect-timeout'):
            pass
        else:
            if re.match(r'https?://', a):
                url = a
            i += 1
            continue
        i += 2
    with open(os.path.join(STATE, 'calls.jsonl'), 'a') as f:
        f.write(json.dumps({'method': method, 'url': url, 'auth': auth, 'data': data, 'argv': args}) + '\n')
    gone = os.path.exists(os.path.join(STATE, 'destroyed'))
    if url == f'{API}/v0/bundles/' and method == 'GET':
        answer({'offers': OFFERS})
    elif m := re.fullmatch(rf'{API}/v0/asks/(\d+)/', url or ''):
        with open(os.path.join(STATE, f'create-{m[1]}.json'), 'w') as f:
            f.write(data or '')
        answer({'success': True, 'new_contract': 4242})
    elif url == f'{API}/v1/instances/?owner=me':
        answer({'instances': [] if gone else [INSTANCE]})
    elif m := re.fullmatch(rf'{API}/v0/instances/request_logs/(\d+)/', url or ''):
        if os.environ.get('FAKE_VAST_LOGS_FAIL') == '1':
            answer({'success': False, 'msg': 'no such instance'})
        else:
            answer({'success': True, 'result_url': LOG_URL})
    elif url == LOG_URL:
        n_file = os.path.join(STATE, 'log-fetches')
        n = int(open(n_file).read()) + 1 if os.path.exists(n_file) else 1
        open(n_file, 'w').write(str(n))
        if n < int(os.environ.get('FAKE_VAST_LOG_READY', '2')):
            sys.exit(22)   # what curl -f does on HTTP 404 (the log is not there yet)
        if heads:
            with open(heads, 'w') as f:
                f.write('HTTP/1.1 200 OK\r\nLast-Modified: Thu, 22 Oct 2026 14:00:05 GMT\r\n\r\n')
        with open(out, 'wb') if out else sys.stdout.buffer as f:
            f.write(LOG.encode())
    elif re.fullmatch(rf'{API}/v0/instances/\d+/', url or '') and method == 'DELETE':
        open(os.path.join(STATE, 'destroyed'), 'w').close()
        answer({'success': True})
    elif url == f'{API}/v0/users/current/':
        answer({'credit': 12.34, 'balance': 0, 'total_spend': 56.78})
    else:
        sys.stderr.write(f'fake vast API: unexpected call {method} {url}\n')
        sys.exit(7)


main()
