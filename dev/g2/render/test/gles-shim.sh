#!/usr/bin/env bash
#
# GLES shim Buffer-contract canary (GlesShimSelfTest): glVertexAttribPointer
# and glVertexAttribIPointer must refuse an array-backed Buffer, as Android
# does, because GL keeps the pointer past the call; glBufferData must still
# take one. Runs on a 16x16 ANGLE pbuffer.
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
  mactak.render.GlesShimSelfTest \
  --lib "$DIST/libtakengine.dylib" \
  --lib "$DIST/libtakenginejni.dylib" \
  --egl "$DIST/libEGL.dylib" --gles "$DIST/libGLESv2.dylib"
