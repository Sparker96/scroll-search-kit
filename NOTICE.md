# Third-party software and data

DRAFT 2026-10-20 — release asset names and checksums to be filled in at release.

The kit's own scripts are MIT-licensed (LICENSE). It runs, downloads or redistributes the following.

## VC3D (Volume Cartographer) — redistributed, unmodified, GPLv3

- What: `VC3D-2eb83c7-2026-10-19-linux-x86_64.AppImage`, the official Linux build of VC3D from
  ScrollPrize/villa at commit `2eb83c7`, published by the villa project as its rolling "latest" release on
  2026-10-19. sha256 `4a624e7cc6f068c54568262e970aa7e49f6b2cc9c420571d88fb7f695f3af731`.
- Why we mirror it: villa's release builds rotate (only "latest" and "stable" are kept), so this exact build is no
  longer downloadable upstream. The kit's same-answer check depends on one fixed build. The file is byte-for-byte the
  upstream one; we did not rebuild or change it.
- Licence: VC3D is licensed under the GNU General Public License v3 (`GPL-3.0.txt`, next to the binary in the
  release). Corresponding source: `villa-2eb83c7.tar.gz` in the same release (a `git archive` of the whole villa
  repository at that commit, including its build files: `volume-cartographer/scripts/Dockerfile.appimage` and
  `build_appimage.sh` describe how the AppImage is built). Upstream: https://github.com/ScrollPrize/villa.
- Bundled libraries: the AppImage bundles Ubuntu 26.04 libraries (Qt 6, OpenCV, GDAL, OpenSSL and ~170 others).
  Their copyright and licence files are inside the AppImage under `usr/share/doc/<package>/copyright`. The build's
  glibc-bundling step adds glibc, libstdc++ and libgcc_s without their own copyright files:
  - glibc (Ubuntu `2.43-2ubuntu2.4`, LGPL-2.1+): its Ubuntu copyright file is in the release as
    `third-party/libc6.copyright`; source: Ubuntu source package `glibc` 2.43-2ubuntu2.4.
  - libstdc++ and libgcc_s come from the `gcc-16` source package (GPL-3 with the GCC Runtime Library Exception); its
    copyright file is already inside the AppImage as `usr/share/doc/libgomp1/copyright`.
- Alternatives (not verified with the kit): villa's current "stable" and "latest" releases.

## Downloaded at setup (not redistributed)

- Reader V3 ink model (the default), by Domenico Russo — Hugging Face `domenicor046/reader-v3`, revision `aee1d64b`,
  file `reader-v3.pth`, sha256 `ea405417…`; MIT licence (model card, checked 2026-10-21); code and evaluations:
  github.com/DomRusso2/reader-v3.
- Reader v2 ink model, by Domenico Russo — Hugging Face `domenicor046/reader-v2`, revision `72633d8a`, file
  `reader-v2-step040000.pth`, sha256 `654ec5ac…`; MIT licence (model card, checked 2026-10-20); code and evaluations:
  github.com/DomRusso2/reader-v2.
- `vesuvius` Python package from ScrollPrize/villa at commit `8aa507c` (MIT).
- PyTorch 2.14.1 (CUDA 13.0) and the Python packages pinned in `kit/requirements-ink.txt`, from PyPI / the PyTorch
  index, each under its own licence.
- `uv` 0.13.1 by Astral (MIT / Apache-2.0), checksum-verified.

## Data

- Scan volumes and surface predictions: Vesuvius Challenge open-data bucket (CC-BY-NC 4.0), read remotely.
- `kit/config/umbilici/PHerc0343_umbilicus.json`: PHerc. 0343 scroll axis by Erwin Nieuwlaar, unmodified copy of
  `inputs/umbilicus_PHerc0343.json` in github.com/Nieuwlaar/pherc343-first-letters at commit `e8370f1f` (git blob
  `e082fdb8`, sha256 `e05a0a62…`); MIT licence, "Copyright (c) 2026 Erwin Nieuwlaar", full text beside it in
  `PHerc0343_umbilicus.LICENSE`.
- `kit/config/seeds/PHerc0343_letters.tsv`: six points at PHerc. 0343 letters 1, 4, 6, 9, 12 and 16, from Erwin
  Nieuwlaar's letter boxes in github.com/Nieuwlaar/pherc343-first-letters at commit `e8370f1f`, placed on voxels of the
  surface prediction (snap distance 0, last column); columns name x y z (level-0 voxels of volume 20250521140437),
  three unused columns (-1). MIT licence, "Copyright (c) 2026 Erwin Nieuwlaar", full text in `PHerc0343_letters.LICENSE`.
- Control strip and reference maps (`control-0343.tar.gz`, release asset): derived from PHerc. 0343 open data,
  CC-BY-NC 4.0.
- Images in `docs/img/`: derived from the Vesuvius Challenge open data, CC-BY-NC 4.0 (not MIT like the code).
  `control-0343-nodata-rv3.png`, `ctrl-0343-strip.jpg` and `quick-0343-letters.png` show PHerc. 0343, whose letters
  were first found by Erwin Nieuwlaar (First Letters, 2026; `quick-0343-letters.png` also shows his letter mesh and
  letter boxes, MIT, read with Reader v2); `ctrl-0814.jpg` shows the PHerc. 0814 team segment and its published ink
  result.
- PHerc. 0343 letter positions used for validation: Erwin Nieuwlaar, github.com/Nieuwlaar/pherc343-first-letters
  (MIT). PHerc. 0814 team segment and ink result: Vesuvius Challenge open data (CC-BY-NC 4.0).
