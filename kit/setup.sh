#!/bin/bash
# setup.sh [CONFIG] — prepare a fresh Linux GPU machine (a rented one, or a test HOME) to run the kit:
#   ~/envs/ink         Python 3.14 + PyTorch 2.14.1 (CUDA 13.0) + the frozen ink environment + villa's vesuvius package
#   ~/code/villa       (sparse: vesuvius/ only, pinned commit)       ~/tools/vc3d/squashfs-root   VC3D, run via AppRun
#   ~/models/<prefix>/ CONFIG's ink model (the search and the same-answer check use it); without CONFIG, Reader v2
#   ~/work             the kit's scripts                              ~/.kit-versions   what was installed
# Inputs: the kit folder ($KIT, default ~/kit) made by make_kit.sh (scripts, config/, test/control/, vc3d.AppImage).
# Everything else comes from public sources and is checksum-verified; every model must pass a weights-only load before
# it is used. No credentials are used or stored. apt packages are installed only when running as root (rented
# containers); elsewhere the system must already have them.
# Usage: bash ~/kit/setup.sh [~/kit/config/<scroll>.env]   (idempotent: finished steps are skipped; ends with a smoke test)
set -euo pipefail
KIT=${KIT:-$HOME/kit}
UV_VER=0.13.1
UV_SHA=eadd9d27c134ab5ac1ffd4473b97a741407f3ea238288f03121fc4deddf90220
VC3D_SHA=4a624e7cc6f068c54568262e970aa7e49f6b2cc9c420571d88fb7f695f3af731   # VC3D 2eb83c7 (2026-10-19), see NOTICE.md
VILLA_SHA=8aa507c1215f1fa8758f13d0538f7af9710e02d7
# PyPI uploads after this time are refused (steps 3 and 4, build tools included): a safety margin against freshly
# published, possibly compromised releases. Every pin in requirements-ink.txt is older.
EXCLUDE_NEWER=2026-10-09T00:00:00Z
PY=$HOME/envs/ink/bin/python
step() { echo "== $(date +%T) $*"; }
t0=$(date +%s)

step "1/8 system packages"
if [ "$(id -u)" = 0 ] && command -v apt-get > /dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # the VC3D command-line tools take these few libraries from the host (checked with ldd)
  apt-get install -y -qq --no-install-recommends ca-certificates curl git procps rsync util-linux \
      libglx0 libglvnd0 libx11-6 libxcb1 libcom-err2 libexpat1 libfontconfig1 libfreetype6 libgmp10 \
      libgpg-error0 libuuid1 zlib1g > /dev/null
else
  echo "not root: skipping apt (expects curl, git, flock, ps and pgrep (procps) and the VC3D host libraries to be present)"
fi

step "2/8 uv $UV_VER"
UV=$HOME/.local/bin/uv
if [ ! -x "$UV" ] || ! "$UV" --version | grep -q "$UV_VER"; then
  d=$HOME/.cache/scroll-kit/uv-$UV_VER; mkdir -p "$d"
  curl -fsSL -o "$d/uv.tgz" "https://github.com/astral-sh/uv/releases/download/$UV_VER/uv-x86_64-unknown-linux-gnu.tar.gz"
  echo "$UV_SHA  $d/uv.tgz" | sha256sum -c --quiet -
  tar -xzf "$d/uv.tgz" -C "$d"
  mkdir -p "$HOME/.local/bin"; install -m 755 "$d"/uv-x86_64-unknown-linux-gnu/uv "$d"/uv-x86_64-unknown-linux-gnu/uvx "$HOME/.local/bin/"
fi
"$UV" --version

step "3/8 Python environment ~/envs/ink"
if [ ! -e "$HOME/envs/ink/.complete" ]; then
  "$UV" python install 3.14
  [ -x "$PY" ] || "$UV" venv --python 3.14 "$HOME/envs/ink"
  "$UV" pip install --python "$PY" torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cu130
  # the frozen environment, minus torch (done above) and the unused CUDA 12 copies of the NVIDIA libraries
  # (the date limit is for PyPI: the PyTorch index publishes no upload times; torch 2.14.1 is from 2026-09-30)
  grep -v -E '^(torch|torchvision)==|^nvidia-[a-z0-9-]+-cu12==' "$KIT/requirements-ink.txt" > "$KIT/requirements-rest.txt"
  "$UV" pip install --python "$PY" --exclude-newer "$EXCLUDE_NEWER" -r "$KIT/requirements-rest.txt"
  touch "$HOME/envs/ink/.complete"
fi

step "4/8 villa vesuvius @ ${VILLA_SHA:0:7}"
if [ ! -e "$HOME/code/villa/vesuvius/pyproject.toml" ]; then
  mkdir -p "$HOME/code"
  git clone -q --filter=blob:none --no-checkout https://github.com/ScrollPrize/villa "$HOME/code/villa"
  git -C "$HOME/code/villa" sparse-checkout set --no-cone /vesuvius
  git -C "$HOME/code/villa" checkout -q "$VILLA_SHA"
fi
[ "$(git -C "$HOME/code/villa" rev-parse HEAD)" = "$VILLA_SHA" ] || { echo "villa is not at $VILLA_SHA"; exit 1; }
"$UV" pip install --python "$PY" --no-deps --exclude-newer "$EXCLUDE_NEWER" -e "$HOME/code/villa/vesuvius"   # its build tools are not pinned

step "5/8 VC3D 2eb83c7"
APP=$HOME/tools/vc3d/squashfs-root
if [ ! -x "$APP/AppRun" ]; then
  echo "$VC3D_SHA  $KIT/vc3d.AppImage" | sha256sum -c --quiet -
  mkdir -p "$HOME/tools/vc3d"; cp "$KIT/vc3d.AppImage" "$HOME/tools/vc3d/vc3d.AppImage"; chmod 755 "$HOME/tools/vc3d/vc3d.AppImage"
  (cd "$HOME/tools/vc3d" && ./vc3d.AppImage --appimage-extract > /dev/null)
fi
"$APP/AppRun" list | grep -c -E '^vc_(grow_seg_from_seed|grow_seg_from_segments|render_tifxyz)$' | grep -q 3 \
  || { echo "VC3D tools missing"; exit 1; }

step "6/8 kit scripts -> ~/work"
mkdir -p "$HOME/work" "$HOME/results"
cp -r "$KIT/work/." "$HOME/work/"
chmod 755 "$HOME/work"/*.sh

step "7/8 ink models (checksum + weights-only safety check)"
# shellcheck disable=SC1091
. "$HOME/work/common.sh"
set +e
if [ -n "${1:-}" ]; then
  load_config "$1" || exit 1
  install_model "$MODEL_URL" "$MODEL_SHA256" "$PREFIX" > /dev/null || exit $?
  echo "config $(basename "$1"): model $PREFIX, crop depth $(model_depth "$MODEL_FILE"), windows at $(window_starts "$(model_depth "$MODEL_FILE")")"
else
  install_model "$RV2_URL" "$RV2_SHA256" rv2 > /dev/null || exit $?
  echo "no config given: Reader v2 installed (bash ~/kit/setup.sh ~/kit/config/<scroll>.env installs that config's model)"
fi
set -e

step "8/8 smoke test"
"$PY" -I -c "
import torch, vesuvius, zarr, tifffile, scipy
from vesuvius.ink_detection.inference import infer
n = torch.cuda.device_count()
print('torch', torch.__version__, 'GPUs', n, [torch.cuda.get_device_name(i) for i in range(n)])
assert n > 0, 'no GPU visible'
"
"$APP/AppRun" vc_render_tifxyz --help > /dev/null 2>&1 || "$APP/AppRun" vc_render_tifxyz -h > /dev/null 2>&1 \
  || echo "note: vc_render_tifxyz --help returned non-zero (checked by the first real render)"
{
  echo "kit $(cat "$KIT/VERSION" 2> /dev/null || echo unversioned)"
  echo "vc3d 2eb83c7 sha256 $VC3D_SHA"; echo "villa $VILLA_SHA"; echo "uv $UV_VER"
  "$PY" -I -c "import sys, torch; print('python', sys.version.split()[0]); print('torch', torch.__version__, 'cuda', torch.version.cuda)"
  for f in "$HOME"/models/*/*.pth; do [ -e "$f.safe" ] && echo "model $f sha256 $(sha256sum "$f" | cut -c1-16)... depth $(cat "$f.depth")"; done
} > "$HOME/.kit-versions"
cat "$HOME/.kit-versions"
echo "setup done in $(( $(date +%s) - t0 ))s; disk free: $(df -h "$HOME" | tail -n 1 | awk '{print $4}')"
touch "$HOME/.kit-setup-ok"
