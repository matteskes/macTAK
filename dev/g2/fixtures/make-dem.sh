#!/usr/bin/env bash
#
# Build the G2.6 elevation fixtures: one tilted plane of known heights
# (MakeDem: h = 50 + 4000*(lat - 37.72) + 2000*(lon + 122.56) metres), in the
# two formats G2.6 proves:
#
#   GeoTIFF   dev/g2/build/fixtures/sf-dem.tif: Float32 on NAD83 (EPSG:4269,
#             what USGS 3DEP ships), 1/3 arc-second cells over the
#             landmarks area, 256x256 tiles, DEFLATE, overviews
#   DTED      dev/g2/build/fixtures/dted/w123/n37.dt1: the whole 1x1 degree
#             cell 37-38N 122-123W, DTED level 1 (3 arc-second posts,
#             whole metres), in the w123/n37.dt1 tree DtedElevationSource reads
#
# Both gitignored, regenerated on demand; CI builds them in the render job.
#
# Usage: dev/g2/fixtures/make-dem.sh [OUT_DIR [WEST SOUTH EAST NORTH [SHIFT]]]
#        (default dev/g2/build/fixtures and the landmarks area; the bounds and
#        SHIFT shape the GeoTIFF only: render/test/elevation.sh builds one
#        that misses the camera frame, and one whose georeference is moved
#        SHIFT degrees east while its heights stay: misregistered elevation)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/fixtures
G2="$(cd "$HERE/.." && pwd)"
OUT="${1:-$G2/build/fixtures}"
WEST="${2:--122.56}"; SOUTH="${3:-37.72}"; EAST="${4:--122.34}"; NORTH="${5:-37.87}"; SHIFT="${6:-0}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for t in gdal_translate gdaladdo; do
  command -v "$t" >/dev/null 2>&1 || { echo "make-dem: missing $t (brew install gdal)" >&2; exit 1; }
done
# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$G2/../jdk.sh"
JDK="$(mactak_jdk_home 21 || true)"
[[ -n "$JDK" ]] || { echo "make-dem: JDK 21 not found (dev/jdk.sh)" >&2; exit 1; }

"$JDK/bin/javac" -d "$WORK" "$HERE/MakeDem.java"
mkdir -p "$OUT/dted/w123"

# GeoTIFF: 1/3 arc-second (10800 cells per degree) over the landmarks area
"$JDK/bin/java" -cp "$WORK" MakeDem "$WORK/plane.asc" "$WEST" "$SOUTH" "$EAST" "$NORTH" 10800
# SHIFT: move the grid's origin (the xllcorner line), not its heights
python3 - "$WORK/plane.asc" "$SHIFT" <<'PY'
import sys
path, shift = sys.argv[1], float(sys.argv[2])
lines = open(path).read().split("\n")
key, value = lines[2].split()
assert key == "xllcorner"
lines[2] = "xllcorner %.12f" % (float(value) + shift)
open(path, "w").write("\n".join(lines))
PY
rm -f "$OUT/sf-dem.tif"
gdal_translate -q -a_srs EPSG:4269 -ot Float32 -of GTiff \
  -co TILED=YES -co BLOCKXSIZE=256 -co BLOCKYSIZE=256 -co COMPRESS=DEFLATE \
  "$WORK/plane.asc" "$OUT/sf-dem.tif"
gdaladdo -q -r average "$OUT/sf-dem.tif" 2 4 8 16

# DTED level 1: 1201x1201 posts on the 1x1 degree cell; posts sit on whole
# 3-arc-second lines, so the grid's cell centres must too (half a post out)
"$JDK/bin/java" -cp "$WORK" MakeDem "$WORK/cell.asc" \
  -123.000416666667 36.999583333333 -121.999583333333 38.000416666667 1200
rm -f "$OUT/dted/w123/n37.dt1"
gdal_translate -q -a_srs EPSG:4326 -ot Int16 -of DTED "$WORK/cell.asc" "$OUT/dted/w123/n37.dt1"

echo "make-dem: wrote $OUT/sf-dem.tif ($(du -h "$OUT/sf-dem.tif" | cut -f1)) and $OUT/dted/w123/n37.dt1 ($(du -h "$OUT/dted/w123/n37.dt1" | cut -f1))"
