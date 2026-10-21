#!/usr/bin/env python3
"""Is a point inside the scan's mask? The public *masked* scan volumes store no chunks outside the scroll, but the
surface prediction can still show surfaces there; a strip grown there renders all-zero (a rented run lost ~1/7 of a
band's growth this way). This checks the level-0 scan chunk under each point: present and not all zero = inside.

  mask_check.py seeds VOL_URL SEEDS_IN SEEDS_OUT     keep the seeds (tsv: name x y z ...) whose chunk is inside;
                                                     prints how many were dropped
  mask_check.py trace VOL_URL TRACE_DIR [--n 20]     sample N valid nodes of a tifxyz surface; exit 3 and print
                                                     OUTSIDE-MASK if every one falls outside, else exit 0
  (exit 3, not 2: argparse exits 2 on a usage error, which must never read as "outside")
A chunk counts as missing when the bucket answers 403 or 404 to a HEAD request (masked volumes simply have no chunk
files outside the scroll). --read also downloads present chunks (a few MB each) and counts all-zero ones as outside.
Each chunk is asked about once, so points sharing a chunk cost one request. cover.py imports Scan to check every node
of the patches it picks from (Scan.inside_points).
"""
import argparse
import http.client
import json
import sys
import threading
import urllib.error
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import numcodecs
import numpy as np


def get(url, tries=5):
    for t in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (403, 404):
                return None
        except Exception:
            pass
        time.sleep(min(30, 2 ** t))
    raise RuntimeError(f"failed: {url}")


_local = threading.local()


def head_status(url, timeout=60):
    """Status of a HEAD request over this thread's kept-alive connection to the host, or None on a network error.
    A new connection per request is slow where connections are rate-limited: 16 at a time took ~2.3 s each on a
    home line, against ~0.09 s per request over one kept-alive connection."""
    u = urllib.parse.urlsplit(url)
    conns = _local.__dict__.setdefault("conns", {})
    for _ in range(2):   # a kept-alive connection that the server has since closed fails once: reconnect
        c = conns.get(u.netloc)
        if c is None:
            cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
            c = conns[u.netloc] = cls(u.netloc, timeout=timeout)
        try:
            c.request("HEAD", u.path + ("?" + u.query if u.query else ""))
            r = c.getresponse()
            r.read()
            return r.status
        except (http.client.HTTPException, OSError):
            c.close()
            conns.pop(u.netloc, None)
    return None


def exists(url, tries=5):
    for t in range(tries):
        if url.startswith(("https://", "http://")):
            st = head_status(url)
            if st is not None and 200 <= st < 300:
                return True
            if st in (403, 404):
                return False
        else:
            try:
                with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=60):
                    return True
            except urllib.error.HTTPError as e:
                if e.code in (403, 404):
                    return False
            except Exception:
                pass
        time.sleep(min(30, 2 ** t))
    raise RuntimeError(f"failed: {url}")


class Scan:
    def __init__(self, url, read=False):
        self.url = url.rstrip("/") + "/0"
        self.read = read
        m = json.loads(get(self.url + "/.zarray"))
        self.shape, self.chunks = m["shape"], m["chunks"]
        self.sep = m.get("dimension_separator", ".")
        self.codec = numcodecs.get_codec(m["compressor"]) if m.get("compressor") else None
        self.cache = {}
        self.pool = None   # one set of threads for every inside_points call, so their connections stay open

    def key(self, x, y, z):
        """The level-0 chunk holding the point, or None outside the volume."""
        if not (0 <= z < self.shape[0] and 0 <= y < self.shape[1] and 0 <= x < self.shape[2]):
            return None
        return int(z) // self.chunks[0], int(y) // self.chunks[1], int(x) // self.chunks[2]

    def _ask(self, k):
        url = f"{self.url}/{self.sep.join(map(str, k))}"
        if not self.read:
            return exists(url)
        raw = get(url)
        data = None if raw is None else (self.codec.decode(raw) if self.codec else raw)
        return data is not None and bool(np.frombuffer(data, np.uint8).any())

    def inside(self, x, y, z):
        k = self.key(x, y, z)
        if k is None:
            return False
        if k not in self.cache:
            self.cache[k] = self._ask(k)
        return self.cache[k]

    def inside_points(self, pts, threads=16):
        """inside() for an (N, 3) array of x y z points, asking about the chunks not yet known in parallel."""
        keys = [self.key(*p) for p in pts]
        new = sorted({k for k in keys if k is not None and k not in self.cache})
        if new and self.pool is None:
            self.pool = ThreadPoolExecutor(threads)
        for k, v in zip(new, self.pool.map(self._ask, new) if new else []):
            self.cache[k] = v
        return np.array([k is not None and self.cache[k] for k in keys], bool)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=("seeds", "trace"))
    ap.add_argument("vol")
    ap.add_argument("src")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--read", action="store_true", help="download present chunks and treat all-zero ones as outside")
    a = ap.parse_args()
    scan = Scan(a.vol, read=a.read)
    if a.mode == "seeds":
        if not a.out:
            ap.error("seeds needs SEEDS_OUT")
        rows = [l for l in open(a.src) if l.strip()]
        keep = [l for l in rows if scan.inside(*(int(float(v)) for v in l.split("\t")[1:4]))]
        with open(a.out, "w") as fh:
            fh.writelines(keep)
        print(f"{len(rows) - len(keep)} of {len(rows)} seeds dropped (scan chunk missing or empty), {len(keep)} kept")
        return
    import tifffile
    P = np.stack([tifffile.imread(f"{a.src}/{c}.tif") for c in "xyz"], -1).astype(np.float64)
    ok = np.all(np.isfinite(P), -1) & np.all(P > 0, -1)
    pts = P[ok]
    if len(pts) == 0:
        print("OUTSIDE-MASK no valid nodes")
        sys.exit(3)
    pts = pts[np.linspace(0, len(pts) - 1, min(a.n, len(pts))).astype(int)]
    n_in = sum(scan.inside(*p) for p in pts)
    if n_in == 0:
        print(f"OUTSIDE-MASK 0 of {len(pts)} sampled nodes inside the scan mask")
        sys.exit(3)
    print(f"inside: {n_in} of {len(pts)} sampled nodes")


if __name__ == "__main__":
    main()
