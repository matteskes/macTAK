#!/usr/bin/env bash
#
# The kernel's leg of the CoT golden test (`make test-cot-golden`, G3.4):
# takkernel's own CotEvent writes each fixture in dev/g3/test/cot-golden,
# and must write what the expected files say. The Swift leg
# (app/Tests/MacTAKCotTests, `make test-app`) holds the Swift port to the
# same files, so the two agree only if the port writes what the kernel does.
#
# usage: cot-golden.sh   (after dev/g1/kernel/build-kernel-jars.sh)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g3/test
ROOT="$(cd "$HERE/../../.." && pwd)"
KERNEL_DIR="$ROOT/dev/g1/kernel"
WORK="$KERNEL_DIR/build"
# shellcheck source=SCRIPTDIR/../../jdk.sh
source "$ROOT/dev/jdk.sh"

die() { printf '[cot-golden] FATAL: %s\n' "$*" >&2; exit 2; }

[[ -x "$WORK/takkernel/gradlew" ]] || die "no patched takkernel in $WORK — run dev/g1/kernel/build-kernel-jars.sh"
JDK="$(mactak_jdk_home 21)" || die "JDK 21 not found (dev/jdk.sh)"

cd "$WORK/takkernel"
JAVA_HOME="$JDK" ./gradlew --no-daemon -q \
  -I "$KERNEL_DIR/kernel-tests.gradle" -I "$HERE/cot-oracle.gradle" \
  -Dmaven.repo.local="$WORK/m2" -PkernelBuildTarget=java \
  -PmacTakOracleDir="$HERE" -PmacTakGoldenDir="$HERE/cot-golden" \
  :shared:macTakCotOracle
