#!/usr/bin/env bash
#
# M3.4 gesture canary (InputBridgeSelfTest): the Apple Maps gesture map on
# the engine's own camera, through a 512x512 ANGLE pbuffer at 2x dpi. Drag
# and scroll keep the ground under the pointer; wheel, pinch and
# double-click zoom by their factor about the pointer; rotate turns the
# content about the pointer; option-drag tilts (up) and turns (right). No
# window, so CI's render job runs it; the AppKit half (the shell's event
# handlers) is shell/test/gestures.sh on the dev Mac.
#
# Needs what dev/g2/render/run.sh needs (ANGLE-linked engine, JDK 21).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test

# Build environment: sets DIST OUT JDK CP GDAL_JAVA, compiles if stale.
# shellcheck source-path=SCRIPTDIR source=../env.sh
source "$HERE/../env.sh"

"$JDK/bin/java" \
  -classpath "$OUT:$CP" \
  -Djava.library.path="$DIST:$GDAL_JAVA" \
  -Djava.awt.headless=true \
  -Dorg.slf4j.simpleLogger.defaultLogLevel="${MACTAK_LOG_LEVEL:-warn}" \
  mactak.render.InputBridgeSelfTest \
  --lib "$DIST/libtakengine.dylib" \
  --lib "$DIST/libtakenginejni.dylib" \
  --egl "$DIST/libEGL.dylib" --gles "$DIST/libGLESv2.dylib"
