#!/usr/bin/env bash
#
# The route render gate (G3.10b; NOTES §G3.10 "the PRs", b): the map's
# marker layer (mactak.render.MapMarkers, as the app adds it) draws a route
# as the app sends it (RouteGraphics): one line through every point in the
# route's colour, its waypoints as 5.5's waypoint icon in that colour, its
# control points as nothing, and the line in 5.5's basic line styles
# (GLPolyline.refreshStyle):
#
#   - a green route, SP -> control point -> VDO: both legs green; green
#     icon pixels just past the first waypoint, where the line isn't; none
#     past the control point
#   - a red dashed line: some of the pixels along it are the gaps
#   - a blue outlined line across a wide white one: a dark edge either side
#     of the blue, where the white would be
#
# The same expectations must then FAIL with the lines solid, no waypoint
# icons and an icon on the control point; and with nothing drawn, so the
# gate can't pass on an empty map.
#
# usage: routes.sh [OUT.png]
# needs: what dev/g2/render/run.sh needs (make build-angle, make gdal-java)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test
ROOT="$(cd "$HERE/../../../.." && pwd)"
OUT="${1:-$ROOT/dev/g2/build/render-routes.png}"
LOG="$(mktemp "${TMPDIR:-/tmp}/routes.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

AT="37.795,-122.445"
WAYPOINT="asset://icons/gugpgpow------.png"   # icon_filters.xml's b-m-p-w
SP="37.7957,-122.4460" CP="37.7957,-122.4450" VDO="37.7947,-122.4450"
GREEN=FF00FF00
expects=(
  # the legs (the second below its VDO's label)
  --expect-run "37.7957,-122.4459,37.7957,-122.4451,00ff00,90,100,64"
  --expect-run "37.7952,-122.4450,37.7950,-122.4450,00ff00,90,100,64"
  # the SP's icon west of the line's end; nothing east of the control point
  --expect-run "37.7957,-122.44602,37.7957,-122.4463,00ff00,15,100,64"
  --expect-run "37.7957,-122.44498,37.7957,-122.4447,00ff00,0,5,64"
  # dashes: gaps along the line
  --expect-run "37.7942,-122.4460,37.7942,-122.4448,ff0000,30,90,64"
  # the outline: dark pixels across the blue line over the white one
  --expect-run "37.79485,-122.4440,37.79515,-122.4440,000000,5,40,128"
)
white=(--polyline "37.7940,-122.4440,37.7960,-122.4440,FFFFFFFF,solid,24")

render() { bash "$ROOT/dev/g2/render/run.sh" --size 256x256 --at "$AT" --res 2 "$@" "${expects[@]}" > "$LOG" 2>&1; }

status=0
set +e
render --polyline "$SP,$CP,$VDO,$GREEN,solid,3" \
  --marker "$SP,$WAYPOINT,$GREEN" --marker "$VDO,$WAYPOINT,$GREEN" \
  --polyline "37.7942,-122.4462,37.7942,-122.4446,FFFF0000,dashed,3" \
  "${white[@]}" --polyline "37.7950,-122.4446,37.7950,-122.4436,FF0000FF,outlined,6" --out "$OUT"
rc=$?
set -e
grep -E '^render-smoke: ([0-9]+ marker|expect|PASS|FAIL)' "$LOG" | sed 's/^/    /' || true
if [[ "$rc" -ne 0 ]]; then
  echo "[routes] FAIL: the route render exited $rc" >&2
  tail -30 "$LOG" | sed 's/^/    | /' >&2
  status=1
fi

# solid lines, no waypoint icons, an icon on the control point: every style
# and icon check must fail
set +e
render --polyline "$SP,$CP,$VDO,$GREEN,solid,3" --marker "$CP,$WAYPOINT,$GREEN" \
  --polyline "37.7942,-122.4462,37.7942,-122.4446,FFFF0000,solid,3" \
  "${white[@]}" --polyline "37.7950,-122.4446,37.7950,-122.4436,FF0000FF,solid,6"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "[routes] FAIL: the expectations passed with plain lines and no waypoints" >&2
  status=1
fi
for want in '#ff0000 +/-64, want 30-90%: FAIL' '#000000 +/-128, want 5-40%: FAIL' \
            '#00ff00 +/-64, want 15-100%: FAIL' '#00ff00 +/-64, want 0-5%: FAIL'; do
  if ! grep -qF -- "$want" "$LOG"; then
    echo "[routes] FAIL: with plain lines, no check said '$want'" >&2
    status=1
  fi
done

# nothing drawn: the legs must fail too
set +e
render --settle 1000
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "[routes] FAIL: the expectations passed with nothing drawn" >&2
  status=1
fi
if [[ "$(grep -cF -- '#00ff00 +/-64, want 90-100%: FAIL' "$LOG")" -ne 2 ]]; then
  echo "[routes] FAIL: with nothing drawn, the two legs' checks didn't both fail" >&2
  status=1
fi

[[ "$status" -eq 0 ]] || exit 1
echo "[routes] PASS: the route drew through its points with its waypoints and no control point, dashed and outlined lines drew as 5.5's; plain, or with nothing drawn, the same checks fail"
