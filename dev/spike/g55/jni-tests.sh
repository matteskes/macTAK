#!/usr/bin/env bash
#
# G1's JNI guard tests (dev/g1/jni-tests, NOTES §G1.9) against the 5.5
# glue, in G1's two modes:
#
#   guards mode  the test binary boots a JVM with an empty classpath:
#                every kernel class lookup fails, so the class-init
#                guards must bail neutrally and JNI_OnLoad must return
#                JNI_ERR instead of crashing
#   kernel mode  the test module runs under the java launcher with the
#                5.5 classpath: the Java-backed IOProviderFactory proxy
#                must behave on real files and fail cleanly
#
# JDK 21, as smoke.sh (5.5's jars are Java 11 bytecode).
#
# usage: jni-tests.sh        (after build-kernel-jars.sh and build-engine.sh)
# out:   dev/spike/g55/build/dist/takengine-jni-{guards,kernel}.xml
# exit:  0 both modes green; 1 a test failed; 2 missing inputs
set -euo pipefail

G55="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=runtime.sh
source "$G55/runtime.sh"
DEV="$(cd "$G55/../.." && pwd)"
BUILD="$G55/build"
CMAKE_OUT="$BUILD/cmake"
DIST="$BUILD/dist"
JARS="$BUILD/kernel/jars"
JDK_VERSION=21

die() { printf '[g55-jni-tests] FATAL: %s\n' "$*" >&2; exit 2; }

for f in engine-cpp/libtakengine.dylib libtakenginejni.dylib \
         takengine-jni-tests libtakengine-jni-tests-module.dylib; do
  [[ -e "$CMAKE_OUT/$f" ]] || die "missing $CMAKE_OUT/$f — run build-engine.sh"
done
[[ -f "$JARS/takkernel-engine-$G55_KERNEL_VERSION.jar" ]] || die "no 5.5 jars in $JARS — run kernel/build-kernel-jars.sh"
JDK="$(g55_jdk_home "$JDK_VERSION")" || die "no JDK $JDK_VERSION (or set G55_JDK${JDK_VERSION}_HOME)"

# JniTestsMain loads all three dylibs from one directory (TAKJNI_TEST_LIBDIR)
rm -rf "$DIST"
mkdir -p "$DIST/classes"
cp "$CMAKE_OUT/engine-cpp/libtakengine.dylib" "$CMAKE_OUT/libtakenginejni.dylib" \
   "$CMAKE_OUT/takengine-jni-tests" "$DIST/"
cp "$CMAKE_OUT/libtakengine-jni-tests-module.dylib" "$DIST/libtakengine-jni-tests.dylib"

echo "[g55] jni-tests guards mode (empty classpath)"
JAVA_HOME="$JDK" TAKJNI_TEST_MODE=guards \
  "$DIST/takengine-jni-tests" --gtest_filter='JniGuards*' \
  --gtest_output="xml:$DIST/takengine-jni-guards.xml"

echo "[g55] jni-tests kernel mode (5.5 classpath, under the java launcher)"
CP="$(g55_kernel_classpath "$JARS")"
"$JDK/bin/javac" -classpath "$CP" -d "$DIST/classes" "$DEV/g1/jni-tests/JniTestsMain.java"
TAKJNI_TEST_MODE=kernel TAKJNI_TEST_LIBDIR="$DIST" TAKJNI_TEST_CLASSPATH="$CP" \
  "$JDK/bin/java" -classpath "$CP:$DIST/classes" JniTestsMain \
  --gtest_filter='JniKernel*' --gtest_output="xml:$DIST/takengine-jni-kernel.xml"

echo "[g55] jni-tests OK: guards and kernel modes green on 5.5"
