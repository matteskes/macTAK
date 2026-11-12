#!/usr/bin/env bash
#
# Sourced by dev/g2/render/env.sh when MACTAK_RENDER_ENV points here
# (render.sh exports it): the render gates' build environment, on the 5.5
# build instead of the 4.6 one. Sets what the gates read from env.sh (DIST OUT JDK
# CP GDAL_JAVA, plus G2 ROOT G1 ENV_SH_DIR) and compiles the same Java:
#
#   engine shadows  regenerated from the 5.5 engine sources + the 5.5
#                   series' Java hunks (env.sh compiles committed shadows,
#                   gated by make check-engine-shadows; here they are
#                   always fresh, so there is nothing to drift)
#   dev/g2/render/src + dev/g1/headless/src, unchanged
#
# Differences from env.sh: JDK 21 and --release 11 (5.5's jars are Java 11
# bytecode); the 5.5 runtime classpath (kernel/build-kernel-jars.sh, which
# brings its own slf4j and bcprov); -Xlint:-deprecation, because 5.5
# deprecates the FeatureDataStore APIs LayerStore and RenderSmoke use, and
# -Xlint:-this-escape, a JDK 21 lint android.graphics.Matrix trips
# (NOTES.md §Render gates). Needs G55_UPSTREAM (render.sh sets it).

ENV_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../g2/render" && pwd)"   # <repo>/dev/g2/render
G2="$(cd "$ENV_SH_DIR/.." && pwd)"
ROOT="$(cd "$G2/../.." && pwd)"
G1="$ROOT/dev/g1"
G55="$ROOT/dev/spike/g55"
# shellcheck source-path=SCRIPTDIR source=runtime.sh
source "$G55/runtime.sh"
DIST="$G55/build/dist"
VER="$G55_KERNEL_VERSION"
OUT="$G55/build/render/classes"
SHADOW_SRC="$G55/build/render/shadow-src"

render_env_fail() { echo "g55/render-env.sh: $*" >&2; exit 2; }

for f in libtakengine.dylib libtakenginejni.dylib libEGL.dylib libGLESv2.dylib; do
  [[ -f "$DIST/$f" ]] || render_env_fail "$f missing in $DIST — run: G55_GLES=angle bash dev/spike/g55/build-engine.sh UPSTREAM_55"
done
JARS="$G55/build/kernel/jars"
[[ -f "$JARS/takkernel-engine-$VER.jar" ]] || render_env_fail "no 5.5 jars in $JARS — run kernel/build-kernel-jars.sh"
JDK="$(g55_jdk_home 21)" || render_env_fail "no JDK 21 (or set G55_JDK21_HOME)"
[[ -d "${G55_UPSTREAM:-}/takkernel/engine/src/main/java" ]] \
  || render_env_fail "G55_UPSTREAM must name the 5.5 checkout (got '${G55_UPSTREAM:-}')"

# gdal.jar first, as env.sh: android-port carries a GDAL 2.4-era org.gdal.*
GDAL_JAVA="${MACTAK_GDAL_JAVA_DIST:-$G2/gdal-java-dist}"
[[ -f "$GDAL_JAVA/gdal.jar" && -f "$GDAL_JAVA/libgdalalljni.dylib" ]] \
  || render_env_fail "GDAL Java bindings missing in $GDAL_JAVA — run: make gdal-java"
GDAL_JAVA="$(cd "$GDAL_JAVA" && pwd)"
CP="$GDAL_JAVA/gdal.jar:$(g55_kernel_classpath "$JARS")"

# Compiled once per render.sh run (it clears $OUT); every gate after the
# first reuses the classes
[[ -f "$OUT/.compiled" ]] && return 0

# The shadows: each engine class a Java hunk of the 5.5 series touches
rm -rf "$SHADOW_SRC" "$OUT"
mkdir -p "$SHADOW_SRC" "$OUT"
while IFS= read -r rel; do
  mkdir -p "$SHADOW_SRC/$(dirname "$rel")"
  cp "$G55_UPSTREAM/takkernel/engine/src/main/$rel" "$SHADOW_SRC/$rel"
done < <(grep -h '^+++ b/tmp/takeng-src/java/' "$G55"/patches/*.patch | sed -E 's|^\+\+\+ b/tmp/takeng-src/||; s/[[:space:]].*$//' | sort -u)
while IFS= read -r p; do
  patch --forward --silent --no-backup-if-mismatch --fuzz=0 -p3 -d "$SHADOW_SRC" < "$p" \
    || render_env_fail "$(basename "$p") does not apply to the 5.5 engine Java"
done < <(grep -l '^+++ b/tmp/takeng-src/java/' "$G55"/patches/*.patch)

find "$SHADOW_SRC" -name '*.java' -print0 | xargs -0 "$JDK/bin/javac" --release 11 -nowarn -encoding UTF-8 \
  -classpath "$CP" -d "$OUT" \
  || render_env_fail "engine shadows do not compile"
find "$ENV_SH_DIR/src" "$G1/headless/src" -name '*.java' -print0 | xargs -0 "$JDK/bin/javac" --release 11 \
  -Xlint:all,-deprecation,-this-escape -Werror -encoding UTF-8 -classpath "$OUT:$CP" -d "$OUT" \
  || render_env_fail "dev/g2/render/src or dev/g1/headless/src does not compile against 5.5"
touch "$OUT/.compiled"
