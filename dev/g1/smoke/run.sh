#!/usr/bin/env bash
#
# G1 Milestone 1 smoke: load the engine in-process from a real JVM and prove
# a JNI round-trip (Java -> libtakenginejni -> libtakengine -> sqlite -> Java).
#
# Usage: smoke/run.sh [native-dist-dir]
# Requires: JDK 21 (dev/jdk.sh finds it). takkernel jars resolve from mavenLocal first,
# else the committed transplants (dev/g1/transplants — the CI native job's
# path; it has no mavenLocal).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="$(cd "$HERE/.." && pwd)"     # <repo>/dev/g1
ROOT="$(cd "$DEV/../.." && pwd)"  # <repo>
DIST="${1:-$DEV/native-dist}"
DIST="$(cd "$DIST" && pwd)"   # System.load needs absolute paths
VER="${TAKKERNEL_VER:-0.59.1}"
M2="${HOME}/.m2/repository"

[[ -f "$DIST/libtakengine.dylib" && -f "$DIST/libtakenginejni.dylib" ]] \
  || { echo "FATAL: dylibs missing in $DIST — run dev/g1/build-native.sh first" >&2; exit 1; }

# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$ROOT/dev/jdk.sh"
JDK="$(mactak_jdk_home 21 || true)"
[[ -n "$JDK" ]] || { echo "FATAL: no JDK 21 found (dev/jdk.sh)" >&2; exit 1; }

# Classpath: mavenLocal jars when present (local gradle builds), else the
# committed transplants (dev/g1/transplants — what CI's native job uses; it
# has no mavenLocal). android-port lives at its G0 home.
jar() { # jar <mavenLocal-path> <committed-path> — prints the first that exists
  if [[ -f "$1" ]]; then echo "$1"; else echo "$2"; fi
}
KERNEL_M2="$M2/gov/tak/kernel"
TRANS="$DEV/transplants"
CP="$(jar "$KERNEL_M2/takkernel-engine/$VER/takkernel-engine-$VER.jar" \
        "$TRANS/takkernel-engine-$VER.jar")"
CP="$CP:$(jar "$KERNEL_M2/takkernel-port/$VER/takkernel-port-$VER.jar" \
        "$TRANS/takkernel-port-$VER.jar")"
CP="$CP:$(jar "$KERNEL_M2/takkernel-annotation/$VER/takkernel-annotation-$VER.jar" \
        "$TRANS/takkernel-annotation-$VER.jar")"
CP="$CP:$(jar "$M2/gov/tak/support/android-port/3.1.0/android-port-3.1.0.jar" \
        "$ROOT/dev/spike/g0/transplants/android-port-3.1.0.jar")"  # android.* stubs
for j in $(echo "$CP" | tr ':' '\n'); do
  [[ -f "$j" ]] || { echo "FATAL: missing jar: $j" >&2
    echo "       run: ./gradlew publishToMavenLocal (engine, port, annotation)" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$JDK/bin/javac" -classpath "$CP" -d "$WORK" "$HERE/EngineLoadSmoke.java"
"$JDK/bin/java" \
  -classpath "$CP:$WORK" \
  -Djava.library.path="$DIST" \
  EngineLoadSmoke \
  "$DIST/libtakengine.dylib" \
  "$DIST/libtakenginejni.dylib"
