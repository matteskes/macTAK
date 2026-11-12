#!/usr/bin/env bash
#
# M3.4 gesture gate: the fourth leg of `make test-shell`. The shell opens the
# GeoJSON + MBTiles stack and, after the first frame, posts a scripted
# sequence of real input events into its own window (shell --gestures): a
# drag, a trackpad scroll, mouse-wheel notches, an option-drag up and one to
# the right, and a double-click. They travel the whole path: AppKit's event
# dispatch → MetalView's handlers → WindowApp.input across JNI → the render
# thread's InputBridge → the engine's CameraController. WindowApp's live
# gate requires every kind to have reached the camera and moved it, plus
# its usual presents / GL errors / content checks; frame times and dropped
# frames are reported (G2's 60 fps exit run gates them).
#
# Where each gesture must land on screen is InputBridgeSelfTest's job
# (render/test/input-bridge.sh, CI). Magnify and rotate have no public event
# constructor, so they are not posted here: the self-test covers their
# mapping, a real trackpad their handlers.
#
# Opens a real window for ~10 s: a dev-Mac manual gate. Needs what
# dev/g2/shell/run.sh needs and the basemap fixture (make-basemap.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/shell/test
ROOT="$(cd "$HERE/../../../.." && pwd)"
BUILD="$ROOT/dev/g2/build"

bash "$ROOT/dev/g2/fixtures/make-basemap.sh" > /dev/null
mkdir -p "$BUILD"
LOG="$(mktemp "${TMPDIR:-/tmp}/shell-gestures.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

set +e
bash "$HERE/../run.sh" \
  --basemap "$BUILD/fixtures/sf-graticule.mbtiles" \
  --layer "$ROOT/dev/g1/headless/test/fixtures/sf-landmarks.geojson" \
  --live 7000 --gestures \
  --out "$BUILD/shell-gestures.png" --frame-log "$BUILD/shell-gestures-frames.csv" \
  > "$LOG" 2>&1
rc=$?
set -e

grep -E '^(mactak-shell: (gestures posted|exiting)|window-app: (live|gestures))' "$LOG" | sed 's/^/    /' || true

fail() { echo "[shell-gestures] FAIL: $*" >&2; sed 's/^/    | /' "$LOG" | tail -40 >&2; exit 1; }

[[ "$rc" -eq 0 ]] || fail "the shell exited $rc"
grep -q '^mactak-shell: gestures posted' "$LOG" || fail "the gesture script did not finish"
grep -q '^window-app: gestures: PASS' "$LOG" || fail "no 'window-app: gestures: PASS'"
grep -q '^window-app: live: PASS' "$LOG" || fail "no 'window-app: live: PASS'"
echo "[shell-gestures] PASS: drag, scroll, wheel, option-drag and double-click reached the camera through AppKit"
