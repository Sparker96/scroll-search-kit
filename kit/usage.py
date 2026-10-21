#!/usr/bin/env python3
"""How much of the rented machine is a run using? Reads metrics.sh's metrics.tsv (one line a minute: epoch,
download cache KB, load averages, memory used/total GB, per-GPU "util, MiB;" list, free disk GB) and prints 10-minute
blocks: CPU busy (1-min load / threads), GPU busy (mean utilisation over all GPUs), memory, scan downloaded, and cost.
Each line counts for the time until the next one (gaps over 10 minutes count as 10), so late lines do not skew it.

usage: usage.py METRICS_TSV --threads N --usd-per-hour P [--start EPOCH] [--block 10]
  N = the machine's CPU threads (nproc); P = everything billed per hour (machine + disk).
"""
import argparse
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tsv")
    ap.add_argument("--threads", type=int, required=True, help="CPU threads of the machine (nproc)")
    ap.add_argument("--usd-per-hour", type=float, required=True, help="machine + disk price per hour")
    ap.add_argument("--start", type=float, help="when billing began (epoch); default = first metrics line")
    ap.add_argument("--block", type=int, default=10, help="minutes per row")
    a = ap.parse_args()
    rows = []
    for line in open(a.tsv):
        f = line.rstrip("\n").split("\t")
        if len(f) < 5:
            continue
        try:
            t = float(f[0])
            cache_gb = float(f[1]) / 1048576 if f[1] else 0.0
            load1 = float(f[2].split()[0])
            mem_used = float(f[3].split("/")[0])
            gpus = [g.split(",") for g in f[4].split(";") if g.strip()]
            util = [float(g[0]) for g in gpus]
            gmem = [float(g[1]) for g in gpus]
        except (ValueError, IndexError):
            continue
        rows.append((t, cache_gb, load1, mem_used, util, gmem))
    if not rows:
        print("no metrics yet")
        return
    t0 = a.start or rows[0][0]
    # each line stands for the time until the next one (capped at 10 min; the last one: 1 min)
    dt = [min(max(rows[i + 1][0] - rows[i][0], 0.0), 600.0) for i in range(len(rows) - 1)] + [60.0]

    def gpu_mean(r):
        return sum(r[4]) / len(r[4]) if r[4] else 0.0
    print(f"{'from':>5} {'min':>4}  {'CPU busy':>8}  {'GPU busy':>8}  {'GPUs w/ work':>12}  {'mem GB':>6}  {'scan GB':>7}")
    blocks = {}
    for r, d in zip(rows, dt):
        blocks.setdefault(int((r[0] - rows[0][0]) // (a.block * 60)), []).append((r, d))
    cpu_s = gpu_s = w_all = 0.0
    for k in sorted(blocks):
        b = blocks[k]
        w = sum(d for _, d in b) or 1.0
        cpu = sum(min(r[2], a.threads) * d for r, d in b) / w / a.threads * 100
        gpu = sum(gpu_mean(r) * d for r, d in b) / w
        active = sum(sum(1 for m in r[5] if m > 100) * d for r, d in b) / w
        cpu_s += cpu * w; gpu_s += gpu * w; w_all += w
        when = time.strftime("%H:%M", time.localtime(b[0][0][0]))
        print(f"{when:>5} {w / 60:>4.0f}  {cpu:>7.0f}%  {gpu:>7.0f}%  {active:>8.1f} of {len(b[0][0][4])}"
              f"  {max(r[3] for r, _ in b):>6.0f}  {b[-1][0][1]:>7.1f}")
    hours = (rows[-1][0] - t0) / 3600
    print(f"overall: CPU busy {cpu_s / w_all:.0f}%, GPU busy {gpu_s / w_all:.0f}% over {w_all / 60:.0f} min of metrics;"
          f" billed so far ~{hours:.2f} h = ${hours * a.usd_per_hour:.2f}")


if __name__ == "__main__":
    main()
