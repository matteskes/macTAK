#!/usr/bin/env bash
#
# Sourced by dev/g2/render/run.sh (RenderSmoke, G2.1) and dev/g2/shell/run.sh
# (the M3.2 Swift shell, WindowApp): the one build environment for the render
# side — native dist + ANGLE linkage checks, JDK 21, the classpath (the
# takkernel jars from dev/g1/kernel-dist, gdal.jar first), and the
# compile-if-stale javac pass over dev/g2/render/src (RenderSmoke, WindowApp,
# the GLES shim), the engine shadows and dev/g1/headless/src
# (LayerStore/NativeGdal).
#
# Engine shadows: macTAK's Java fixes to upstream engine classes ship as
# Java hunks in dev/g1/patches. Each compile regenerates the shadowed classes
# from src/ + those hunks (--fuzz=0) and compiles them ahead of the engine
# jar, so there is no committed copy to drift (dev/spike/g55/NOTES.md
# §Render gates).
#
# Sets: DIST OUT JDK CP GDAL_JAVA (plus G2 ROOT G1 ENV_SH_DIR — the sourcing
# script should use these rather than derive its own). Exports nothing:
# callers add the JVM's GDAL_DATA / MACTAK_HOME themselves.
# Exits (killing the sourcing shell) when the environment is unusable.

ENV_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render
G2="$(cd "$ENV_SH_DIR/.." && pwd)"                          # <repo>/dev/g2
ROOT="$(cd "$G2/../.." && pwd)"                             # <repo>
G1="$ROOT/dev/g1"
DIST="${MACTAK_NATIVE_DIST:-$G1/native-dist}"
DIST="$(cd "$DIST" && pwd)"
OUT="$G2/build/render-classes"
SHADOW_SRC="$G2/build/shadow-src"
ENGINE_JAVA="$ROOT/src/takkernel/engine/src/main"

for f in libtakengine.dylib libtakenginejni.dylib libEGL.dylib libGLESv2.dylib; do
  [[ -f "$DIST/$f" ]] || { echo "render/env.sh: $f missing in $DIST — run: MACTAK_GLES=angle bash dev/g1/build-native.sh" >&2; exit 2; }
done
# Capture, then grep: `otool | grep -q` under pipefail can die of SIGPIPE
# (grep quits on the first match, otool gets EPIPE → exit 141) and read as
# "no match" — the false-failure trap recorded in fetch-angle.sh (G1 trap 2).
linkage="$(otool -L "$DIST/libtakengine.dylib")"
grep -q '@rpath/libGLESv2.dylib' <<<"$linkage" \
  || { echo "render/env.sh: libtakengine is linked against the GLES stub, not ANGLE — rebuild with MACTAK_GLES=angle" >&2; exit 2; }

# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$ROOT/dev/jdk.sh"
JDK="$(mactak_jdk_home 21 || true)"
[[ -n "$JDK" ]] || { echo "render/env.sh: JDK 21 not found (dev/jdk.sh)" >&2; exit 2; }

# G2.4b: the engine's GDAL classes (GdalLibrary, GdalDatasetProjection2 —
# shadowed for trap #48) import org.gdal. `make gdal-java` stages the
# bindings built against the libgdal the engine links; libgdalalljni lives
# beside the jar — callers add $GDAL_JAVA to java.library.path. gdal.jar goes
# FIRST: android-port carries a GDAL 2.4-era org.gdal.* (66 classes, SWIG JNI
# stubs) that would otherwise win class resolution — no OAMS_* constants at
# compile time, and a gdalJNI whose native signatures do not match our
# libgdalalljni at run time (trap #49).
GDAL_JAVA="${MACTAK_GDAL_JAVA_DIST:-$G2/gdal-java-dist}"
[[ -f "$GDAL_JAVA/gdal.jar" && -f "$GDAL_JAVA/libgdalalljni.dylib" ]] \
  || { echo "render/env.sh: GDAL Java bindings missing in $GDAL_JAVA — run: make gdal-java" >&2; exit 2; }
GDAL_JAVA="$(cd "$GDAL_JAVA" && pwd)"
# The takkernel jars and their runtime classpath (kernel first, android-port
# last; it brings slf4j-api and BouncyCastle, which EngineLibrary's verifier
# needs), then slf4j-simple as the binding.
# shellcheck source=SCRIPTDIR/../../g1/kernel/classpath.sh
source "$G1/kernel/classpath.sh"
KERNEL_CP="$(mactak_kernel_classpath)" \
  || { echo "render/env.sh: no takkernel jars in $MACTAK_KERNEL_DIST — run dev/g1/kernel/build-kernel-jars.sh" >&2; exit 2; }
CP="$GDAL_JAVA/gdal.jar:$KERNEL_CP:$G1/transplants/slf4j-simple-1.7.30.jar"

# Recompile when the class dir is missing, a source, a patch or a jar is
# newer than it, or the set of sources and patches changed: a deleted patch
# or source makes nothing newer, and its stale class would stay (G2 trap #70).
INPUT_SET="$(find "$ENV_SH_DIR/src" "$G1/headless/src" -name '*.java'; find "$G1/patches" -maxdepth 1 -name '*.patch')"
INPUT_SET="$(sort <<<"$INPUT_SET")"
if [[ ! -d "$OUT" ]] \
   || [[ "$(cat "$OUT/.input-set" 2>/dev/null)" != "$INPUT_SET" ]] \
   || [[ -n "$(find "$ENV_SH_DIR/src" "$G1/headless/src" -name '*.java' -newer "$OUT" -print -quit)" ]] \
   || [[ -n "$(find "$G1/patches" -maxdepth 1 -name '*.patch' -newer "$OUT" -print -quit)" ]] \
   || [[ -n "$(find "$MACTAK_KERNEL_DIST" "$GDAL_JAVA" -name '*.jar' -newer "$OUT" -print -quit)" ]]; then
  [[ -d "$ENGINE_JAVA/java" ]] \
    || { echo "render/env.sh: no engine Java at $ENGINE_JAVA — the shadows regenerate from src/ (CONTRIBUTING.md, Setup)" >&2; exit 2; }
  rm -rf "$OUT" "$SHADOW_SRC"; mkdir -p "$OUT" "$SHADOW_SRC"
  # The shadows: each engine class a Java hunk of the series touches, copied
  # from src/ and patched as build-native.sh patches the C++ (--fuzz=0)
  while IFS= read -r rel; do
    mkdir -p "$SHADOW_SRC/$(dirname "$rel")"
    cp "$ENGINE_JAVA/$rel" "$SHADOW_SRC/$rel"
  done < <(grep -h '^+++ b/tmp/takeng-src/java/' "$G1"/patches/*.patch | sed -E 's|^\+\+\+ b/tmp/takeng-src/||; s/[[:space:]].*$//' | sort -u)
  while IFS= read -r p; do
    patch --forward --silent --no-backup-if-mismatch --fuzz=0 -p3 -d "$SHADOW_SRC" < "$p" \
      || { echo "render/env.sh: $(basename "$p") does not apply to the engine Java in src/" >&2; rm -rf "$OUT"; exit 2; }
  done < <(grep -l '^+++ b/tmp/takeng-src/java/' "$G1"/patches/*.patch)
  # upstream code is not held to our -Xlint:all -Werror bar
  find "$SHADOW_SRC" -name '*.java' -print0 | xargs -0 "$JDK/bin/javac" --release 21 -nowarn -encoding UTF-8 \
    -classpath "$CP" -d "$OUT" \
    || { rm -rf "$OUT"; exit 1; }
  # + dev/g1/headless/src: LayerStore/NativeGdal (G1.3) back the --layer option
  find "$ENV_SH_DIR/src" "$G1/headless/src" -name '*.java' -print0 | xargs -0 "$JDK/bin/javac" --release 21 -Xlint:all -Werror -encoding UTF-8 \
    -classpath "$OUT:$CP" -d "$OUT" \
    || { rm -rf "$OUT"; exit 1; }
  printf '%s\n' "$INPUT_SET" > "$OUT/.input-set"
  touch "$OUT"
fi
