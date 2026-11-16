#!/usr/bin/env bash
#
# The own-GDAL guards (dev/deps/README.md), run after a build:
#   1. check-gdal-drivers.sh: dev/deps/dist's GDAL registers exactly the
#      drivers dev/deps/gdal-drivers.txt lists;
#   2. check-closure.py: the libraries the process loads, from every built
#      root present (engine, JNI glue, commo, GDAL's Java bindings), hold no
#      OpenSSL 4, Homebrew curl/libpq or Homebrew GDAL/PROJ/libspatialite,
#      and one libgdal and one libproj;
#   3. brew-pins.py --closure: every Homebrew package they load is in the
#      Brewfile, at the version Brewfile.lock.json pins (#151).
#
# Usage: dev/deps/check.sh   (make check-deps)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/deps
ROOT="$(cd "$HERE/../.." && pwd)"

bash "$HERE/check-gdal-drivers.sh"

roots=()
for f in "$ROOT"/dev/g1/native-dist/libtakengine.dylib "$ROOT"/dev/g1/native-dist/libtakenginejni.dylib \
         "$ROOT"/dev/g1/native-dist/libcommoncommo.dylib "$ROOT"/dev/g1/native-dist/libcommoncommojni.dylib \
         "$ROOT"/dev/g2/gdal-java-dist/libgdalalljni.dylib; do
  [[ -f "$f" ]] && roots+=("$f")
done
(( ${#roots[@]} > 0 )) || { echo "[closure] FAIL: nothing built to check (run dev/g1/build-native.sh)"; exit 1; }
echo "[closure] roots: ${roots[*]##*/}"
python3 -I "$HERE/check-closure.py" "${roots[@]}"
# every Homebrew package those load is in the Brewfile, at its pinned version (#151)
python3 -I "$HERE/brew-pins.py" --closure "${roots[@]}"
