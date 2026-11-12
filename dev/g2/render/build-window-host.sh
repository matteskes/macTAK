#!/usr/bin/env bash
#
# Build the M3.1 window-harness host dylib: dev/g2/render/WindowHost.m →
# dev/g2/build/window-host.dylib (rebuilt when stale), then print its path
# (run.sh captures it and hands it to RenderSmoke --window-host; the dylib
# is System.load'ed by mactak.render.WindowHost).
#
# Compiling needs no GUI session — this is the CI gate (the run that opens
# the window is `make test-render-window` on the dev Mac, same split as
# M3.0's compile-only smoke-window).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # dev/g2/render
G2="$(cd "$HERE/.." && pwd)"
OUT="$G2/build/window-host.dylib"

# JDK 21's JNI headers (dev/jdk.sh: MACTAK_JDK21_HOME, a JDK 21 JAVA_HOME,
# setup-java's JAVA_HOME_21_AARCH64, then java_home), loudly when none.
# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$G2/../jdk.sh"
JDK="$(mactak_jdk_home 21 || true)"
[[ -n "$JDK" ]] || { echo "build-window-host.sh: JDK 21 not found (dev/jdk.sh)" >&2; exit 2; }
[[ -d "$JDK/include" ]] \
  || { echo "build-window-host.sh: $JDK has no include/ — JNI headers missing" >&2; exit 2; }

# WindowHost.m's mtime alone misses two stale-dylib cases: edits to this
# script (flags), and a switched JDK (its jni.h differs). Compare both too —
# both comparisons are < 2s apart from a real rebuild.
if [[ ! -f "$OUT" ]] || [[ "$HERE/WindowHost.m" -nt "$OUT" ]] \
   || [[ "$0" -nt "$OUT" ]] || [[ "$JDK/include/jni.h" -nt "$OUT" ]]; then
  mkdir -p "$(dirname "$OUT")"
  clang -ObjC -fobjc-arc -dynamiclib \
    -I"$JDK/include" -I"$JDK/include/darwin" \
    -framework Foundation -framework AppKit -framework QuartzCore -framework Metal \
    -o "$OUT" "$HERE/WindowHost.m"
fi

echo "$OUT"