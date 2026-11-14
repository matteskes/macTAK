#!/usr/bin/env bash
#
# G1.9 JNI guard/behavior unit canary — the runner (dev/g1/NOTES.md §G1.9).
#
# The binary (built by dev/g1/build-native.sh into the staged dir) boots a
# real desktop JVM in-process, twice:
#
#   guards mode  — empty classpath: every kernel/Android class lookup
#                  fails, so the wave-5/6 class-init guards must surface
#                  as neutral bailouts and JNI_OnLoad must fail cleanly
#                  (JNI_ERR) instead of dying on a pending exception.
#   kernel mode  — the takkernel jars (dev/g1/kernel/classpath.sh): the
#                  Java-backed IOProviderFactory proxy is installed as
#                  the engine's global Filesystem and must behave on
#                  real files (the getFileCount isDirectory fix) and
#                  bail TE_Err with a clean JNIEnv on real Java failures.
#                  G2's runtime android.net.Uri runs ahead of the jars'
#                  Stub!, as in the app (G1.22).
#
# and a third time under the launcher:
#
#   noslf4j mode — the kernel jars minus slf4j-api: JNI_OnLoad's
#                  ManagedLogger finds no Log class, and native logging
#                  must go quiet instead of crashing the JVM (G1.17).
#
# Skips (exit 0) when no JDK 21 is present — the native build itself needs
# none; CI's native job installs JDK 21 before build-native.sh.
#
# Usage: jni-tests/run.sh [staged-dir]   (default: dev/g1/native-dist)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="$(cd "$HERE/.." && pwd)"       # <repo>/dev/g1
ROOT="$(cd "$DEV/../.." && pwd)"    # <repo>
DIST="${1:-$DEV/native-dist}"
DIST="$(cd "$DIST" && pwd)"

BIN="$DIST/takengine-jni-tests"
[[ -x "$BIN" ]] || { echo "FATAL: $BIN missing — run dev/g1/build-native.sh first" >&2; exit 1; }

# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$ROOT/dev/jdk.sh"
JDK="$(mactak_jdk_home 21 || true)"
if [[ -z "$JDK" ]]; then
  echo "[g1] jni-tests SKIP: no JDK 21 found (the native build needs none; install zulu@21 to run)"
  exit 0
fi
export JAVA_HOME="$JDK"
# kernel mode: where the fixture's System.load finds libtakenginejni.dylib
export TAKJNI_TEST_LIBDIR="$DIST"

# kernel-mode classpath: the takkernel jars, kernel first and
# android-port last (dev/g1/kernel/classpath.sh)
# shellcheck source=SCRIPTDIR/../kernel/classpath.sh
source "$DEV/kernel/classpath.sh"
CP="$(mactak_kernel_classpath)" \
  || { echo "FATAL: no takkernel jars in $MACTAK_KERNEL_DIST — run dev/g1/kernel/build-kernel-jars.sh" >&2; exit 1; }

echo "[g1] jni-tests guards mode (empty classpath: class-init failures are the vector)"
env -u TAKJNI_TEST_CLASSPATH TAKJNI_TEST_MODE=guards \
  "$BIN" --gtest_filter='JniGuards*' --gtest_output=xml:"$DIST/takengine-jni-guards.xml"

echo "[g1] jni-tests kernel mode (takkernel jars, under the java launcher — the smoke's boot)"
CLASSES="$DIST/launcher-classes"
mkdir -p "$CLASSES"
"$JDK/bin/javac" -classpath "$CP" -d "$CLASSES" "$HERE/JniTestsMain.java"
# android-port's android.net.Uri is a Stub! (G2 trap 16), so a kernel pin
# that reaches Uri.parse ran into it. The app runs with G2's runtime Uri
# ahead of android-port, and kernel mode does the same (issue 142 batch 2).
SHIMS="$DIST/launcher-shims"
mkdir -p "$SHIMS"
"$JDK/bin/javac" -d "$SHIMS" "$DEV/../g2/render/src/android/net/Uri.java"
TAKJNI_TEST_MODE=kernel TAKJNI_TEST_CLASSPATH="$CP" \
  "$JDK/bin/java" \
  -classpath "$SHIMS:$CP:$CLASSES" \
  JniTestsMain \
  --gtest_filter='JniKernel*' \
  --gtest_output="xml:$DIST/takengine-jni-kernel.xml"

echo "[g1] jni-tests noslf4j mode (kernel jars minus slf4j-api: the ManagedLogger's Log class cannot load)"
CP_NO_SLF4J="$(tr ':' '\n' <<<"$CP" | grep -v '/slf4j-api-[^/]*\.jar$' | paste -sd: -)"
[[ "$CP_NO_SLF4J" != "$CP" ]] || { echo "FATAL: no slf4j-api jar on the kernel classpath to leave out" >&2; exit 1; }
TAKJNI_TEST_MODE=noslf4j \
  "$JDK/bin/java" \
  -classpath "$CP_NO_SLF4J:$CLASSES" \
  JniTestsMain \
  --gtest_filter='JniNoSlf4j*' \
  --gtest_output="xml:$DIST/takengine-jni-noslf4j.xml"

echo "[g1] jni-tests OK — guards, kernel and noslf4j pins green"
