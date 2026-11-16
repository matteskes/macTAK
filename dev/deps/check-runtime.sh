#!/usr/bin/env bash
#
# The relocatable-runtime guard without an app bundle (`make check-runtime`,
# CI's render job; issue #152): stage the built natives the way app/bundle.sh
# does (stage-runtime.py: the engine, its JNI glue, ANGLE, GDAL's Java
# bindings, commo when built, and everything they load) into
# dev/g2/build/runtime/Frameworks, then check-bundle.py: every Mach-O file
# loads only what the directory carries and macOS provides.
#
# CI can't build the app itself (the Swift package targets macOS 27, the
# render job runs on 26), so this is the part of the bundle check that CI
# runs; `make test-app-bundle` runs the app bundle itself on a dev Mac.
#
# Usage: dev/deps/check-runtime.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/deps
ROOT="$(cd "$HERE/../.." && pwd)"
NATIVE="$ROOT/dev/g1/native-dist"
OUT="$ROOT/dev/g2/build/runtime"

roots=()
for f in "$NATIVE"/libtakengine.dylib "$NATIVE"/libtakenginejni.dylib "$NATIVE"/libEGL.dylib "$NATIVE"/libGLESv2.dylib \
         "$ROOT"/dev/g2/gdal-java-dist/libgdalalljni.dylib "$NATIVE"/libcommoncommo.dylib "$NATIVE"/libcommoncommojni.dylib; do
  [[ -f "$f" ]] && roots+=("$f")
done
[[ -f "$NATIVE/libtakengine.dylib" ]] || { echo "[runtime] FAIL: no engine in $NATIVE (run dev/g1/build-native.sh)"; exit 1; }
echo "[runtime] roots: ${roots[*]##*/}"

rm -rf "$OUT"
python3 -I "$HERE/stage-runtime.py" "$OUT/Frameworks" "${roots[@]}"
python3 -I "$HERE/check-bundle.py" "$OUT"
