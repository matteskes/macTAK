#!/usr/bin/env bash
#
# G2.1 render smoke: the engine's native renderer (GLGlobe via GLMapView)
# draws into an EGL pbuffer on ANGLE/Metal from a JDK 21 JVM.
#
# Requires: MACTAK_GLES=angle bash dev/g1/build-native.sh (engine linked
# against ANGLE's libGLESv2, libEGL/libGLESv2 staged in native-dist).
#
# Usage: dev/g2/render/run.sh [--size WxH] [--frames N] [--out FILE.ppm]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render

# Build environment: dist checks, JDK, classpath, compile-if-stale (env.sh
# sets DIST OUT JDK CP and the G2/ROOT/G1 anchors; M3.2: shared with
# dev/g2/shell/run.sh so the shell builds the very same classes).
# shellcheck source-path=SCRIPTDIR source=env.sh
source "$HERE/env.sh"

# --window: build the M3.1 window-harness host dylib (WindowHost.m) and hand
# its path to the smoke. The harness layer is off-screen, so this needs no
# GUI session — CI runs the same exercise on a runner.
WIN_HOST_ARGS=()
for a in "$@"; do
  if [[ "$a" == "--window" ]]; then
    WIN_HOST="$(bash "$HERE/build-window-host.sh")"
    WIN_HOST_ARGS=(--window-host "$WIN_HOST")
    break
  fi
done

# RenderSmoke writes --out through ImageIO, which does not create parent
# directories, and dev/g2/build is gitignored — a clean checkout's first
# `--out dev/g2/build/…` (make test-render, CI) would die on the PNG write.
# Make the parent here, before Java runs.
prev=""
for a in "$@"; do
  if [[ "$prev" == "--out" ]]; then mkdir -p "$(dirname "$a")"; fi
  prev="$a"
done

# GDAL_DATA for the engine's GdalLibrary::init (Homebrew gdal; override with GDAL_DATA).
GDAL_DATA_DIR="${GDAL_DATA:-$(gdal-config --datadir 2>/dev/null || echo /opt/homebrew/opt/gdal/share/gdal)}"

# $OUT first: it shadows com.atakmap.map.EngineLibrary (the jre/JOGL host
# bootstrap in the engine jar) with the macOS one, and the android.* classes
# whose transplant bodies are "Stub!" (graphics value types, opengl.Matrix,
# os.Environment).
# MACTAK_HOME: android.os.Environment's "external storage" (FileSystemUtils'
# atak/ root); the smoke keeps it in a scratch dir unless the caller sets one.
SCRATCH=""
if [[ -z "${MACTAK_HOME:-}" ]]; then
  SCRATCH="$(mktemp -d)"; export MACTAK_HOME="$SCRATCH"
  trap 'rm -rf "$SCRATCH"' EXIT
fi

"$JDK/bin/java" \
  -classpath "$OUT:$CP" \
  -Djava.library.path="$DIST:$GDAL_JAVA" \
  -Djava.awt.headless=true \
  -Dmactak.gdal.data="$GDAL_DATA_DIR" \
  -Dorg.slf4j.simpleLogger.defaultLogLevel="${MACTAK_LOG_LEVEL:-warn}" \
  mactak.render.RenderSmoke \
  --lib "$DIST/libtakengine.dylib" \
  --lib "$DIST/libtakenginejni.dylib" \
  --egl "$DIST/libEGL.dylib" --gles "$DIST/libGLESv2.dylib" \
  "$@" \
  ${WIN_HOST_ARGS[@]+"${WIN_HOST_ARGS[@]}"}
