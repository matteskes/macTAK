#!/usr/bin/env bash
#
# G1 offline-layer canary: atak-headless opens vector layers through the
# engine's feature stack (native OGR provider -> PersistentDataSourceFeatureDataStore2)
# and reads the features back through FeatureDataStore2 cursors.
#
#   dev/g1/headless/test/layer.sh            # committed GeoJSON fixture (+ SHP/GPKG/KML
#                                            # derived from it when ogr2ogr is on PATH)
#   dev/g1/headless/test/layer.sh FILE...    # your own layer file(s)
#
# PASS = every layer opens and yields the expected feature count.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g1/headless/test
CLI="$HERE/../atak-headless"
FIXTURE="$HERE/fixtures/sf-landmarks.geojson"
FIXTURE_FEATURES=8
WORK="$(mktemp -d)"
# shellcheck disable=SC2317,SC2329  # invoked via trap (SC2317 on shellcheck < 0.10)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

rc=0
run_one() {   # run_one FILE EXPECTED_FEATURES
  local f="$1" n="$2" log ec=0
  log="$WORK/$(basename "$f").log"
  "$CLI" --layer "$f" --layer-db "$WORK/layers-$(basename "$f")" --expect-features "$n" > "$log" 2>&1 || ec=$?
  if [[ "$ec" == 0 ]]; then
    echo "[layer-test] ok   $(basename "$f") ($n feature(s))"
  else
    echo "[layer-test] FAIL $(basename "$f") (exit $ec)"; rc=1
  fi
  sed 's/^/    /' "$log"
}

if [[ $# -ge 1 ]]; then
  for f in "$@"; do run_one "$f" 1; done
else
  run_one "$FIXTURE" "$FIXTURE_FEATURES"
  if command -v ogr2ogr >/dev/null 2>&1; then
    # same features through three more GDAL drivers; shapefiles are single-geometry,
    # so only the points survive the conversion (the OGR driver picks one layer type).
    ogr2ogr -f GPKG "$WORK/sf-landmarks.gpkg" "$FIXTURE" >/dev/null 2>&1 \
      && run_one "$WORK/sf-landmarks.gpkg" "$FIXTURE_FEATURES"
    ogr2ogr -f KML "$WORK/sf-landmarks.kml" "$FIXTURE" >/dev/null 2>&1 \
      && run_one "$WORK/sf-landmarks.kml" "$FIXTURE_FEATURES"
    ogr2ogr -f 'ESRI Shapefile' "$WORK/sf-points.shp" "$FIXTURE" -where "kind = 'poi'" >/dev/null 2>&1 \
      && run_one "$WORK/sf-points.shp" 3
  else
    echo "[layer-test] ogr2ogr not on PATH; GPKG/KML/SHP legs skipped"
  fi
fi

if [[ "$rc" == 0 ]]; then
  echo "[layer-test] PASS: offline layer(s) opened through FeatureDataStore2"
else
  echo "[layer-test] FAIL"
fi
exit "$rc"
