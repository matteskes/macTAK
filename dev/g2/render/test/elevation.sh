#!/usr/bin/env bash
#
# G2.6 elevation gate: the engine reads a GeoTIFF DEM and a DTED cell, gives
# the right heights, and the terrain renderer draws them on ANGLE.
#
# The fixtures (make-dem.sh) are one tilted plane of known heights,
# h = 50 + 4000*(lat - 37.72) + 2000*(lon + 122.56) metres, which
# interpolation reproduces exactly, so every expected height is the formula.
#
#   geotiff    sf-dem.tif under the synthetic imagery, camera tilted 50 deg:
#              heights at three points (RenderSmoke --expect-height; a file
#              with no vertical datum reads as ellipsoid heights), and ray
#              casts hit the terrain mesh at the engine's height (automatic
#              with --elevation)
#   dted       the DTED cell w123/n37.dt1: the same heights above mean sea
#              level (--expect-height ...,msl adds the engine's geoid
#              height, -32 m here) and the terrain mesh
#   off-frame  a DEM east of the camera: no height at the points, no terrain
#              under the rays: must fail
#   shifted    the same heights georeferenced 0.005 degrees east (10 m of
#              this plane's slope): must fail --expect-height
#
# Needs what dev/g2/render/run.sh needs (ANGLE engine, make gdal-java) and
# the GDAL CLI (the fixtures).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test
ROOT="$(cd "$HERE/../../../.." && pwd)"
FIX="$ROOT/dev/g2/build/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CAMERA=(--at "37.79,-122.45" --res 20 --tilt 50)
POINTS=("37.79,-122.45" "37.75,-122.5" "37.82,-122.4")

plane() {   # the fixtures' height at LAT,LON
  python3 -c 'import sys; lat, lon = (float(v) for v in sys.argv[1].split(",")); print("%.3f" % (50 + 4000 * (lat - 37.72) + 2000 * (lon + 122.56)))' "$1"
}
heights=(); heights_msl=()
for p in "${POINTS[@]}"; do
  heights+=(--expect-height "$p,$(plane "$p")")
  heights_msl+=(--expect-height "$p,$(plane "$p"),msl")
done

log() { printf '[elevation] %s\n' "$*"; }
fail() { log "FAIL: $*" >&2; tail -25 "$WORK/run.log" | sed 's/^/    | /' >&2; exit 1; }
render() {   # render RENDER_ARGS... ; returns the smoke's exit code
  set +e
  bash "$ROOT/dev/g2/render/run.sh" "$@" > "$WORK/run.log" 2>&1
  local rc=$?
  set -e
  grep -E '^render-smoke: (elevation|height|terrain|PASS|FAIL)' "$WORK/run.log" | sed 's/^/    /' || true
  return "$rc"
}

bash "$ROOT/dev/g2/fixtures/make-dem.sh" "$FIX" > /dev/null
bash "$ROOT/dev/g2/fixtures/make-imagery.sh" "$FIX/sf-imagery.tif" > /dev/null

log "geotiff: sf-dem.tif under the imagery, tilted"
render --basemap "$FIX/sf-imagery.tif" --elevation "$FIX/sf-dem.tif" "${CAMERA[@]}" "${heights[@]}" \
  --out "$ROOT/dev/g2/build/render-elevation.png" || fail "the GeoTIFF elevation render failed"
[[ "$(grep -c '^render-smoke: terrain .*: ok$' "$WORK/run.log")" -eq 3 ]] || fail "the terrain mesh was not under every ray"

log "dted: the w123/n37.dt1 cell, heights above sea level"
render --elevation "$FIX/dted" "${CAMERA[@]}" "${heights_msl[@]}" || fail "the DTED elevation render failed"

log "off-frame: a DEM east of the camera must fail"
mkdir -p "$WORK/off-frame"
bash "$ROOT/dev/g2/fixtures/make-dem.sh" "$WORK/off-frame" -122.30 37.78 -122.20 37.85 > /dev/null
if render --elevation "$WORK/off-frame/sf-dem.tif" "${CAMERA[@]}" "${heights[@]}"; then
  fail "an off-frame DEM passed"
fi
grep -q 'FAIL: the terrain renderer did not draw the elevation' "$WORK/run.log" || fail "off-frame failed, but not on the terrain check"

log "shifted: the same heights georeferenced 0.005 degrees east must fail --expect-height"
mkdir -p "$WORK/shifted"
bash "$ROOT/dev/g2/fixtures/make-dem.sh" "$WORK/shifted" -122.56 37.72 -122.34 37.87 0.005 > /dev/null
if render --elevation "$WORK/shifted/sf-dem.tif" "${CAMERA[@]}" "${heights[@]}"; then
  fail "a shifted DEM passed"
fi
grep -q 'FAIL: a height at a known point is wrong' "$WORK/run.log" || fail "shifted failed, but not on --expect-height"

log "PASS: GeoTIFF and DTED elevation give the right heights and the terrain renderer draws them; off-frame and shifted elevation fail"
