#!/usr/bin/env bash
#
# The line and click gate (G3.8b; NOTES §G3.8 "the PRs", b): the map's
# marker layer (mactak.render.MapMarkers, as the app adds it) draws a line
# where it is, and a click comes back as the place or marker under it:
#
#   - a 3 px orange line across the frame: the pixels over two points on it
#     are orange, the ground beside it black (no basemap)
#   - a click on a point's pixel comes back as that point (MapPick, the
#     scene model's inverse), within a pixel's worth of ground
#   - a click beside a marker picks it (MapMarkers.markerAt); one on bare
#     ground picks none
#
# The same expectations must then FAIL with no line and no marker, so the
# gate can't pass on an empty map.
#
# usage: lines.sh [OUT.png]
# needs: what dev/g2/render/run.sh needs (make build-angle, make gdal-java)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test
ROOT="$(cd "$HERE/../../../.." && pwd)"
OUT="${1:-$ROOT/dev/g2/build/render-lines.png}"
LOG="$(mktemp "${TMPDIR:-/tmp}/lines.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

AT="37.795,-122.445"
MARKER="37.7946,-122.4452"
expects=(--expect "37.795,-122.4456,ff8000" --expect "37.795,-122.4444,ff8000" --expect "37.7953,-122.445,000000"
         --expect-ground "$AT" --expect-ground "37.7946,-122.4441"
         --expect-marker "$MARKER,marker-0" --expect-marker "37.7954,-122.4441,none")

render() { bash "$ROOT/dev/g2/render/run.sh" --size 256x256 --at "$AT" --res 2 "$@" "${expects[@]}" > "$LOG" 2>&1; }

status=0
set +e
render --marker "$MARKER,asset://icons/roles/team.png,FF00FFFF" --line "37.795,-122.4462,37.795,-122.4438,FFFF8000" --out "$OUT"
rc=$?
set -e
grep -E '^render-smoke: ([0-9]+ marker|expect|pick|click|PASS|FAIL)' "$LOG" | sed 's/^/    /' || true
if [[ "$rc" -ne 0 ]]; then
  echo "[lines] FAIL: the line render exited $rc" >&2
  tail -30 "$LOG" | sed 's/^/    | /' >&2
  status=1
fi

set +e
render --settle 1000
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "[lines] FAIL: the expectations passed with no line and no marker" >&2
  status=1
fi
for want in 'want #ff8000: FAIL' 'want marker-0: FAIL'; do
  if ! grep -qF -- "$want" "$LOG"; then
    echo "[lines] FAIL: with nothing drawn, no check said '$want'" >&2
    status=1
  fi
done

[[ "$status" -eq 0 ]] || exit 1
echo "[lines] PASS: the line drew where it is, clicks came back as the place and the marker; with neither, the same checks fail"
