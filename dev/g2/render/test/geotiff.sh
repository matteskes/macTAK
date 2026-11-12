#!/usr/bin/env bash
#
# G2.4 b.1 GeoTIFF gate: imagery through GDAL, in the right place.
#
#   draws      the synthetic UTM 10N GeoTIFF (make-imagery.sh) goes through
#              GdalLayerInfo → GdalTileReader → DatasetRasterLayer2 and the
#              frame passes; the run log must show provider=gdal
#   placed     the pixel over three ground points is the field colour
#              MakeImagery painted there (RenderSmoke --expect): a raster in
#              the wrong place (axis order, projection) fills the frame just
#              as well, so coverage alone cannot tell
#   off-frame  the same imagery built east of the camera frame must fail the
#              content gate, as render/test/basemap-gate.sh does for MBTiles
#   shifted    the same pixels georeferenced one field (0.005 degrees) east
#              must fail --expect: the georeferencing check catches
#              misregistered imagery
#
# Needs what dev/g2/render/run.sh needs (ANGLE engine, make gdal-java) and
# the GDAL CLI (make-imagery.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test
ROOT="$(cd "$HERE/../../../.." && pwd)"
FIX="$ROOT/dev/g2/build/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# camera: the middle of the imagery at 15 m/px, so a 0.005-degree field is ~30 px
CAMERA=(--at "37.795,-122.445" --res 15)
# field centres clear of the roads and labels
POINTS=("37.7725,-122.4775" "37.8175,-122.4125" "37.7875,-122.4375")

# MakeImagery's field colour at a point: FIELDS[(i*3 + j*5) mod 4] with
# i, j the field's index (floor(lon / 0.005), floor(lat / 0.005))
field_colour() {
  python3 -c '
import math, sys
lat, lon = (float(v) for v in sys.argv[1].split(","))
fields = ["3f7a4a", "5e8f3e", "2f6e73", "4c8a6a"]
i, j = math.floor(lon / 0.005), math.floor(lat / 0.005)
print(fields[(i * 3 + j * 5) % 4])' "$1"
}

expects=()
for p in "${POINTS[@]}"; do expects+=(--expect "$p,$(field_colour "$p")"); done

log() { printf '[geotiff] %s\n' "$*"; }
fail() { log "FAIL: $*" >&2; tail -25 "$WORK/run.log" | sed 's/^/    | /' >&2; exit 1; }
render() {   # render LOGNAME RENDER_ARGS... ; returns the smoke's exit code
  set +e
  bash "$ROOT/dev/g2/render/run.sh" "${@:2}" > "$WORK/run.log" 2>&1
  local rc=$?
  set -e
  grep -E '^render-smoke: (basemap|expect|sentinel|PASS|FAIL)' "$WORK/run.log" | sed 's/^/    /' || true
  cp "$WORK/run.log" "$WORK/$1.log"
  return "$rc"
}

bash "$ROOT/dev/g2/fixtures/make-imagery.sh" "$FIX/sf-imagery.tif" > /dev/null

log "draws + placed: sf-imagery.tif (UTM 10N), three ground points"
render placed --basemap "$FIX/sf-imagery.tif" "${CAMERA[@]}" "${expects[@]}" \
  --out "$ROOT/dev/g2/build/render-geotiff.png" || fail "the GeoTIFF render failed"
grep -q 'render-smoke: basemap sf-imagery.tif type=native provider=gdal' "$WORK/run.log" \
  || fail "the GeoTIFF was not described by GDAL (provider=gdal)"
[[ "$(grep -c ': ok$' "$WORK/run.log")" -eq "${#POINTS[@]}" ]] || fail "not every ground point had its colour"

log "off-frame: the same imagery east of the camera must fail the content gate"
bash "$ROOT/dev/g2/fixtures/make-imagery.sh" "$WORK/off-frame.tif" -122.30 37.78 -122.20 37.85 > /dev/null
if render off-frame --basemap "$WORK/off-frame.tif" "${CAMERA[@]}"; then
  fail "off-frame imagery passed the smoke"
fi
grep -q 'FAIL: basemap attached but content covers' "$WORK/run.log" || fail "off-frame failed, but not on the content gate"

log "shifted: the same pixels georeferenced one field east must fail --expect"
bash "$ROOT/dev/g2/fixtures/make-imagery.sh" "$WORK/shifted.tif" -122.56 37.72 -122.34 37.87 0.005 > /dev/null
if render shifted --basemap "$WORK/shifted.tif" "${CAMERA[@]}" "${expects[@]}"; then
  fail "imagery shifted one field east passed --expect"
fi
grep -q 'FAIL: a pixel over a known ground point has the wrong colour' "$WORK/run.log" \
  || fail "shifted imagery failed, but not on --expect"

log "PASS: GeoTIFF imagery draws through GDAL, in the right place; off-frame and shifted imagery fail"
