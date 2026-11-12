#!/usr/bin/env bash
#
# Compile-only gate for the headless launcher src (#29). atak-headless
# javacs dev/g1/headless/src at launch, so nothing in CI ever type-checked
# HeadlessCLI.java; this compiles the launcher's exact file set with its
# exact contract (--release 21, -Xlint:all -Werror, same classpath: the
# takkernel jars from dev/g1/kernel-dist, kernel first) into a throwaway
# dir. The commo API classes come in as $1 — a jar or a classes dir:
# native-dist/jcommoncommo.jar locally, a plain javac over the checkout's
# commoncommo/jni/com/atakmap/commoncommo sources in CI (the same set
# build-commo.sh seeds its jar with). No natives needed.
#
# usage: test/compile-gate.sh <commo-api-jar-or-classes-dir>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G1="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$G1/../.." && pwd)"

[[ $# -eq 1 && -e "$1" ]] \
  || { echo "compile-gate: usage: $0 <commo-api-jar-or-classes-dir>" >&2; exit 1; }
COMMO_CP="$1"

# Same classpath as the launcher (atak-headless): the takkernel jars
# (dev/g1/kernel/classpath.sh) and the slf4j-simple binding.
# shellcheck source=SCRIPTDIR/../../kernel/classpath.sh
source "$G1/kernel/classpath.sh"
KERNEL_CP="$(mactak_kernel_classpath)" \
  || { echo "compile-gate: no takkernel jars in $MACTAK_KERNEL_DIST — run $G1/kernel/build-kernel-jars.sh" >&2; exit 1; }
CP="$COMMO_CP:$KERNEL_CP:$G1/transplants/slf4j-simple-1.7.30.jar"

# shellcheck source=SCRIPTDIR/../../../jdk.sh
source "$ROOT/dev/jdk.sh"
JDK="$(mactak_jdk_home 21 || true)"
[[ -n "$JDK" ]] || { echo "compile-gate: JDK 21 not found (dev/jdk.sh)" >&2; exit 1; }

OUT="$(mktemp -d /tmp/mactak-compile-gate.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/classes"    # javac -d does not create it

# The launcher's compile line (atak-headless), verbatim flags and file set —
# the dylibs it also checks for are a launch concern, not a compile one.
"$JDK/bin/javac" --release 21 -Xlint:all -Werror -encoding UTF-8 \
  -classpath "$CP" -d "$OUT/classes" "$HERE"/../src/mactak/headless/*.java

echo "compile-gate: OK ($(cd "$OUT/classes" && find . -name '*.class' | wc -l | tr -d ' ') classes)"
