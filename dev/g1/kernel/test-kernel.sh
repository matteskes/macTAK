#!/usr/bin/env bash
#
# takkernel's own JVM unit tests (`make test-kernel`): :port:test on Gradle
# 8.13 / JDK 21, in the patched copy build-kernel-jars.sh leaves in
# dev/g1/kernel/build. port-tests.gradle excludes the classes that need
# Android's runtime (the android-port substitute is compile-time only).
#
# usage: test-kernel.sh   (after build-kernel-jars.sh)
# out:   dev/g1/kernel/build/takkernel/port/build/java/{reports,test-results}
set -euo pipefail

KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # <repo>/dev/g1/kernel
ROOT="$(cd "$KERNEL_DIR/../../.." && pwd)"
# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$ROOT/dev/jdk.sh"
WORK="$KERNEL_DIR/build"

die() { printf '[g1-kernel-tests] FATAL: %s\n' "$*" >&2; exit 2; }

[[ -x "$WORK/takkernel/gradlew" ]] || die "no patched takkernel in $WORK — run dev/g1/kernel/build-kernel-jars.sh"
JDK="$(mactak_jdk_home 21)" || die "JDK 21 not found (dev/jdk.sh)"

cd "$WORK/takkernel"
JAVA_HOME="$JDK" ./gradlew --no-daemon -I "$KERNEL_DIR/port-tests.gradle" \
  -Dmaven.repo.local="$WORK/m2" -PkernelBuildTarget=java :port:test
echo "[g1-kernel-tests] PASS: :port:test (Android-runtime classes excluded: port-tests.gradle)"
