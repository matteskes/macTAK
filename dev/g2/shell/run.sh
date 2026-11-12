#!/usr/bin/env bash
#
# G2 M3.2 shell run: build + launch the Swift/AppKit shell (dev/g2/shell) —
# the process that starts the JVM in-process through libjli, opens an
# NSWindow over a CAMetalLayer, and upcalls WindowApp.start; the JVM's
# render thread drives the engine into the layer on ANGLE/Metal. After the
# first frame the window stays live (M3.3): it resizes, follows the
# display's backing scale and pauses while occluded; gestures are M3.4.
# The JVM runs generational ZGC (sub-millisecond pauses: smooth frames,
# dev/g2/NOTES.md "The rest of G2 — decided 2026-11-12").
#
# The run opens a real window (auto-closes --linger ms after the frame, or
# stays up with --wait), so it needs a GUI session — a dev-Mac manual gate
# (`make test-shell`); CI compiles the shell only (build-shell.sh).
#
# Usage: dev/g2/shell/run.sh [--compile-only] [same flags as the shell:
#   --size WxH --frames N --settle MS --linger MS --wait --out FILE.png
#   --layer FILE --basemap FILE --layer-db DIR --res M --at LAT,LON
#   --live MS --resize-to WxH --frame-log FILE.csv]
# Prereqs: MACTAK_GLES=angle engine (dev/g1/build-native.sh), staged ANGLE
#   (dev/g2/fetch-angle.sh) — the same as render/run.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/shell

COMPILE_ONLY=0
SHELL_ARGS=()
for a in "$@"; do
  case "$a" in
    --compile-only) COMPILE_ONLY=1 ;;
    *) SHELL_ARGS+=("$a") ;;
  esac
done

BIN="$(bash "$HERE/build-shell.sh")"
if [[ "$COMPILE_ONLY" = 1 ]]; then
  echo "run.sh: compile-only OK ($BIN)"
  exit 0
fi

# Build environment shared with dev/g2/render/run.sh: dist checks, JDK,
# classpath, compile-if-stale over dev/g2/render/src — WindowApp.class and
# RenderSmoke.class come from the same javac pass (env.sh sets DIST OUT CP
# JDK and the G2/ROOT/G1 anchors).
# shellcheck source-path=SCRIPTDIR source=../render/env.sh
source "$HERE/../render/env.sh"

# WindowApp writes --out through ImageIO, which does not create parent
# directories; make the parent before the shell runs (same as render/run.sh).
prev=""
for a in "${SHELL_ARGS[@]}"; do
  if [[ "$prev" == "--out" ]]; then mkdir -p "$(dirname "$a")"; fi
  prev="$a"
done

# GDAL_DATA for the engine's GdalLibrary::init (Homebrew gdal; override with GDAL_DATA).
GDAL_DATA_DIR="${GDAL_DATA:-$(gdal-config --datadir 2>/dev/null || echo /opt/homebrew/opt/gdal/share/gdal)}"

# MACTAK_HOME: android.os.Environment's "external storage" (FileSystemUtils'
# atak/ root); the shell keeps it in a scratch dir unless the caller sets one.
SCRATCH=""
if [[ -z "${MACTAK_HOME:-}" ]]; then
  SCRATCH="$(mktemp -d)"; export MACTAK_HOME="$SCRATCH"
  trap 'rm -rf "$SCRATCH"' EXIT
fi

# The in-process JVM is the JDK that compiled the classes (env.sh's JDK 21):
# jni_boot.c boots $JAVA_HOME's libjli, and an inherited JDK 8 there would
# refuse the --release 21 classes.
export JAVA_HOME="$JDK"

# Not exec: the EXIT trap above must still run to remove the scratch
# MACTAK_HOME. The shell's exit status (WindowApp's code) becomes ours.
set +e
"$BIN" \
  --classpath "$OUT:$CP" \
  --lib "$DIST/libtakengine.dylib" \
  --lib "$DIST/libtakenginejni.dylib" \
  --egl "$DIST/libEGL.dylib" --gles "$DIST/libGLESv2.dylib" \
  --prop "-Djava.library.path=$DIST:$GDAL_JAVA" \
  --prop "-Djava.awt.headless=true" \
  --prop "-XX:+UseZGC" --prop "-XX:+ZGenerational" \
  --prop "-Dmactak.gdal.data=$GDAL_DATA_DIR" \
  --prop "-Dorg.slf4j.simpleLogger.defaultLogLevel=${MACTAK_LOG_LEVEL:-warn}" \
  ${SHELL_ARGS[@]+"${SHELL_ARGS[@]}"}
exit $?
