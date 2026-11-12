#!/usr/bin/env bash
#
# G1 Milestone 1 smoke: load the engine in-process from a real JVM and prove
# a JNI round-trip (Java -> libtakenginejni -> libtakengine -> sqlite -> Java).
#
# Usage: smoke/run.sh [native-dist-dir]
# Requires: JDK 21 (dev/jdk.sh finds it) and the takkernel jars
# (dev/g1/kernel/build-kernel-jars.sh → dev/g1/kernel-dist).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="$(cd "$HERE/.." && pwd)"     # <repo>/dev/g1
ROOT="$(cd "$DEV/../.." && pwd)"  # <repo>
DIST="${1:-$DEV/native-dist}"
DIST="$(cd "$DIST" && pwd)"   # System.load needs absolute paths

[[ -f "$DIST/libtakengine.dylib" && -f "$DIST/libtakenginejni.dylib" ]] \
  || { echo "FATAL: dylibs missing in $DIST — run dev/g1/build-native.sh first" >&2; exit 1; }

# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$ROOT/dev/jdk.sh"
JDK="$(mactak_jdk_home 21 || true)"
[[ -n "$JDK" ]] || { echo "FATAL: no JDK 21 found (dev/jdk.sh)" >&2; exit 1; }

# shellcheck source=SCRIPTDIR/../kernel/classpath.sh
source "$DEV/kernel/classpath.sh"
CP="$(mactak_kernel_classpath)" \
  || { echo "FATAL: no takkernel jars in $MACTAK_KERNEL_DIST — run dev/g1/kernel/build-kernel-jars.sh" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$JDK/bin/javac" -classpath "$CP" -d "$WORK" "$HERE/EngineLoadSmoke.java"
"$JDK/bin/java" \
  -classpath "$CP:$WORK" \
  -Djava.library.path="$DIST" \
  EngineLoadSmoke \
  "$DIST/libtakengine.dylib" \
  "$DIST/libtakenginejni.dylib"
