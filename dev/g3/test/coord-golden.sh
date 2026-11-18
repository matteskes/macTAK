#!/usr/bin/env bash
#
# The kernel's leg of the coordinate golden test (`make test-coord-golden`,
# G3.6a). Two oracles, both from the pin:
#
#   1. ATAK 5.5's own CoordinateFormatUtilities (the app's, taken from src/)
#      over the kernel's MGRSPoint, UTMPoint and SpanUtilities writes each
#      fixture in dev/g3/test/coord-golden (CoordOracle.java).
#   2. The engine's own geoid code (formats/wmm, geoid-oracle.cpp) writes
#      app/Resources/egm96-15.grid, which must match the committed file,
#      and the geoid heights at the fixture points.
#
# The Swift leg (app/Tests/MacTAKCotTests/CoordinateTests.swift, make
# test-app) holds the port to the same expected files.
#
# usage: coord-golden.sh [--write]   (after dev/g1/kernel/build-kernel-jars.sh)
#   --write   rewrites the expected files and the grid instead of checking
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g3/test
ROOT="$(cd "$HERE/../../.." && pwd)"
KERNEL_DIR="$ROOT/dev/g1/kernel"
WORK="$KERNEL_DIR/build"
GOLDEN="$HERE/coord-golden"
GRID="$ROOT/app/Resources/egm96-15.grid"
WMM="$ROOT/src/takkernel/engine/src/main/cpp"
APP_PKG="atak/ATAK/app/src/main/java/com/atakmap/coremap/conversions"
PIN="9f6893d"
# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$ROOT/dev/jdk.sh"

die() { printf '[coord-golden] FATAL: %s\n' "$*" >&2; exit 2; }

mode="check"
case "${1:-}" in
  --write) mode="write" ;;
  "") ;;
  *) die "usage: coord-golden.sh [--write]" ;;
esac

[[ -x "$WORK/takkernel/gradlew" ]] || die "no patched takkernel in $WORK — run dev/g1/kernel/build-kernel-jars.sh"
[[ -f "$WMM/formats/wmm/EGM9615.h" ]] || die "no $WMM/formats/wmm — check out atak-civ's takkernel into src/"
JDK="$(mactak_jdk_home 21)" || die "JDK 21 not found (dev/jdk.sh)"

# 5.5's formatter: from src/'s work tree when the sparse checkout has it
# (CI's jvm-tests job), else from its git objects (a local sparse checkout
# leaves the app out).
APP_SRC="$WORK/coord-oracle-app-src"
rm -rf "$APP_SRC"
mkdir -p "$APP_SRC/com/atakmap/coremap/conversions"
for f in CoordinateFormat.java CoordinateFormatUtilities.java; do
  if [[ -f "$ROOT/src/$APP_PKG/$f" ]]; then
    cp "$ROOT/src/$APP_PKG/$f" "$APP_SRC/com/atakmap/coremap/conversions/$f"
  else
    git -C "$ROOT/src" show "$PIN:$APP_PKG/$f" > "$APP_SRC/com/atakmap/coremap/conversions/$f" \
      || die "can't read $APP_PKG/$f from src/ — add it to the sparse checkout"
  fi
done

# 1. the formatter
(
  cd "$WORK/takkernel"
  JAVA_HOME="$JDK" ./gradlew --no-daemon -q \
    -I "$KERNEL_DIR/kernel-tests.gradle" -I "$HERE/coord-oracle.gradle" \
    -Dmaven.repo.local="$WORK/m2" -PkernelBuildTarget=java \
    -PmacTakOracleDir="$HERE" -PmacTakAppSrcDir="$APP_SRC" -PmacTakGoldenDir="$GOLDEN" \
    -PmacTakGoldenMode="$mode" \
    :shared:macTakCoordOracle
)

# 2. the geoid
ORACLE="$WORK/geoid-oracle"
c++ -std=c++17 -O1 -w -I"$WMM" "$HERE/geoid-oracle.cpp" "$WMM/formats/wmm/GeomagnetismLibrary.cpp" -o "$ORACLE"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$ORACLE" grid "$tmp/egm96-15.grid"
heights() { grep -hv '^#' "$GOLDEN/points.tsv" "$GOLDEN/geoid-points.tsv" | grep . | "$ORACLE" heights; }
if [[ "$mode" == write ]]; then
  cp "$tmp/egm96-15.grid" "$GRID"
  heights > "$GOLDEN/expected/geoid.tsv"
  echo "wrote $GRID and $GOLDEN/expected/geoid.tsv"
  exit 0
fi
if ! cmp -s "$tmp/egm96-15.grid" "$GRID"; then
  echo "[coord-golden] FAIL: app/Resources/egm96-15.grid differs from the engine's EGM9615.h — run coord-golden.sh --write"
  exit 1
fi
heights > "$tmp/geoid.tsv"
if ! diff -u "$GOLDEN/expected/geoid.tsv" "$tmp/geoid.tsv"; then
  echo "[coord-golden] FAIL: expected/geoid.tsv differs from the engine's geoid"
  exit 1
fi
echo "[coord-golden] PASS: the grid and the geoid heights are the engine's"
