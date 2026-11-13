#!/usr/bin/env bash
#
# The G2 exit run (`make exit-run`; dev/g2/NOTES.md "The 60 fps gate"): the
# full stack (real imagery + vector + real elevation) in the shell's window
# under the scripted gesture tour, on the dev Mac.
#
#   1. fetch the real data (fixtures/fetch-exit-data.sh: NAIP 2024 imagery
#      and USGS 3DEP elevation, pinned by pixel checksums)
#   2. datum: the 3DEP clip must read as sea level plus the geoid at two
#      flat points (Stow Lake, and a street on Twin Peaks' east slope),
#      through RenderSmoke --expect-height ...,msl; the same window without
#      the NAVD88 stamp must fail it (G2 trap #74)
#   3. a warm-up run, discarded: the first run after a rebuild pays for
#      Metal's pipeline compiles (trap #66)
#   4. the measured run: the shell at its default size on the Retina
#      display, the NAIP basemap, the landmarks and the 3DEP terrain, the
#      10 s tour (shell --tour: pan, zoom, tilt, turn) inside an 11 s live
#      phase
#
# PASS: the live gate (every present succeeded, no GL error, content, and
# the terrain mesh under three rays at the end), every gesture kind reached
# the camera, and ZERO DROPPED FRAMES (no present interval over 25 ms).
# Reported, not gated: fps and interval percentiles, render CPU, the
# longest GC pause, peak resident memory, cold start (launch to the first
# presented frame, and to the first frame with content).
#
# Artifacts in dev/g2/build/: exit-run.txt (the summary), exit-run.log,
# exit-run-frames.csv, exit-run-gc.log, exit-run.png and exit-run-live.png.
#
# Opens a real window for about 40 s in all: a dev-Mac manual gate, not CI.
# Needs what dev/g2/shell/run.sh needs, gdal, and the network for step 1
# (once; the clips are cached).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/shell/test
ROOT="$(cd "$HERE/../../../.." && pwd)"
BUILD="$ROOT/dev/g2/build"
DATA="$BUILD/exit-data"
LANDMARKS="$ROOT/dev/g1/headless/test/fixtures/sf-landmarks.geojson"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/exit-run.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The clip's centre, at 3 m/px: the 1280x960 px window shows 3.8 x 2.9 km of it.
CAMERA=(--at "37.7706,-122.4605" --res 3)
LIVE_MS=11000
# Flat 5x5-cell spots in the 3DEP window, at cell centres (heights NAVD88, metres)
HEIGHTS=(--expect-height "37.7701389,-122.4770833,87.010,msl"
         --expect-height "37.7560648,-122.4510648,247.362,msl")

log() { printf '[exit-run] %s\n' "$*"; }
fail() { log "FAIL: $*" >&2; exit 1; }

log "1. data"
bash "$ROOT/dev/g2/fixtures/fetch-exit-data.sh" "$DATA" | sed 's/^/    /'
NAIP="$DATA/sf-naip-2024.tif"
DEM="$DATA/sf-3dep-13.tif"

log "2. datum: 3DEP heights read as NAVD88 (sea level) plus the geoid"
smoke() {   # smoke LOG RENDER_ARGS... ; the smoke's exit code
  local out="$1"; shift
  set +e
  bash "$ROOT/dev/g2/render/run.sh" "$@" > "$out" 2>&1
  local rc=$?
  set -e
  grep -E '^render-smoke: (height|terrain|PASS|FAIL)' "$out" | sed 's/^/    /' || true
  return "$rc"
}
smoke "$WORK/datum.log" --basemap "$NAIP" --elevation "$DEM" "${CAMERA[@]}" --tilt 45 "${HEIGHTS[@]}" \
  || { tail -25 "$WORK/datum.log" >&2; fail "the stamped 3DEP clip does not read as sea level"; }
log "   control: the window as fetched (no vertical datum) must fail"
if smoke "$WORK/datum-unstamped.log" --elevation "$DATA/3dep-window.tif" "${CAMERA[@]}" --tilt 45 "${HEIGHTS[@]}"; then
  fail "the unstamped window passed: the check cannot tell the datums apart"
fi
grep -q 'FAIL: a height at a known point is wrong' "$WORK/datum-unstamped.log" \
  || fail "the unstamped window failed, but not on --expect-height"

SHELL_ARGS=(--basemap "$NAIP" --layer "$LANDMARKS" --elevation "$DEM" "${CAMERA[@]}"
            --live "$LIVE_MS" --tour)

log "3. warm-up run (discarded)"
set +e
bash "$ROOT/dev/g2/shell/run.sh" "${SHELL_ARGS[@]}" > "$WORK/warm-up.log" 2>&1
log "   exit $?; $(sed -nE 's/^window-app: live: ([0-9]+ frames;.*dropped[^;]*);.*/\1/p' "$WORK/warm-up.log")"
set -e

log "4. measured run"
RUN_LOG="$BUILD/exit-run.log"
GC_LOG="$BUILD/exit-run-gc.log"
rm -f "$GC_LOG"
set +e
bash "$ROOT/dev/g2/shell/run.sh" "${SHELL_ARGS[@]}" \
  --out "$BUILD/exit-run.png" --frame-log "$BUILD/exit-run-frames.csv" \
  --prop "-Xlog:gc*:file=$GC_LOG" > "$RUN_LOG" 2>&1
rc=$?
set -e

field() { sed -nE "$1" "$RUN_LOG" | tail -1; }
frames_line="$(field 's/^window-app: live: ([0-9]+ frames;.*)$/\1/p')"
dropped="$(field 's/^window-app: live: .*dropped \(>25 ms\) ([0-9]+);.*/\1/p')"
gc_max="$(sed -nE 's/.*Pause .* ([0-9.]+)ms$/\1/p' "$GC_LOG" 2>/dev/null | sort -g | tail -1)"
gc_n="$(grep -cE 'Pause .* [0-9.]+ms$' "$GC_LOG" 2>/dev/null || true)"
# ZGC's other way to stall a thread: an allocation waiting for a collection
gc_stalls="$(awk '/Allocation Stalls:/ { for (i = NF - 3; i <= NF; i++) s += $i } END { print s + 0 }' "$GC_LOG" 2>/dev/null || echo '?')"

{
  echo "G2 exit run, $(date '+%Y-%m-%d %H:%M %Z'), $(sysctl -n machdep.cpu.brand_string 2>/dev/null), macOS $(sw_vers -productVersion)"
  echo "commit $(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet HEAD -- dev || echo ' + local changes')"
  echo "data: NAIP 2024 window $(gdalinfo -checksum "$DATA/naip-window.tif" | sed -nE 's/^ *Checksum=([0-9]+)$/\1/p' | tr '\n' ' ')/ 3DEP window $(gdalinfo -checksum "$DATA/3dep-window.tif" | sed -nE 's/^ *Checksum=([0-9]+)$/\1/p')"
  grep -E '^window-app: (cold start|camera|basemap|elevation|[0-9]+ feature)|^mactak-shell: (CAMetalLayer|peak resident)' "$RUN_LOG" || true
  echo "live: $frames_line"
  grep -E '^window-app: live: (dropped frame|terrain|[0-9]+ presented)|^window-app: gestures:|^window-app: live frame .*GL error' "$RUN_LOG" || true
  echo "GC: ${gc_n:-0} pauses, longest ${gc_max:-?} ms, allocation stalls ${gc_stalls} (generational ZGC)"
  echo "shell exit $rc"
} > "$BUILD/exit-run.txt"
sed 's/^/    /' "$BUILD/exit-run.txt"

[[ "$rc" -eq 0 ]] || { tail -40 "$RUN_LOG" | sed 's/^/    | /' >&2; fail "the shell exited $rc (live or gesture gate)"; }
[[ -n "$dropped" ]] || fail "no frame-time line in the run log"
[[ "$dropped" -eq 0 ]] || fail "$dropped dropped frame(s) (present interval > 25 ms)"
log "PASS: full stack, 10 s tour, zero dropped frames ($BUILD/exit-run.txt)"
