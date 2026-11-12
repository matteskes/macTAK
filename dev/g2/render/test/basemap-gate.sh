#!/usr/bin/env bash
#
# Negative canary for the render smoke's basemap gate: a basemap that draws
# nothing in the frame must FAIL the smoke, even though a vector layer is
# drawing. Without this the basemap leg could not fail: "content pixels > 0"
# is satisfied by the vector layer alone (23890 of 262144 px in CI), so a
# basemap that never rendered still read PASS.
#
# The basemap here is the same synthetic graticule, built over the Oakland
# hills: east of the camera frame, which RenderSmoke fits to the
# sf-landmarks layer (lon -122.52 .. -122.38 at the default 512x512).
#
# Needs what dev/g2/render/run.sh needs (ANGLE-linked engine, JDK 21, GDAL CLI).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test
G2="$(cd "$HERE/../.." && pwd)"
LAYER="$G2/../g1/headless/test/fixtures/sf-landmarks.geojson"
OFF_FRAME="$G2/build/fixtures/oakland-graticule.mbtiles"
LOG="$(mktemp "${TMPDIR:-/tmp}/basemap-gate.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

bash "$G2/fixtures/make-basemap.sh" "$OFF_FRAME" -122.20 37.72 -122.05 37.87

set +e
bash "$G2/render/run.sh" --basemap "$OFF_FRAME" --layer "$LAYER" > "$LOG" 2>&1
rc=$?
set -e
grep -E '^render-smoke: (basemap|camera|sentinel|FAIL|PASS)' "$LOG" | sed 's/^/    /' || true

if [[ "$rc" -eq 1 ]] && grep -q '^render-smoke: FAIL: basemap attached but' "$LOG"; then
  echo "[basemap-gate] PASS: an off-frame basemap fails the smoke"
else
  echo "[basemap-gate] FAIL: expected exit 1 with 'FAIL: basemap attached but …', got exit $rc" >&2
  exit 1
fi
