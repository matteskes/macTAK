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

JDK="$(/usr/libexec/java_home -v 1.8 2>/dev/null || true)"
[[ -n "$JDK" ]] || { echo "build-window-host.sh: JDK 1.8 not found" >&2; exit 2; }

if [[ ! -f "$OUT" ]] || [[ "$HERE/WindowHost.m" -nt "$OUT" ]]; then
  mkdir -p "$(dirname "$OUT")"
  clang -ObjC -dynamiclib \
    -I"$JDK/include" -I"$JDK/include/darwin" \
    -framework Foundation -framework AppKit -framework QuartzCore -framework Metal \
    -o "$OUT" "$HERE/WindowHost.m"
fi

echo "$OUT"