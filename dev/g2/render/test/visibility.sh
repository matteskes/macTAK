#!/usr/bin/env bash
#
# The Overlay Manager's visibility gate (G3.11b; NOTES §G3.11 "the PRs", b):
# an item hidden in the Overlay Manager leaves the map, and comes back when
# shown, as 5.5's MapItem.setVisible does. The app hides an item by taking
# it off the engine's marker layer (MapMarkerSync sends a hidden item
# nothing, so the layer removes it) and shows it by putting it back; this
# drives that layer the same way, in one session:
#
#   - a marker (the team icon, cyan), a line (orange) and a route's line
#     (green) are drawn;
#   - the marker and the route's line are hidden: their pixels are gone,
#     and the orange line, still shown, is still there;
#   - they are shown again: their pixels are back.
#
# The hidden checks must then FAIL when what is hidden isn't on the map
# (nothing leaves); and every check must fail with nothing drawn, so the
# gate can't pass on an empty map.
#
# usage: visibility.sh [OUT.png]
# needs: what dev/g2/render/run.sh needs (make build-angle, make gdal-java)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test
ROOT="$(cd "$HERE/../../../.." && pwd)"
OUT="${1:-$ROOT/dev/g2/build/render-visibility.png}"
LOG="$(mktemp "${TMPDIR:-/tmp}/visibility.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

AT="37.795,-122.445"
MARKER="37.7957,-122.4457"
# shown: the icon across its middle, the orange line and the green one
shown=(
  --expect-run "37.7957,-122.44585,37.7957,-122.44555,00ffff,15,100,64"
  --expect-run "37.7950,-122.4460,37.7950,-122.4440,ff8000,80,100,64"
  --expect-run "37.7943,-122.4460,37.7943,-122.4440,00ff00,80,100,64"
)
# hidden: no icon and no green; the orange line stays
hidden=(
  --expect-hidden-run "37.7957,-122.44585,37.7957,-122.44555,00ffff,0,5,64"
  --expect-hidden-run "37.7950,-122.4460,37.7950,-122.4440,ff8000,80,100,64"
  --expect-hidden-run "37.7943,-122.4460,37.7943,-122.4440,00ff00,0,5,64"
)
items=(--marker "$MARKER,asset://icons/roles/team.png,FF00FFFF"
       --line "37.7950,-122.4462,37.7950,-122.4438,FFFF8000"
       --polyline "37.7943,-122.4462,37.7943,-122.4438,FF00FF00,solid,6")

render() { bash "$ROOT/dev/g2/render/run.sh" --size 256x256 --at "$AT" --res 2 "$@" "${shown[@]}" "${hidden[@]}" > "$LOG" 2>&1; }

status=0
# marker-0, line-1, line-2 in option order
set +e
render "${items[@]}" --hide marker-0 --hide line-2 --out "$OUT"
rc=$?
set -e
grep -E '^render-smoke: ([0-9]+ marker|expect|hidden|shown|PASS|FAIL)' "$LOG" | sed 's/^/    /' || true
if [[ "$rc" -ne 0 ]]; then
  echo "[visibility] FAIL: the hide and show render exited $rc" >&2
  tail -30 "$LOG" | sed 's/^/    | /' >&2
  status=1
fi

# hiding what isn't there leaves the icon and the green line: the hidden checks must fail
set +e
render "${items[@]}" --hide marker-9 --hide line-9 --settle 1500
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "[visibility] FAIL: the hidden checks passed with nothing hidden" >&2
  status=1
fi
for want in '#00ffff +/-64, want 0-5%: FAIL' '#00ff00 +/-64, want 0-5%: FAIL'; do
  if ! grep -qF -- "$want" "$LOG"; then
    echo "[visibility] FAIL: with nothing hidden, no check said '$want'" >&2
    status=1
  fi
done

# nothing drawn: the shown checks must fail
set +e
render --settle 1000
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "[visibility] FAIL: the checks passed with nothing drawn" >&2
  status=1
fi
for want in '#00ffff +/-64, want 15-100%: FAIL' '#ff8000 +/-64, want 80-100%: FAIL'; do
  if ! grep -qF -- "$want" "$LOG"; then
    echo "[visibility] FAIL: with nothing drawn, no check said '$want'" >&2
    status=1
  fi
done

if [[ "$status" -eq 0 ]]; then
  echo "[visibility] PASS: hidden items leave the map and come back; the checks fail when nothing is hidden or drawn"
fi
exit "$status"
