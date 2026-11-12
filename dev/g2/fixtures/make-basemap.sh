#!/usr/bin/env bash
#
# Build the G2 offline raster basemap fixture: a synthetic graticule over
# the sf-landmarks.geojson area as MBTiles (Web-Mercator tile pyramid), the
# format the engine's MBTilesTileReader consumes with no GDAL Java bindings.
#
# Output: dev/g2/build/fixtures/sf-graticule.mbtiles (gitignored; ~1 MB,
# regenerated on demand — CI builds it in the render-angle job).
#
# Usage: dev/g2/fixtures/make-basemap.sh [out.mbtiles [WEST SOUTH EAST NORTH]]
#        (bounds default to the sf-landmarks area; render/test/basemap-gate.sh
#        passes others to build a basemap that misses the camera frame)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/fixtures
G2="$(cd "$HERE/.." && pwd)"
OUT="${1:-$G2/build/fixtures/sf-graticule.mbtiles}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for t in gdal_translate gdaladdo gdalwarp; do
  command -v "$t" >/dev/null 2>&1 || { echo "make-basemap: missing $t (brew install gdal)" >&2; exit 1; }
done
# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$G2/../jdk.sh"
JDK="$(mactak_jdk_home 21 || true)"
[[ -n "$JDK" ]] || { echo "make-basemap: JDK 21 not found (dev/jdk.sh)" >&2; exit 1; }

# sf-landmarks.geojson bounds + margin; 16000 px/deg ≈ 7 m/px at 37.8°N (≈ zoom 14)
WEST="${2:--122.56}"; SOUTH="${3:-37.72}"; EAST="${4:--122.34}"; NORTH="${5:-37.87}"; PPD=16000

"$JDK/bin/javac" -d "$WORK" "$HERE/MakeBasemap.java"
"$JDK/bin/java" -Djava.awt.headless=true -cp "$WORK" MakeBasemap "$WORK/graticule.png" "$WEST" "$SOUTH" "$EAST" "$NORTH" "$PPD"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
# EPSG:4326 PNG (+world file; the PNG driver ignores .prj, so -s_srs) → Web Mercator GeoTIFF → MBTiles pyramid
gdalwarp -q -s_srs EPSG:4326 -t_srs EPSG:3857 -r bilinear -of GTiff "$WORK/graticule.png" "$WORK/graticule-3857.tif"
gdal_translate -q -of MBTILES -co TILE_FORMAT=PNG "$WORK/graticule-3857.tif" "$OUT"
gdaladdo -q -r average "$OUT" 2 4 8 16 32 64
echo "make-basemap: wrote $OUT ($(du -h "$OUT" | cut -f1))"
sqlite3 "$OUT" "select 'zoom', zoom_level, count(*) from tiles group by zoom_level;" 2>/dev/null | sed 's/^/make-basemap:   /' || true
