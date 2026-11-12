#!/usr/bin/env bash
#
# Asset-icon canary: the GeoJSON landmarks render (make test-render's layer
# step, CI's "Render the GeoJSON fixture") with every asset: URI resolved.
# The landmarks' points draw with asset:/icons/reference_point.png, which
# takkernel's desktop jar packages as the classpath resource
# assets/icons/reference_point.png. Before ClasspathAssets the substitute
# Context.getAssets() returned null, every icon load failed ("failed to
# handle URI asset:..." from AsyncBitmapLoader2, 62 times in this render)
# and the engine retried on a new thread each frame; the render still
# passed, because the points simply did not draw. This makes it fail.
#
# The render's own gate (glErrors=0) covers the other half: with the icons
# loading, the point renderer's desktop-GL state (points-es-state-desktop-
# only.patch) raised GL_INVALID_ENUM every frame on ANGLE.
#
# Needs what dev/g2/render/run.sh needs (make build-angle, make gdal-java).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test
ROOT="$(cd "$HERE/../../../.." && pwd)"
OUT="${1:-$ROOT/dev/g2/build/render-layer.png}"
LOG="$(mktemp "${TMPDIR:-/tmp}/asset-icons.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

set +e
bash "$ROOT/dev/g2/render/run.sh" \
  --layer "$ROOT/dev/g1/headless/test/fixtures/sf-landmarks.geojson" --out "$OUT" > "$LOG" 2>&1
rc=$?
set -e
grep -E '^render-smoke: ([0-9]+ frames|sentinel|PASS|FAIL)' "$LOG" | sed 's/^/    /' || true

failed="$(grep -c 'failed to handle URI asset:' "$LOG" || true)"
if [[ "$rc" -ne 0 ]]; then
  echo "[asset-icons] FAIL: the layer render exited $rc" >&2
  tail -30 "$LOG" | sed 's/^/    | /' >&2
  exit 1
fi
if [[ "$failed" -ne 0 ]]; then
  echo "[asset-icons] FAIL: $failed asset: URI load(s) failed, e.g.:" >&2
  grep -m3 'failed to handle URI asset:' "$LOG" | sed 's/^/    | /' >&2
  exit 1
fi
echo "[asset-icons] PASS: every asset: URI resolved from the classpath, and the layer render passed"
