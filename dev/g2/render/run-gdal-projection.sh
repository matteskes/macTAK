#!/usr/bin/env bash
#
# G2.4 b.2 smoke: the engine's GDAL georeferencing (GdalLibrary.init →
# GdalDatasetProjection2) on GDAL 3 with the trap #48 axis-order patch in
# effect. Shares render/env.sh with the render smoke, so the shadowed
# GdalLibrary/GdalDatasetProjection2 under engine-shadows/ are what runs.
#
# Usage: dev/g2/render/run-gdal-projection.sh
# Requires: make build-angle (native dist) and make gdal-java (org.gdal).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render
# shellcheck source-path=SCRIPTDIR source=env.sh
source "$HERE/env.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export MACTAK_HOME="${MACTAK_HOME:-$SCRATCH}"

"$JDK/bin/java" \
  -classpath "$OUT:$CP" \
  -Djava.library.path="$DIST:$GDAL_JAVA" \
  -Djava.awt.headless=true \
  -Dmactak.gdal.data="$GDAL_DATA_DIR" \
  -Dorg.slf4j.simpleLogger.defaultLogLevel="${MACTAK_LOG_LEVEL:-warn}" \
  mactak.render.GdalProjectionSmoke \
  --lib "$DIST/libtakengine.dylib" \
  --lib "$DIST/libtakenginejni.dylib" \
  --scratch "$SCRATCH"
