#!/bin/bash
# make_kit.sh [OUT_DIR] — assemble the folder that is copied to a rented machine (vast.sh push ID OUT_DIR):
#   setup.sh, requirements-ink.txt, VERSION, work/, config/, test/control/ and vc3d.AppImage   [default OUT_DIR build/kit]
# The VC3D AppImage and the control data are release assets of this repository (too big for git). They are downloaded
# once and checksum-verified, or taken from local copies: VC3D_APPIMAGE=/path/to/VC3D...AppImage, CONTROL_TGZ=/path.
# Nothing secret goes in: the folder is scanned for key-like content and refused if any turns up.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
K=${1:-$R/build/kit}
RELEASE=${RELEASE:-https://github.com/Sparker96/scroll-search-kit/releases/download/v1.0}
VC3D_SHA=4a624e7cc6f068c54568262e970aa7e49f6b2cc9c420571d88fb7f695f3af731
VC3D_URL=${VC3D_URL:-$RELEASE/VC3D-2eb83c7-2026-10-19-linux-x86_64.AppImage}
CONTROL_SHA=${CONTROL_SHA:-34e562a53261f699d15ec82dcc3b50829e903987763156bb317a66ff1b3ec1ae}
CONTROL_URL=${CONTROL_URL:-$RELEASE/control-0343.tar.gz}
# the kit records the commit it was built from; uncommitted changes would make that record false
if [ -n "$(git -C "$R" status --porcelain 2> /dev/null)" ] && [ "${ALLOW_DIRTY:-0}" != 1 ]; then
  echo "the repository has uncommitted changes: commit them (or ALLOW_DIRTY=1 for a throw-away test kit)"; exit 1
fi
mkdir -p "$K/test"
cp "$R/kit/setup.sh" "$R/kit/requirements-ink.txt" "$K/"
cp -r "$R/kit/work" "$R/kit/config" "$K/"
# scroll axis files that are not in the repository (UMBILICI_DIR=folder of <scroll>_umbilicus.json files)
if [ -n "${UMBILICI_DIR:-}" ]; then mkdir -p "$K/config/umbilici"; cp "$UMBILICI_DIR"/*_umbilicus.json "$K/config/umbilici/"; fi
rm -rf "$K/work/__pycache__"
(git -C "$R" describe --tags --always --dirty 2> /dev/null || echo unversioned) > "$K/VERSION"
if ! echo "$VC3D_SHA  $K/vc3d.AppImage" | sha256sum -c --quiet - 2> /dev/null; then
  if [ -n "${VC3D_APPIMAGE:-}" ]; then cp "$VC3D_APPIMAGE" "$K/vc3d.AppImage.part"
  else curl -fL --retry 3 -o "$K/vc3d.AppImage.part" "$VC3D_URL"; fi
  echo "$VC3D_SHA  $K/vc3d.AppImage.part" | sha256sum -c --quiet - || { echo "VC3D AppImage checksum MISMATCH"; exit 1; }
  mv "$K/vc3d.AppImage.part" "$K/vc3d.AppImage"
fi
if [ ! -s "$K/test/control/check.env" ]; then
  if [ -d "$R/kit/test/control" ]; then cp -r "$R/kit/test/control" "$K/test/"
  else
    tgz=${CONTROL_TGZ:-}
    # a downloaded archive is fetched afresh and removed once unpacked: the kit carries the control, not the archive
    if [ -z "$tgz" ]; then tgz=$K/test/control.tar.gz.part; rm -f "$tgz"; curl -fL --retry 3 -o "$tgz" "$CONTROL_URL"; fi
    if [ -n "$CONTROL_SHA" ]; then echo "$CONTROL_SHA  $tgz" | sha256sum -c --quiet - || { echo "control checksum MISMATCH"; exit 1; }; fi
    tar -xzf "$tgz" -C "$K/test"
    [ -n "${CONTROL_TGZ:-}" ] || rm -f "$tgz"
  fi
fi
chmod 755 "$K"/*.sh "$K/work"/*.sh
# every config must find its scroll axis in the kit, or say where to download it (UMBILICUS_URL)
for c in "$K"/config/*.env; do
  [ "$(basename "$c")" = TEMPLATE.env ] && continue
  u=$(sed -n 's/^UMBILICUS=\([^ #]*\).*/\1/p' "$c" | tail -n 1)
  case $u in /*|"") ;; *) u=$K/config/$u ;; esac
  if [ -n "$u" ] && [ ! -s "$u" ] && ! grep -q '^UMBILICUS_URL=.' "$c"; then
    echo "$(basename "$c"): scroll axis $u is not in the kit and has no UMBILICUS_URL (UMBILICI_DIR=... adds it): refusing"; exit 1
  fi
  s=$(sed -n 's/^SEEDS_EXTRA=\([^ #]*\).*/\1/p' "$c" | tail -n 1)
  case $s in /*|"") ;; *) s=$K/config/$s ;; esac
  if [ -n "$s" ] && [ ! -s "$s" ]; then echo "$(basename "$c"): SEEDS_EXTRA $s is not in the kit: refusing"; exit 1; fi
done
# nothing secret may travel to a rented machine: private keys, tokens, and 64-hex strings that are not checksums
python3 -I - "$K" << 'EOF' || { echo "kit contains something that looks secret: refusing"; exit 1; }
import re, sys
from pathlib import Path
bad = re.compile(r"BEGIN [A-Z ]*PRIVATE KEY|vastai-auth|Authorization: Bearer [A-Za-z0-9]|\bhf_[A-Za-z0-9]{30,}"
                 r"|\bgh[pousr]_[A-Za-z0-9]{30,}|\bAKIA[0-9A-Z]{16}\b")
hex64 = re.compile(r"\b[0-9a-fA-F]{64}\b")
hits = []
for p in Path(sys.argv[1]).rglob("*"):
    if not p.is_file() or p.stat().st_size > 5_000_000:
        continue
    try:
        text = p.read_text()
    except (UnicodeDecodeError, OSError):
        continue
    for n, line in enumerate(text.splitlines(), 1):
        checksum_line = re.search(r"sha|SHA|checksum", line) or (
            p.name == "SHA256SUMS" and re.fullmatch(r"[0-9a-f]{64}  [^ ]+", line))   # sha256sum's own output format
        if bad.search(line) or (hex64.search(line) and not checksum_line):
            hits.append(f"{p}:{n}")
print("\n".join(hits))
sys.exit(1 if hits else 0)
EOF
du -sh "$K"; find "$K" -maxdepth 2 | sort | head -n 40
