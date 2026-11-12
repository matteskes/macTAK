#!/usr/bin/env bash
#
# The G1 load canary (dev/g1/smoke/EngineLoadSmoke.java) on the 5.5 build:
# the 5.5 engine jar and its runtime classpath (kernel/build-kernel-jars.sh)
# plus libtakengine and libtakenginejni (build-engine.sh), in one JVM.
# PASS = Java -> JNI glue -> C++ Database2 -> sqlite -> Java returns 42.
#
# JDK 21: 5.5's desktop jars are Java 11 bytecode (upstream's
# gradle/buildconfig.gradle), so the Zulu 8 that G1 runs on cannot load
# them; 21 is the LTS Gradle already needs.
#
# usage: smoke.sh            (after build-kernel-jars.sh and build-engine.sh)
# exit:  0 PASS; 1 FAIL; 2 missing inputs
set -euo pipefail

G55="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=runtime.sh
source "$G55/runtime.sh"
DEV="$(cd "$G55/../.." && pwd)"
BUILD="$G55/build"
JARS="$BUILD/kernel/jars"
CORE_LIB="$BUILD/cmake/engine-cpp/libtakengine.dylib"
JNI_LIB="$BUILD/cmake/libtakenginejni.dylib"
JDK_VERSION=21

die() { printf '[g55-smoke] FATAL: %s\n' "$*" >&2; exit 2; }

for f in "$CORE_LIB" "$JNI_LIB"; do
  [[ -f "$f" ]] || die "missing $f — run build-engine.sh"
done
[[ -f "$JARS/takkernel-engine-$G55_KERNEL_VERSION.jar" ]] || die "no 5.5 jars in $JARS — run kernel/build-kernel-jars.sh"
JDK="$(g55_jdk_home "$JDK_VERSION")" || die "no JDK $JDK_VERSION (or set G55_JDK${JDK_VERSION}_HOME)"

CP="$(g55_kernel_classpath "$JARS")"
CLASSES="$(mktemp -d)"
trap 'rm -rf "$CLASSES"' EXIT

"$JDK/bin/javac" -classpath "$CP" -d "$CLASSES" "$DEV/g1/smoke/EngineLoadSmoke.java"
if "$JDK/bin/java" -classpath "$CP:$CLASSES" EngineLoadSmoke "$CORE_LIB" "$JNI_LIB"; then
  exit 0
fi
exit 1
