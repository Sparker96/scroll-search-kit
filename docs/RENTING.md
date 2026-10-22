# Renting a machine and running a search, step by step

DRAFT 2026-10-20. Commands are run on **your own computer** unless the line says `vast.sh ssh ID '...'`, which runs
on the rented machine. Prices change by the hour; check before you rent.

## Before the first rental (once)

1. **vast.ai account with prepaid credit.** Buy a small amount of credit and leave automatic top-up off: the credit
   is then a hard spending cap (machines stop when it runs out). Check vast.ai's current 2FA / API-key behaviour.
2. **API key.** Create one in the vast.ai console and save it in a file only you can read:
   `install -D -m 600 /dev/stdin ~/.config/vesuvius/vastai-key` (paste, then Ctrl-D), or set `VAST_KEY_FILE`.
   The key never goes to the rented machine.
3. **SSH key for rented machines only.** `ssh-keygen -t ed25519 -C rented-machines -f ~/.ssh/vesuvius_rental` (or set
   `RENTAL_KEY`). `-C` sets the comment that travels with the public half (by default your user and computer name).
   Add the **public** half (`.pub`) on your vast.ai account's SSH keys page; vast.ai copies it into every new machine.
   `vast.sh` connects with this key only, with agent and X11 forwarding off. `vast.sh create` also has the machine add
   this public half itself when it starts, in case vast.ai's copy does not arrive, and report its SSH setup (see "The
   machine refuses the SSH key" below). It refuses a `.pub` file that is not exactly one plain key line: no quotes in
   the comment.
4. **Build the kit folder:** `kit/make_kit.sh build/kit` (downloads the pinned VC3D build and the control data from
   this repository's release, checks their checksums, and refuses to build if anything looks like a secret).
5. **Write a config** for your scroll: copy `kit/config/TEMPLATE.env` into `build/kit/config/`. Start with the
   control (`control-0343.env`) to see the kit work on a scroll with known letters.

## A run

```bash
kit/vast.sh offers                          # cheapest fitting machines; filters: MIN_GPUS, MIN_THREADS, GEO, ...
kit/vast.sh create OFFER my-search 2000     # rent it with a 2000 GB disk; prints the instance ID
kit/vast.sh wait ID                         # until it runs and SSH answers (~1-3 min; not in 5 min: see below)
kit/vast.sh push ID build/kit               # copies the kit to /root/kit
kit/vast.sh ssh ID 'bash /root/kit/setup.sh /root/kit/config/my-scroll.env'      # ~1-5 min
kit/vast.sh ssh ID 'setsid nohup bash /root/work/run.sh /root/kit/config/my-scroll.env > /root/run.log 2>&1 < /dev/null &'
```

`offers` ends each line with the machine's id: `EXCLUDE_MACHINES=12345,67890 kit/vast.sh offers` leaves machines out,
for example one that refused your key. `create` rents vast.ai's base image in the build vast.ai picks for the machine's
driver; `IMAGE=...` rents another image or build instead. `kit/vast.sh status ID` shows the machine id and the image.

`run.sh` first runs the same-answer check with the config's ink model and batch size, and stops if it fails (see
`results/<run>/check/check.tsv`) or if the control has no reference maps made by that model (the kit's control has
Reader V3 and Reader v2; for another model, `CHECK=0` runs without the check).

**While it runs** (every few minutes; it only reads):

```bash
kit/vast.sh ssh ID 'bash /root/work/watch.sh /root/results/my-scroll'     # status line + ALERT lines
kit/vast.sh ssh ID 'tail -n 5 /root/run.log'
kit/vast.sh ssh ID 'cat /root/results/my-scroll/metrics.tsv' > metrics.tsv
python3 kit/usage.py metrics.tsv --threads 128 --usd-per-hour 3.13        # CPU/GPU busy and cost so far
```

**At the end:**

```bash
kit/vast.sh pull ID /root/results/my-scroll results/my-scroll   # maps, surfaces, logs; skips the 3D volumes
kit/vast.sh destroy ID      # billing stops only when the machine is DESTROYED (a stopped one still bills its disk)
kit/vast.sh balance
```

A pull treats what comes back as untrusted. It writes only plain files and folders, and only inside the local folder.
Links, device files and names that point outside it are skipped and named; the pull then ends with exit 1.

## If something goes wrong

- **The machine refuses the SSH key** (`kit/vast.sh ssh ID true` says `Permission denied (publickey)`): `vast.sh wait`
  keeps trying for up to 30 minutes without saying why, so watch the clock instead. If SSH does not answer 5 minutes
  after `kit/vast.sh status ID` first says `running`, stop `wait` (Ctrl-C) and keep the machine's log:
  `kit/vast.sh logs ID > refused.log`. It is read through the API, so no SSH is needed. If vast.ai passes the start-up
  script's output to the log, the kit's report in it shows the key file, its permissions and the SSH server's
  settings. Then destroy the machine (`kit/vast.sh destroy ID`). Detaching and re-attaching the key or rebooting the
  machine did not help when this happened to us, and only adds billed time. Rent another machine, with its machine id
  in `EXCLUDE_MACHINES`.
- **Stopped or interrupted run:** start the same `run.sh` command again; it continues where it stopped.
  `bash /root/work/stop.sh /root/results/my-scroll` returns only when nothing of the run is left (a tool that ignores
  TERM, as the stitcher can, gets KILL after 10 s), so `run.sh` can start right after it. A `run.sh` started while a
  stopped run's tools are still ending waits up to 2 minutes for them; one started next to a running `run.sh` is
  refused at once. If `run.sh` itself was killed (`kill -9`, out of memory), what it started keeps running without it:
  `stop.sh` ends those processes too.
- **Blank strips** (`queue/blank/`): renders with no papyrus in them. `bash /root/work/inkq.sh retry
  /root/results/my-scroll blank` queues them for a fresh render, while the run is going or before a restart.
- **Failed strips** (`queue/failed/`, reason in the file and in `ink.tsv`): fix the cause, then `... retry ... failed`.
- **Strips outside the scan's mask** (`queue/outside/`) are never rendered: the masked scan holds no data there. If a
  network fault may have caused it, `bash /root/work/inkq.sh retry /root/results/my-scroll outside` checks them again.
- **Never edit the kit's scripts while a run uses them**: bash reads a script as it runs, so the running copy can break.
  Stop the run (`bash /root/work/stop.sh /root/results/my-scroll`), change what you need, start it again: it resumes.
- **Low disk:** below `MIN_FREE_GB` the ink workers wait (and `alerts.log` says so); after `DISK_WAITS` waits they
  stop and `run.sh` ends with an error, strips kept in the queue. The VC3D download cache (`~/.VC3D/remote_cache`)
  has no size limit: size the disk for the scan data you will read. `CACHE_EVICT=1` lets the kit delete old cache
  files instead; it deletes files on the machine, so turn it on only if you mean to.
- **NOTHING SEARCHED (exit 6)**: no strip was big enough to keep. `alerts.log` and the summary say why for each box;
  usually too few grower slots (a warning at the start) or too little growth time for a thin patch cloud.
- **Ink workers stopped** (`watch.sh` says NO INK WORKERS or STOPPED): a GPU whose ink step keeps failing stops its
  worker after `GPU_FAIL_MAX` failures in a row; the worker starts again after `WORKER_PAUSE` × n seconds, at most
  `WORKER_RESTARTS` times (a worker that died is restarted the same way, its strip put back in the queue). If every
  worker stays stopped, `run.sh` stops the run. Restart it to continue.
