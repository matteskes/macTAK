#!/usr/bin/env bash
#
# The kernel's leg of the range and bearing golden test (`make
# test-rab-golden`, G3.8a). Two checks, both from the pin:
#
#   1. The vendored magnetic model is the engine's: app/Sources/CMagnetic's
#      formats/wmm and port/Platform.h, and app/Resources/wmm_cof, must be
#      byte-identical to src/takkernel's.
#   2. 5.5's own GeoCalculations, magnetic north, AngleUtilities and
#      SpanUtilities, on the engine's natives (RabOracle.java), write each
#      expected file in dev/g3/test/rab-golden/expected.
#
# The Swift leg (app/Tests/MacTAKCotTests/RangeBearingTests.swift, make
# test-app) holds the port to the same expected files.
#
# usage: rab-golden.sh [--write]   (after build-kernel-jars.sh and build-native.sh)
#   --write   rewrites the expected files instead of checking them
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g3/test
ROOT="$(cd "$HERE/../../.." && pwd)"
ENGINE="$ROOT/src/takkernel/engine/src/main"
VENDORED="$ROOT/app/Sources/CMagnetic"
GOLDEN="$HERE/rab-golden"
DIST="$ROOT/dev/g1/native-dist"

die() { printf '[rab-golden] FATAL: %s\n' "$*" >&2; exit 2; }

mode="check"
case "${1:-}" in
  --write) mode="write" ;;
  "") ;;
  *) die "usage: rab-golden.sh [--write]" ;;
esac

# 1. the vendored files
for pair in \
  "$ENGINE/cpp/formats/wmm/GeomagnetismLibrary.cpp:$VENDORED/formats/wmm/GeomagnetismLibrary.cpp" \
  "$ENGINE/cpp/formats/wmm/GeomagnetismHeader.h:$VENDORED/formats/wmm/GeomagnetismHeader.h" \
  "$ENGINE/cpp/port/Platform.h:$VENDORED/port/Platform.h" \
  "$ENGINE/res/raw/wmm_cof:$ROOT/app/Resources/wmm_cof"; do
  upstream="${pair%%:*}" ours="${pair#*:}"
  [[ -f "$upstream" ]] || die "no $upstream — check out atak-civ's takkernel into src/"
  cmp -s "$upstream" "$ours" || die "${ours#"$ROOT"/} differs from the engine's ${upstream#"$ROOT"/}"
done
echo "[rab-golden] the vendored magnetic model matches the engine's"

# 2. the oracle
[[ -f "$DIST/libtakengine.dylib" && -f "$DIST/libtakenginejni.dylib" ]] \
  || die "no engine dylibs in $DIST — run dev/g1/build-native.sh"
# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$ROOT/dev/jdk.sh"
JDK="$(mactak_jdk_home 21)" || die "JDK 21 not found (dev/jdk.sh)"
# shellcheck source=SCRIPTDIR/../../g1/kernel/classpath.sh
source "$ROOT/dev/g1/kernel/classpath.sh"
CP="$(mactak_kernel_classpath)" || die "no takkernel jars — run dev/g1/kernel/build-kernel-jars.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$JDK/bin/javac" -classpath "$CP" -d "$WORK/classes" "$HERE/RabOracle.java"
"$JDK/bin/java" -Duser.timezone=UTC -classpath "$CP:$WORK/classes" -Djava.library.path="$DIST" \
  RabOracle "$DIST/libtakengine.dylib" "$DIST/libtakenginejni.dylib" "$ENGINE/res/raw/wmm_cof" \
  "$GOLDEN" "$WORK/expected"

if [[ "$mode" == write ]]; then
  cp "$WORK"/expected/*.tsv "$GOLDEN/expected/"
  echo "[rab-golden] wrote $(find "$WORK/expected" -name '*.tsv' | wc -l | tr -d ' ') expected files"
  exit 0
fi
fail=0
for f in "$WORK"/expected/*.tsv; do
  name="$(basename "$f")"
  if ! diff -u "$GOLDEN/expected/$name" "$f"; then
    echo "[rab-golden] FAIL: $name differs from the kernel's answers" >&2
    fail=1
  fi
done
(( fail == 0 )) || exit 1
echo "[rab-golden] PASS: every expected file is the kernel's"
