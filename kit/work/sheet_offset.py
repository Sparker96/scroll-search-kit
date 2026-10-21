# usage: sheet_offset.py OUT.tsv ZARR...  per-tile depth profile of a layer render (61 layers in this kit): where is the
# bright papyrus? For each 40x40 tile with data: mean intensity per layer, peak layer, contrast (max-min)/mean.
# Appends to OUT.tsv. No tile with data (empty output) = a blank render, which inkq.sh treats as BLANK.
# Reads the render one chunk-slab of layers at a time (uint8), so memory stays near one slab instead of a float copy of
# the whole volume; the numbers are the same as reading it whole.
import sys, zarr, numpy as np
T = 40
with open(sys.argv[1], "a") as fh:
    for z in sys.argv[2:]:
        g = zarr.open(z, mode="r")
        a = g["0"] if hasattr(g, "keys") and "0" in g else g
        d, h, w = a.shape
        h2, w2 = h // T, w // T
        prof = np.zeros((d, h2, w2), np.float32)        # (layers, h2, w2) tile means
        pos = np.zeros((h2, w2), np.int64)              # voxels > 0 per tile, over all layers
        step = max(1, int(a.chunks[0]))
        for z0 in range(0, d, step):
            slab = np.asarray(a[z0:z0 + step])          # uint8
            for i in range(slab.shape[0]):
                t = slab[i, :h2 * T, :w2 * T].astype(np.float32).reshape(h2, T, w2, T)
                prof[z0 + i] = t.mean(axis=(1, 3))
                pos += (t > 0).sum(axis=(1, 3))
        valid = pos / float(d * T * T) > 0.9
        k = np.ones(3) / 3
        sm = np.apply_along_axis(lambda p: np.convolve(p, k, mode="same"), 0, prof)
        pk = sm[1:-1].argmax(0) + 1
        con = (sm.max(0) - sm.min(0)) / (sm.mean(0) + 1e-6)
        name = z.rstrip("/").split("/")[-1].replace(".zarr", "")
        ys, xs = np.nonzero(valid)
        for y, x in zip(ys, xs):
            fh.write(f"{name}\t{y*T}\t{x*T}\t{pk[y,x]}\t{con[y,x]:.3f}\t" + ",".join(f"{q:.0f}" for q in prof[:, y, x]) + "\n")
        print(name, (d, h, w), int(valid.sum()), "tiles")
