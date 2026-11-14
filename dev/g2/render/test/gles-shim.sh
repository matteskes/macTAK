#!/usr/bin/env bash
#
# GLES shim canary (GlesShimSelfTest). Buffer contract: glVertexAttribPointer
# and glVertexAttribIPointer must refuse an array-backed Buffer, as Android
# does, because GL keeps the pointer past the call; glBufferData must still
# take one. Bounds (issue 133): every Java (array, offset) entry point
# throws IllegalArgumentException, as Android does, for a negative offset or
# an array too short from the offset. Runs on a 16x16 ANGLE pbuffer.
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
