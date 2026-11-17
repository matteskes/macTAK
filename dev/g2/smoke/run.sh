#!/usr/bin/env bash
#
# G2 spike smoke: build + run egl-triangle against the staged ANGLE runtime.
# Proves EGL display (Metal) → pbuffer → ES3 context → draw → readback.
#
# Usage: dev/g2/smoke/run.sh [angle-dist-dir]
# Requires: dev/g2/fetch-angle.sh has staged libEGL/libGLESv2 (or pass a dir).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/smoke
G2="$(cd "$HERE/.." && pwd)"                           # <repo>/dev/g2
ROOT="$(cd "$G2/../.." && pwd)"                        # <repo>
ANGLE="${1:-$G2/angle-dist}"
# Check the dir BEFORE cd'ing into it: under set -e a failed cd aborts with
# a bare "cd: no such file" and the helpful message below never shows.
[[ -d "$ANGLE" ]] \
  || { echo "FATAL: ANGLE distribution not found at $ANGLE — run dev/g2/fetch-angle.sh first" >&2; exit 1; }
ANGLE="$(cd "$ANGLE" && pwd)"
KHR="$ROOT/src/khronos"

[[ -f "$ANGLE/libEGL.dylib" && -f "$ANGLE/libGLESv2.dylib" ]] \
  || { echo "FATAL: ANGLE missing in $ANGLE — run dev/g2/fetch-angle.sh first" >&2; exit 1; }
[[ -f "$KHR/EGL/api/EGL/egl.h" && -f "$KHR/OpenGL/api/GLES3/gl3.h" ]] \
  || { echo "FATAL: khronos headers missing under $KHR — src/ is the sparse upstream clone, not submodules; see CONTRIBUTING.md Setup" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

clang -arch arm64 -O1 -Wall \
  -I"$KHR/EGL/api" -I"$KHR/OpenGL/api" \
  -o "$WORK/egl-triangle" "$HERE/egl-triangle.c" \
  -L"$ANGLE" -lEGL -lGLESv2 -Wl,-rpath,"$ANGLE"

OUT_PPM="${MACTAK_SMOKE_PPM:-}"
"$WORK/egl-triangle" ${OUT_PPM:+"$OUT_PPM"}
