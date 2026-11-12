#!/usr/bin/env bash
#
# G2.4b smoke: compile + run GdalJavaSmoke against the staged GDAL Java
# bindings (dev/g2/fetch-gdal-java.sh). Proves org.gdal loads the Homebrew
# libgdal the engine links, GTiff round-trips, and records the GDAL 3
# axis-order behaviour for the engine's SpatialReference construction.
#
# Usage: dev/g2/smoke/run-gdal-java.sh [gdal-java-dist-dir]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/smoke
G2="$(cd "$HERE/.." && pwd)"
DIST="${1:-$G2/gdal-java-dist}"
# Check before cd: under set -e a failed cd hides the message (fetch-angle trap).
[[ -f "$DIST/gdal.jar" && -f "$DIST/libgdalalljni.dylib" ]] \
  || { echo "FATAL: GDAL Java bindings not staged at $DIST — run dev/g2/fetch-gdal-java.sh first" >&2; exit 1; }
DIST="$(cd "$DIST" && pwd)"

# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$G2/../jdk.sh"
JDK="$(mactak_jdk_home 21 || true)"
[[ -n "$JDK" ]] || { echo "run-gdal-java: JDK 21 not found (dev/jdk.sh)" >&2; exit 2; }
command -v gdal-config >/dev/null || { echo "FATAL: gdal-config not found" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$JDK/bin/javac" --release 21 -Xlint:all -Werror -encoding UTF-8 \
  -classpath "$DIST/gdal.jar" -d "$WORK" "$HERE/GdalJavaSmoke.java"

# -Djava.library.path: org.gdal.gdal.gdalJNI's static init System.loadLibrary("gdalalljni")
"$JDK/bin/java" -Djava.library.path="$DIST" -classpath "$WORK:$DIST/gdal.jar" \
  mactak.smoke.GdalJavaSmoke "$(gdal-config --version)" "$WORK"
