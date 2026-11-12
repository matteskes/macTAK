#!/usr/bin/env bash
#
# takkernel's own JVM unit tests (`make test-kernel`): :port:test and
# :shared:test on Gradle 8.13 / JDK 21, in the patched copy
# build-kernel-jars.sh leaves in dev/g1/kernel/build. kernel-tests.gradle
# leaves out what needs the TAK artifactory: the classes that need Android's
# runtime (the android-port substitute is compile-time only) and :shared's
# desktop MIL-STD-2525 glue with its tests.
#
# usage: test-kernel.sh   (after build-kernel-jars.sh)
# out:   dev/g1/kernel/build/takkernel/{port,shared}/build/java/{reports,test-results}
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
# --continue: one run reports both modules' failures
JAVA_HOME="$JDK" ./gradlew --no-daemon --continue -I "$KERNEL_DIR/kernel-tests.gradle" \
  -Dmaven.repo.local="$WORK/m2" -PkernelBuildTarget=java :port:test :shared:test
echo "[g1-kernel-tests] PASS: :port:test :shared:test (artifactory-only code and tests excluded: kernel-tests.gradle)"
