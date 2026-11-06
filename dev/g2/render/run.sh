#!/usr/bin/env bash
#
# G2.1 render smoke: the engine's native renderer (GLGlobe via GLMapView)
# draws into an EGL pbuffer on ANGLE/Metal from a Zulu 8 JVM.
#
# Requires: MACTAK_GLES=angle bash dev/g1/build-native.sh (engine linked
# against ANGLE's libGLESv2, libEGL/libGLESv2 staged in native-dist).
#
# Usage: dev/g2/render/run.sh [--size WxH] [--frames N] [--out FILE.ppm]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render
G2="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$G2/../.." && pwd)"
G1="$ROOT/dev/g1"
DIST="${MACTAK_NATIVE_DIST:-$G1/native-dist}"
DIST="$(cd "$DIST" && pwd)"
VER="${TAKKERNEL_VER:-0.59.1}"
M2="${HOME}/.m2/repository"
OUT="$G2/build/render-classes"

for f in libtakengine.dylib libtakenginejni.dylib libEGL.dylib libGLESv2.dylib; do
  [[ -f "$DIST/$f" ]] || { echo "render/run.sh: $f missing in $DIST — run: MACTAK_GLES=angle bash dev/g1/build-native.sh" >&2; exit 2; }
done
otool -L "$DIST/libtakengine.dylib" | grep -q '@rpath/libGLESv2.dylib' \
  || { echo "render/run.sh: libtakengine is linked against the GLES stub, not ANGLE — rebuild with MACTAK_GLES=angle" >&2; exit 2; }

JDK="${JAVA_HOME:-$("/usr/libexec/java_home" -v 1.8 2>/dev/null || true)}"
[[ -n "$JDK" ]] || { echo "render/run.sh: JDK 1.8 not found" >&2; exit 2; }

# --window: build the M3.1 window-harness host dylib (WindowHost.m) and hand
# its path to the smoke. The harness layer is off-screen, so this needs no
# GUI session — CI runs the same exercise on a runner.
WIN_HOST_ARGS=()
for a in "$@"; do
  if [[ "$a" == "--window" ]]; then
    WIN_HOST="$(bash "$HERE/build-window-host.sh")"
    WIN_HOST_ARGS=(--window-host "$WIN_HOST")
    break
  fi
done

# mavenLocal first, else the committed transplants — same contract as dev/g1.
jar() { if [[ -f "$1" ]]; then echo "$1"; else echo "$2"; fi; }
KERNEL_M2="$M2/gov/tak/kernel"
TRANS="$G1/transplants"
CP="$(jar "$KERNEL_M2/takkernel-engine/$VER/takkernel-engine-$VER.jar" "$TRANS/takkernel-engine-$VER.jar")"
CP="$CP:$(jar "$KERNEL_M2/takkernel-port/$VER/takkernel-port-$VER.jar" "$TRANS/takkernel-port-$VER.jar")"
CP="$CP:$(jar "$KERNEL_M2/takkernel-annotation/$VER/takkernel-annotation-$VER.jar" "$TRANS/takkernel-annotation-$VER.jar")"
CP="$CP:$(jar "$M2/gov/tak/support/android-port/3.1.0/android-port-3.1.0.jar" "$ROOT/dev/spike/g0/transplants/android-port-3.1.0.jar")"
CP="$CP:$(jar "$M2/org/slf4j/slf4j-api/1.7.30/slf4j-api-1.7.30.jar" "$TRANS/slf4j-api-1.7.30.jar")"
CP="$CP:$(jar "$M2/org/slf4j/slf4j-simple/1.7.30/slf4j-simple-1.7.30.jar" "$TRANS/slf4j-simple-1.7.30.jar")"
# com.atakmap.map.EngineLibrary (jre host bootstrap, run from Globe.<clinit>)
# references BouncyCastle; the verifier needs the class even though the BKS
# keystore path is never exercised here. Upstream pin (gradle/versions.gradle)
# is 1.67; fetched from Maven Central into the gitignored build dir, sha256-pinned.
BC_VER=1.67
BC_SHA256=fa0041a36f9f20af3c6b8dbf6eb49a969e2c9cc029049d61acc526ba3247b3ef
BC_JAR="$(jar "$M2/org/bouncycastle/bcprov-jdk15on/$BC_VER/bcprov-jdk15on-$BC_VER.jar" "$G2/build/lib/bcprov-jdk15on-$BC_VER.jar")"
if [[ ! -f "$BC_JAR" ]]; then
  mkdir -p "$(dirname "$BC_JAR")"
  curl -fsSL -o "$BC_JAR.tmp" "https://repo1.maven.org/maven2/org/bouncycastle/bcprov-jdk15on/$BC_VER/bcprov-jdk15on-$BC_VER.jar"
  echo "$BC_SHA256  $BC_JAR.tmp" | shasum -a 256 -c - >/dev/null || { rm -f "$BC_JAR.tmp"; echo "render/run.sh: bcprov checksum mismatch" >&2; exit 2; }
  mv "$BC_JAR.tmp" "$BC_JAR"
fi
CP="$CP:$BC_JAR"
for j in ${CP//:/ }; do
  [[ -f "$j" ]] || { echo "render/run.sh: missing jar: $j" >&2; exit 2; }
done

if [[ ! -d "$OUT" ]] || [[ -n "$(find "$HERE/src" "$G1/headless/src" -name '*.java' -newer "$OUT" -print -quit)" ]]; then
  rm -rf "$OUT"; mkdir -p "$OUT"
  # + dev/g1/headless/src: LayerStore/NativeGdal (G1.3) back the --layer option
  find "$HERE/src" "$G1/headless/src" -name '*.java' -print0 | xargs -0 "$JDK/bin/javac" -source 8 -target 8 -Xlint:all -Werror -encoding UTF-8 \
    -classpath "$CP" -d "$OUT" \
    || { rm -rf "$OUT"; exit 1; }
  touch "$OUT"
fi

# GDAL_DATA for the engine's GdalLibrary::init (Homebrew gdal; override with GDAL_DATA).
GDAL_DATA_DIR="${GDAL_DATA:-$(gdal-config --datadir 2>/dev/null || echo /opt/homebrew/opt/gdal/share/gdal)}"

# $OUT first: it shadows com.atakmap.map.EngineLibrary (the jre/JOGL host
# bootstrap in the engine jar) with the macOS one, and the android.* classes
# whose transplant bodies are "Stub!" (graphics value types, opengl.Matrix,
# os.Environment).
# MACTAK_HOME: android.os.Environment's "external storage" (FileSystemUtils'
# atak/ root); the smoke keeps it in a scratch dir unless the caller sets one.
SCRATCH=""
if [[ -z "${MACTAK_HOME:-}" ]]; then
  SCRATCH="$(mktemp -d)"; export MACTAK_HOME="$SCRATCH"
  trap 'rm -rf "$SCRATCH"' EXIT
fi

"$JDK/bin/java" \
  -classpath "$OUT:$CP" \
  -Djava.library.path="$DIST" \
  -Djava.awt.headless=true \
  -Dmactak.gdal.data="$GDAL_DATA_DIR" \
  -Dorg.slf4j.simpleLogger.defaultLogLevel="${MACTAK_LOG_LEVEL:-warn}" \
  mactak.render.RenderSmoke \
  --lib "$DIST/libtakengine.dylib" \
  --lib "$DIST/libtakenginejni.dylib" \
  --egl "$DIST/libEGL.dylib" --gles "$DIST/libGLESv2.dylib" \
  "$@" \
  ${WIN_HOST_ARGS[@]+"${WIN_HOST_ARGS[@]}"}
