#!/usr/bin/env bash
#
# Stage commo for the Swift package (G3.1, `make test-app-comms`): copy
# dev/g1/native-dist/libcommoncommo.dylib (dev/g1/build-commo.sh) to
# app/.build/commo/, with its install name changed to
# @rpath/libcommoncommo.dylib, and print that directory.
#
# build-commo.sh names the dylib @loader_path/libcommoncommo.dylib, which
# is right next to the JNI library but makes a Swift binary look for commo
# in its own directory. With @rpath, Package.swift's -rpath finds the staged
# copy. G1's copy is left as it is.
#
# Package.swift adds the comms targets only when MACTAK_COMMO_LIB names this
# directory, so `make test-app` and CI's shell job still build without
# commo.
#
# Usage: app/stage-commo.sh   (MACTAK_COMMO_DIST overrides the source dir)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/app
REPO="$(cd "$HERE/.." && pwd)"
DIST="${MACTAK_COMMO_DIST:-$REPO/dev/g1/native-dist}"
SRC="$DIST/libcommoncommo.dylib"
HEADERS="$REPO/src/commoncommo/core/include/commo.h"
STAGE="$HERE/.build/commo"

[[ -f "$SRC" ]] || { echo "stage-commo.sh: no $SRC — run dev/g1/build-commo.sh first" >&2; exit 1; }
[[ -f "$HEADERS" ]] || { echo "stage-commo.sh: no $HEADERS — check out the pinned atak-civ tree in src/" >&2; exit 1; }

mkdir -p "$STAGE"
if [[ ! "$STAGE/libcommoncommo.dylib" -nt "$SRC" ]]; then
  cp -f "$SRC" "$STAGE/libcommoncommo.dylib"
  install_name_tool -id "@rpath/libcommoncommo.dylib" "$STAGE/libcommoncommo.dylib" 2>/dev/null
  # install_name_tool invalidates the signature, and arm64 refuses unsigned dylibs.
  codesign --force --sign - "$STAGE/libcommoncommo.dylib" >/dev/null 2>&1 \
    || { echo "stage-commo.sh: ad-hoc codesign failed" >&2; exit 1; }
fi
echo "$STAGE"
