#!/usr/bin/env bash
#
# Sourced by dev/g2/render/run.sh (RenderSmoke, G2.1) and dev/g2/shell/run.sh
# (the M3.2 Swift shell, WindowApp): the one build environment for the render
# side — native dist + ANGLE linkage checks, JDK 8, the classpath
# (mavenLocal-or-transplant jars, sha256-pinned bcprov), and the
# compile-if-stale javac pass over dev/g2/render/src (RenderSmoke, WindowApp,
# the GLES shim), dev/g2/render/engine-shadows and dev/g1/headless/src
# (LayerStore/NativeGdal).
#
# Sets: DIST VER M2 OUT JDK CP GDAL_JAVA (plus G2 ROOT G1 ENV_SH_DIR — the
# sourcing script should use these rather than derive its own). Exports
# nothing: callers add the JVM's GDAL_DATA / MACTAK_HOME themselves.
# Exits (killing the sourcing shell) when the environment is unusable.

# MACTAK_RENDER_ENV: another build's environment script, setting the same
# variables (dev/spike/g55/render-env.sh runs these gates on the 5.5 build).
# Unset, this file is unchanged.
if [[ -n "${MACTAK_RENDER_ENV:-}" ]]; then
  # shellcheck source=/dev/null
  source "$MACTAK_RENDER_ENV"
  return 0
fi

ENV_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render
G2="$(cd "$ENV_SH_DIR/.." && pwd)"                          # <repo>/dev/g2
ROOT="$(cd "$G2/../.." && pwd)"                             # <repo>
G1="$ROOT/dev/g1"
DIST="${MACTAK_NATIVE_DIST:-$G1/native-dist}"
DIST="$(cd "$DIST" && pwd)"
VER="${TAKKERNEL_VER:-0.59.1}"
M2="${HOME}/.m2/repository"
OUT="$G2/build/render-classes"

for f in libtakengine.dylib libtakenginejni.dylib libEGL.dylib libGLESv2.dylib; do
  [[ -f "$DIST/$f" ]] || { echo "render/env.sh: $f missing in $DIST — run: MACTAK_GLES=angle bash dev/g1/build-native.sh" >&2; exit 2; }
done
# Capture, then grep: `otool | grep -q` under pipefail can die of SIGPIPE
# (grep quits on the first match, otool gets EPIPE → exit 141) and read as
# "no match" — the false-failure trap recorded in fetch-angle.sh (G1 trap 2).
linkage="$(otool -L "$DIST/libtakengine.dylib")"
grep -q '@rpath/libGLESv2.dylib' <<<"$linkage" \
  || { echo "render/env.sh: libtakengine is linked against the GLES stub, not ANGLE — rebuild with MACTAK_GLES=angle" >&2; exit 2; }

JDK="${JAVA_HOME:-$("/usr/libexec/java_home" -v 1.8 2>/dev/null || true)}"
[[ -n "$JDK" ]] || { echo "render/env.sh: JDK 1.8 not found" >&2; exit 2; }

# mavenLocal first, else the committed transplants — same contract as dev/g1.
jar() { if [[ -f "$1" ]]; then echo "$1"; else echo "$2"; fi; }
KERNEL_M2="$M2/gov/tak/kernel"
TRANS="$G1/transplants"
# G2.4b: the engine's GDAL classes (GdalLibrary, GdalDatasetProjection2 —
# shadowed under engine-shadows/ for trap #48) import org.gdal. `make
# gdal-java` stages the bindings built against the libgdal the engine links;
# libgdalalljni lives beside the jar — callers add $GDAL_JAVA to
# java.library.path. gdal.jar goes FIRST: android-port-3.1.0.jar carries a
# GDAL 2.4-era org.gdal.* (66 classes, SWIG JNI stubs) that would otherwise
# win class resolution — no OAMS_* constants at compile time, and a gdalJNI
# whose native signatures do not match our libgdalalljni at run time
# (trap #49).
GDAL_JAVA="${MACTAK_GDAL_JAVA_DIST:-$G2/gdal-java-dist}"
[[ -f "$GDAL_JAVA/gdal.jar" && -f "$GDAL_JAVA/libgdalalljni.dylib" ]] \
  || { echo "render/env.sh: GDAL Java bindings missing in $GDAL_JAVA — run: make gdal-java" >&2; exit 2; }
GDAL_JAVA="$(cd "$GDAL_JAVA" && pwd)"
CP="$GDAL_JAVA/gdal.jar"
CP="$CP:$(jar "$KERNEL_M2/takkernel-engine/$VER/takkernel-engine-$VER.jar" "$TRANS/takkernel-engine-$VER.jar")"
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
  # --retry: same rationale as fetch-angle.sh — a single-shot Maven Central
  # fetch flakes CI on a transient 5xx; retry, then let the checksum gate judge.
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "$BC_JAR.tmp" \
    "https://repo1.maven.org/maven2/org/bouncycastle/bcprov-jdk15on/$BC_VER/bcprov-jdk15on-$BC_VER.jar"
  echo "$BC_SHA256  $BC_JAR.tmp" | shasum -a 256 -c - >/dev/null || { rm -f "$BC_JAR.tmp"; echo "render/env.sh: bcprov checksum mismatch" >&2; exit 2; }
  mv "$BC_JAR.tmp" "$BC_JAR"
fi
CP="$CP:$BC_JAR"
# Split on ':' only — ${CP//:/ } also splits on spaces, so a space anywhere
# in $HOME or MACTAK_NATIVE_DIST false-failed the whole classpath check.
IFS=: read -r -a CP_JARS <<< "$CP"
for j in "${CP_JARS[@]}"; do
  [[ -n "$j" ]] || continue
  [[ -f "$j" ]] || { echo "render/env.sh: missing jar: $j" >&2; exit 2; }
done

SHADOWS="$ENV_SH_DIR/engine-shadows"
if [[ ! -d "$OUT" ]] || [[ -n "$(find "$ENV_SH_DIR/src" "$SHADOWS" "$G1/headless/src" -name '*.java' -newer "$OUT" -print -quit)" ]]; then
  rm -rf "$OUT"; mkdir -p "$OUT"
  # engine-shadows/: upstream engine classes carrying a dev/g1/patches hunk
  # (byte-identical to src/ + patch, gated by `make check-engine-shadows`);
  # upstream code is not held to our -Xlint:all -Werror bar.
  # Without upstream src/ that gate SKIPs, so a patch edited without
  # regenerating its shadow is caught only in CI — say so at compile time.
  if [[ ! -d "$ROOT/src/takkernel/engine/src/main/java" ]]; then
    echo "render/env.sh: engine-shadows/ NOT drift-checked (no upstream src/ checkout) — if you edited dev/g1/patches, regenerate the shadow; 'make check-engine-shadows' verifies where src/ exists" >&2
  fi
  find "$SHADOWS" -name '*.java' -print0 | xargs -0 "$JDK/bin/javac" -source 8 -target 8 -nowarn -encoding UTF-8 \
    -classpath "$CP" -d "$OUT" \
    || { rm -rf "$OUT"; exit 1; }
  # + dev/g1/headless/src: LayerStore/NativeGdal (G1.3) back the --layer option
  find "$ENV_SH_DIR/src" "$G1/headless/src" -name '*.java' -print0 | xargs -0 "$JDK/bin/javac" -source 8 -target 8 -Xlint:all -Werror -encoding UTF-8 \
    -classpath "$OUT:$CP" -d "$OUT" \
    || { rm -rf "$OUT"; exit 1; }
  touch "$OUT"
fi