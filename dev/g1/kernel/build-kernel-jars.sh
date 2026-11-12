#!/usr/bin/env bash
#
# The takkernel 8.30.5 jars and the JNI headers the engine's glue includes,
# built from the public 5.5 source in src/ (no TAK artifactory):
#
#   src/takkernel  →  dev/g1/kernel/build/takkernel (copy)
#   + gradle-public-source-build.patch (public artifacts only, no native
#     hook; javac -h writes the JNI headers, as upstream's
#     generateJniHeaders does)
#   + android-port-3.1.0-g55 (android-port/build-android-port.py) in a
#     private Maven repo, so ~/.m2 is neither read nor written
#   → dev/g1/kernel-dist/: takkernel-engine-8.30.5.jar and its resolved
#     runtime classpath (runtime-classpath.gradle): port, annotation,
#     android-port, slf4j, bouncycastle, JOGL, ... (classpath.sh orders it)
#   → dev/g1/jni-include/*.h (committed: the native build then needs no
#     JDK; CI rebuilds them and fails on a diff)
#
# The jars are upstream's, unpatched: macTAK's Java fixes ship as engine
# shadows that dev/g2/render/env.sh regenerates from dev/g1/patches.
#
# usage: build-kernel-jars.sh
# needs: src/ per CONTRIBUTING.md (takkernel/ in full), JDK 21 (Gradle 8.13;
#        dev/jdk.sh finds it), network for Maven Central and jogamp.org on
#        the first run
# exit:  0 jars and headers written; 1 build failed; 2 usage or preflight
set -euo pipefail

KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # <repo>/dev/g1/kernel
G1="$(cd "$KERNEL_DIR/.." && pwd)"
ROOT="$(cd "$G1/../.." && pwd)"
# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$ROOT/dev/jdk.sh"
# shellcheck source=SCRIPTDIR/classpath.sh
source "$KERNEL_DIR/classpath.sh"
WORK="$KERNEL_DIR/build"
M2="$WORK/m2"
HEADERS="$G1/jni-include"
ANDROID_PORT_VERSION="3.1.0-g55"

log() { printf '\n[g1-kernel] %s\n' "$*"; }
die() { printf '\n[g1-kernel] FATAL: %s\n' "$*" >&2; exit 2; }

[[ $# -eq 0 ]] || die "usage: build-kernel-jars.sh (reads src/)"
[[ -x "$ROOT/src/takkernel/gradlew" ]] || die "no takkernel at $ROOT/src/takkernel — populate src/ per CONTRIBUTING.md (Setup)"
for t in rsync patch python3; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
JDK="$(mactak_jdk_home 21)" || die "JDK 21 not found (dev/jdk.sh); Gradle 8.13 runs on it"

rm -rf "$WORK" "$MACTAK_KERNEL_DIST"
mkdir -p "$WORK" "$MACTAK_KERNEL_DIST"

log "copying takkernel → $WORK/takkernel"
rsync -a --exclude .git --exclude build --exclude .gradle "$ROOT/src/takkernel" "$WORK/"

log "applying gradle-public-source-build.patch (--fuzz=0)"
patch --forward --silent --no-backup-if-mismatch --fuzz=0 -p1 -d "$WORK" \
  < "$KERNEL_DIR/gradle-public-source-build.patch" || die "gradle patch failed"

log "android-port $ANDROID_PORT_VERSION → private Maven repo"
JAVAC="$JDK/bin/javac" python3 "$KERNEL_DIR/android-port/build-android-port.py" \
  "$M2/gov/tak/support/android-port/$ANDROID_PORT_VERSION"

log "gradle: annotation, port, engine $MACTAK_KERNEL_VERSION (log: $WORK/gradle.log)"
if ! (cd "$WORK/takkernel" && JAVA_HOME="$JDK" ./gradlew --no-daemon \
        -I "$KERNEL_DIR/runtime-classpath.gradle" -PmacTakRuntimeDir="$MACTAK_KERNEL_DIST" \
        -Dmaven.repo.local="$M2" -PkernelBuildTarget=java \
        :annotation:publishToMavenLocal :port:publishToMavenLocal :engine:publishToMavenLocal \
        :engine:macTakRuntimeJars \
        >"$WORK/gradle.log" 2>&1); then
  grep -E "error:|What went wrong" -A3 "$WORK/gradle.log" | head -n 40 >&2
  log "FAIL: gradle (full log: $WORK/gradle.log)"
  exit 1
fi

cp "$M2/gov/tak/kernel/takkernel-engine/$MACTAK_KERNEL_VERSION/takkernel-engine-$MACTAK_KERNEL_VERSION.jar" "$MACTAK_KERNEL_DIST/"

log "JNI headers → $HEADERS"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp "$WORK/takkernel/engine/build/java/generated/jni/"*.h "$HEADERS/"

jar_count="$(find "$MACTAK_KERNEL_DIST" -name '*.jar' | wc -l | tr -d ' ')"
header_count="$(find "$HEADERS" -name '*.h' | wc -l | tr -d ' ')"
log "PASS: $jar_count jars in $MACTAK_KERNEL_DIST, $header_count headers in $HEADERS"
