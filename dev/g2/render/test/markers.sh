#!/usr/bin/env bash
#
# The marker gate (G3.7b; roadmap: "markers' pixels where expected"): the
# map's marker layer (mactak.render.MapMarkers, as the app adds it) draws
# two markers where they are, in the colours ATAK 5.5 gives them:
#
#   - a contact: 5.5's role icon (asset://icons/roles/team.png, a classpath
#     asset) tinted cyan, its team colour
#   - the self marker: 5.5's two self drawables composited and tinted
#     0xff44b2dd under a white outline, loaded as a base64:// URI (which
#     needs G2's android.util.Base64: android-port's is "Stub!")
#
# The pixel over each marker's point must be its colour, and the ground
# between them black (no basemap). The same expectations must then FAIL
# with no markers, so the gate can't pass on an empty map. No base64:// or
# asset:// load may fail.
#
# usage: markers.sh [OUT.png]
# needs: what dev/g2/render/run.sh needs (make build-angle, make gdal-java)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test
ROOT="$(cd "$HERE/../../../.." && pwd)"
OUT="${1:-$ROOT/dev/g2/build/render-markers.png}"
LOG="$(mktemp "${TMPDIR:-/tmp}/markers.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

AT="37.795,-122.445"
CONTACT="37.795,-122.4455"
SELF="37.795,-122.4445"
expects=(--expect "$CONTACT,00ffff" --expect "$SELF,44b2dd" --expect "37.7953,-122.445,000000")

render() { bash "$ROOT/dev/g2/render/run.sh" --size 256x256 --at "$AT" --res 2 "$@" "${expects[@]}" > "$LOG" 2>&1; }

status=0
set +e
render --marker "$CONTACT,asset://icons/roles/team.png,FF00FFFF" --marker "$SELF,self" --out "$OUT"
rc=$?
set -e
grep -E '^render-smoke: ([0-9]+ marker|expect|PASS|FAIL)' "$LOG" | sed 's/^/    /' || true
if [[ "$rc" -ne 0 ]]; then
  echo "[markers] FAIL: the marker render exited $rc" >&2
  tail -30 "$LOG" | sed 's/^/    | /' >&2
  status=1
fi
failed="$(grep -c 'failed to handle URI' "$LOG" || true)"
if [[ "$failed" -ne 0 ]]; then
  echo "[markers] FAIL: $failed icon load(s) failed, e.g.:" >&2
  grep -m3 'failed to handle URI' "$LOG" | cut -c1-160 | sed 's/^/    | /' >&2
  status=1
fi

set +e
render --settle 1000
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "[markers] FAIL: the expectations passed with no markers" >&2
  status=1
fi

[[ "$status" -eq 0 ]] || exit 1
echo "[markers] PASS: both markers drew where they are, in 5.5's colours; with none, the same check fails"
