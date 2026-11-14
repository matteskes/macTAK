#!/usr/bin/env bash
#
# android.graphics stand-in canary (GraphicsSelfTest, G2 audit finding 7):
#   - BitmapRegionDecoder: open-by-path, decode, recycle, and a failed open,
#     must leave the open-descriptor count where it started (issue 131);
#   - Canvas: save/restore and restoreToCount cover the clip as well as the
#     transform, as on Android (issue 132).
# Pure Java (no natives, no GL), but the stand-ins compile against the
# kernel jars, so it uses the render build environment.
#
# Needs what dev/g2/render/run.sh needs (ANGLE-linked engine, JDK 21).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test

# Build environment: sets DIST OUT JDK CP GDAL_JAVA, compiles if stale.
# shellcheck source-path=SCRIPTDIR source=../env.sh
source "$HERE/../env.sh"

"$JDK/bin/java" \
  -classpath "$OUT:$CP" \
  -Djava.awt.headless=true \
  mactak.render.GraphicsSelfTest
