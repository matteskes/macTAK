#!/usr/bin/env bash
#
# M3.3 live-window gate: the third leg of `make test-shell`. The shell opens
# the GeoJSON + MBTiles stack, and after the first frame the render thread
# keeps the window live: the camera pans every frame for --live ms while the
# shell resizes the window halfway through, on the host's path (setFrameSize
# → the layer's drawableSize at the backing scale → WindowApp.resize → EGL
# surface recreated on the render thread). WindowApp's live gate then
# requires every present to succeed, no GL error, the resize to have reached
# the surface and the content gate to hold at the new size; this script also
# requires the surface's final size to be the one the shell asked for, in
# pixels (points x backing scale), and both PNGs (the first frame and the
# live frame after the resize) to decode, at their surfaces' sizes: the
# shell's AWT-free PNG writer once wrote files no decoder read (trap #59).
#
# Prints the live phase's frame times (interval and render+present p50/p95)
# and keeps them as CSV: dev/g2/build/shell-frames.csv. The 60 fps exit gate
# is G2's last step; M3.3 only logs them.
#
# Opens a real window for ~10 s: a dev-Mac manual gate, like the other legs
# of `make test-shell`. Needs what dev/g2/shell/run.sh needs (make
# build-angle, make gdal-java) and the basemap fixture (make-basemap.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/shell/test
ROOT="$(cd "$HERE/../../../.." && pwd)"
BUILD="$ROOT/dev/g2/build"
LIVE_MS=6000
RESIZE_TO=800x560

bash "$ROOT/dev/g2/fixtures/make-basemap.sh" > /dev/null
mkdir -p "$BUILD"
LOG="$(mktemp "${TMPDIR:-/tmp}/shell-live.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

set +e
bash "$HERE/../run.sh" \
  --basemap "$BUILD/fixtures/sf-graticule.mbtiles" \
  --layer "$ROOT/dev/g1/headless/test/fixtures/sf-landmarks.geojson" \
  --live "$LIVE_MS" --resize-to "$RESIZE_TO" \
  --out "$BUILD/shell-resize.png" --frame-log "$BUILD/shell-frames.csv" \
  > "$LOG" 2>&1
rc=$?
set -e

grep -E '^(mactak-shell: (CAMetalLayer|resized|exiting)|window-app: (window surface|live))' "$LOG" | sed 's/^/    /' || true

fail() { echo "[shell-live] FAIL: $*" >&2; sed 's/^/    | /' "$LOG" | tail -40 >&2; exit 1; }

[[ "$rc" -eq 0 ]] || fail "the shell exited $rc"
grep -q '^window-app: live: PASS' "$LOG" || fail "no 'window-app: live: PASS'"
asked="$(sed -nE 's/^mactak-shell: resized the window to .* \(([0-9]+x[0-9]+) px\)$/\1/p' "$LOG" | tail -1)"
got="$(sed -nE 's/^window-app: live: surface now ([0-9]+x[0-9]+) px.*/\1/p' "$LOG" | tail -1)"
[[ -n "$asked" ]] || fail "the shell never resized the window"
[[ "$got" == "$asked" ]] || fail "the surface ended at ${got:-its first size}, the shell asked for $asked"

# sips (macOS) decodes the PNG or prints <nil> sizes
png_size() { sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}'; }
first="$(sed -nE 's/^mactak-shell: CAMetalLayer .* drawable=([0-9]+x[0-9]+) px.*/\1/p' "$LOG" | head -1)"
[[ "$(png_size "$BUILD/shell-resize.png")" == "$first" ]] || fail "shell-resize.png does not decode at $first"
[[ "$(png_size "$BUILD/shell-resize-live.png")" == "$asked" ]] || fail "shell-resize-live.png does not decode at $asked"
echo "[shell-live] PASS: the window stayed live through a pan and a resize to $asked px"
