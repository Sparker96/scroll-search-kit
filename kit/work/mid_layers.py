# usage: mid_layers.py OUTDIR ZARR...  preview image of a layer render: the mean of its 3 middle layers -> OUTDIR/<name>__mid.tif
import sys, zarr, tifffile, numpy as np
for z in sys.argv[2:]:
    g = zarr.open(z, mode="r")
    a = g["0"] if hasattr(g, "keys") and "0" in g else g
    d = a.shape[0]
    mid = np.asarray(a[d // 2 - 1:d // 2 + 2]).mean(0).astype(np.uint8)
    out = sys.argv[1] + "/" + z.rstrip("/").split("/")[-1].replace(".zarr", "") + "__mid.tif"
    tifffile.imwrite(out, mid, compression="zlib")
    print(out, a.shape, mid.shape)
