#!/usr/bin/env bash
#
# Build the G2.4 b.1 GeoTIFF imagery fixture: synthetic "aerial" imagery
# (MakeImagery: green and blue fields, a white road grid, "GeoTIFF" labels)
# over the sf-landmarks area, as real imagery ships: reprojected to UTM
# zone 10N on NAD83 (EPSG:26910, USGS NAIP's projection), tiled 256x256,
# DEFLATE-compressed, with internal overviews. The engine reads it through
# GDAL: GdalLayerInfo → GdalTileReader → textures.
#
# Output: dev/g2/build/fixtures/sf-imagery.tif (gitignored; regenerated on
# demand; CI builds it in the render job).
#
# Usage: dev/g2/fixtures/make-imagery.sh [out.tif [WEST SOUTH EAST NORTH [SHIFT]]]
#        (bounds default to the sf-landmarks area; render/test/geotiff.sh
#        passes others to build imagery that misses the camera frame, and
#        SHIFT, in degrees, to move the georeference east while the pixels
#        stay: misregistered imagery, for the georeferencing canary)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/fixtures
G2="$(cd "$HERE/.." && pwd)"
OUT="${1:-$G2/build/fixtures/sf-imagery.tif}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for t in gdalwarp gdaladdo gdalinfo; do
  command -v "$t" >/dev/null 2>&1 || { echo "make-imagery: missing $t (brew install gdal)" >&2; exit 1; }
done
# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$G2/../jdk.sh"
JDK="$(mactak_jdk_home 21 || true)"
[[ -n "$JDK" ]] || { echo "make-imagery: JDK 21 not found (dev/jdk.sh)" >&2; exit 1; }

WEST="${2:--122.56}"; SOUTH="${3:-37.72}"; EAST="${4:--122.34}"; NORTH="${5:-37.87}"; SHIFT="${6:-0}"; PPD=16000

"$JDK/bin/javac" -d "$WORK" "$HERE/MakeImagery.java"
"$JDK/bin/java" -Djava.awt.headless=true -cp "$WORK" MakeImagery "$WORK/imagery.png" "$WEST" "$SOUTH" "$EAST" "$NORTH" "$PPD"
# SHIFT: move the world file's origin (its 5th line, the upper-left x)
python3 - "$WORK/imagery.pgw" "$SHIFT" <<'PY'
import sys
path, shift = sys.argv[1], float(sys.argv[2])
lines = open(path).read().split("\n")
lines[4] = "%.12f" % (float(lines[4]) + shift)
open(path, "w").write("\n".join(lines))
PY

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
gdalwarp -q -s_srs EPSG:4326 -t_srs EPSG:26910 -r bilinear -of GTiff \
  -co TILED=YES -co BLOCKXSIZE=256 -co BLOCKYSIZE=256 -co COMPRESS=DEFLATE -co PHOTOMETRIC=RGB \
  "$WORK/imagery.png" "$OUT"
gdaladdo -q -r average "$OUT" 2 4 8 16
echo "make-imagery: wrote $OUT ($(du -h "$OUT" | cut -f1))"
gdalinfo "$OUT" | grep -E '^Size is|^PROJCRS|Overviews:' | sort -u | sed 's/^ */make-imagery:   /' || true
