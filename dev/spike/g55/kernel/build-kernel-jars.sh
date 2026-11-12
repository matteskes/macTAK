#!/usr/bin/env bash
#
# JNI step of the 5.5 spike (dev/spike/g55/NOTES.md §JNI glue): the
# takkernel 8.30.5 jars and the JNI headers the 5.5 glue includes.
#
#   <5.5>/takkernel  →  dev/spike/g55/build/kernel/takkernel (copy)
#   + kernel/gradle-public-source-build.patch (public artifacts only, no
#     native hook; javac -h writes the JNI headers, as upstream's
#     generateJniHeaders does)
#   + android-port-3.1.0-g55 (android-port/build-android-port.py) in a
#     private Maven repo, so ~/.m2 is neither read nor written
#   → build/kernel/jars/: takkernel-engine-8.30.5.jar and its resolved
#     runtime classpath (runtime-classpath.gradle): port, annotation,
#     android-port, slf4j, bouncycastle, JOGL, ...
#   → dev/spike/g55/jni-include/*.h (committed, like dev/g1/jni-include:
#     the native build then needs no JDK; commit the diff when it changes)
#
# The jars are upstream's, unpatched: macTAK's Java fixes ship as engine
# shadows (dev/g2/render/engine-shadows), not inside the jar.
#
# usage: build-kernel-jars.sh UPSTREAM_55
#        UPSTREAM_55  root of an atak-civ checkout at 5.5.1.10 (needs
#                     takkernel/ in full)
# needs: JDK 21 (Gradle 8.13) and JDK 8 (the android-port stubs), or
#        G55_JDK21_HOME / G55_JDK8_HOME pointing at them; network
#        for Maven Central and jogamp.org on the first run
# exit:  0 jars and headers written; 1 build failed; 2 usage or preflight
set -euo pipefail

KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # <repo>/dev/spike/g55/kernel
G55="$(cd "$KERNEL_DIR/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../runtime.sh
source "$G55/runtime.sh"
WORK="$G55/build/kernel"
M2="$WORK/m2"
HEADERS="$G55/jni-include"
ANDROID_PORT_VERSION="3.1.0-g55"

log() { printf '\n[g55-kernel] %s\n' "$*"; }
die() { printf '\n[g55-kernel] FATAL: %s\n' "$*" >&2; exit 2; }

[[ $# -eq 1 ]] || die "usage: build-kernel-jars.sh UPSTREAM_55"
UPSTREAM="$(cd "$1" && pwd)" || die "no such directory: $1"
[[ -x "$UPSTREAM/takkernel/gradlew" ]] || die "no takkernel at $UPSTREAM/takkernel"

for t in rsync patch python3; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
GRADLE_JDK="$(g55_jdk_home 21)" || die "JDK 21 not found (Gradle 8.13 runs on it; or set G55_JDK21_HOME)"
G55_JDK8_HOME="$(g55_jdk_home 8)" || die "JDK 8 not found (build-android-port.py compiles with it; or set G55_JDK8_HOME)"
export G55_JDK8_HOME

rm -rf "$WORK"
mkdir -p "$WORK/jars"

log "copying takkernel → $WORK/takkernel"
rsync -a --exclude .git --exclude build --exclude .gradle "$UPSTREAM/takkernel" "$WORK/"

log "applying gradle-public-source-build.patch (--fuzz=0)"
patch --forward --silent --no-backup-if-mismatch --fuzz=0 -p1 -d "$WORK" \
  < "$KERNEL_DIR/gradle-public-source-build.patch" || die "gradle patch failed"

log "android-port $ANDROID_PORT_VERSION → private Maven repo"
python3 "$G55/android-port/build-android-port.py" \
  "$M2/gov/tak/support/android-port/$ANDROID_PORT_VERSION"

log "gradle: annotation, port, engine $G55_KERNEL_VERSION (log: $WORK/gradle.log)"
if ! (cd "$WORK/takkernel" && JAVA_HOME="$GRADLE_JDK" ./gradlew --no-daemon \
        -I "$KERNEL_DIR/runtime-classpath.gradle" -PmacTakRuntimeDir="$WORK/jars" \
        -Dmaven.repo.local="$M2" -PkernelBuildTarget=java \
        :annotation:publishToMavenLocal :port:publishToMavenLocal :engine:publishToMavenLocal \
        :engine:macTakRuntimeJars \
        >"$WORK/gradle.log" 2>&1); then
  grep -E "error:|What went wrong" -A3 "$WORK/gradle.log" | head -n 40 >&2
  log "FAIL: gradle (full log: $WORK/gradle.log)"
  exit 1
fi

cp "$M2/gov/tak/kernel/takkernel-engine/$G55_KERNEL_VERSION/takkernel-engine-$G55_KERNEL_VERSION.jar" "$WORK/jars/"

log "JNI headers → $HEADERS"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp "$WORK/takkernel/engine/build/java/generated/jni/"*.h "$HEADERS/"

jar_count="$(find "$WORK/jars" -name '*.jar' | wc -l | tr -d ' ')"
header_count="$(find "$HEADERS" -name '*.h' | wc -l | tr -d ' ')"
log "PASS: $jar_count jars in $WORK/jars, $header_count headers in $HEADERS"
