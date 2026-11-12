#!/usr/bin/env bash
#
# Compile-only gate for the headless launcher src (#29). atak-headless
# javacs dev/g1/headless/src at launch, so nothing in CI ever type-checked
# HeadlessCLI.java; this compiles the launcher's exact file set with its
# exact contract (--release 21, -Xlint:all -Werror, same classpath:
# mavenLocal first, committed transplants as fallback) into a throwaway
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

# Same classpath resolution as the launcher (atak-headless): mavenLocal
# first, else the committed transplants.
jar() { if [[ -f "$1" ]]; then echo "$1"; else echo "$2"; fi; }
VER="${TAKKERNEL_VER:-0.59.1}"
M2="${HOME}/.m2/repository"
KERNEL_M2="$M2/gov/tak/kernel"
TRANS="$G1/transplants"
CP="$COMMO_CP"
CP="$CP:$(jar "$KERNEL_M2/takkernel-engine/$VER/takkernel-engine-$VER.jar" "$TRANS/takkernel-engine-$VER.jar")"
CP="$CP:$(jar "$KERNEL_M2/takkernel-port/$VER/takkernel-port-$VER.jar" "$TRANS/takkernel-port-$VER.jar")"
CP="$CP:$(jar "$KERNEL_M2/takkernel-annotation/$VER/takkernel-annotation-$VER.jar" "$TRANS/takkernel-annotation-$VER.jar")"
CP="$CP:$(jar "$M2/gov/tak/support/android-port/3.1.0/android-port-3.1.0.jar" \
            "$ROOT/dev/spike/g0/transplants/android-port-3.1.0.jar")"
# com.atakmap.coremap.log.Log (java target) logs through slf4j; 1.7.30 is upstream's pin.
CP="$CP:$(jar "$M2/org/slf4j/slf4j-api/1.7.30/slf4j-api-1.7.30.jar" "$TRANS/slf4j-api-1.7.30.jar")"
CP="$CP:$(jar "$M2/org/slf4j/slf4j-simple/1.7.30/slf4j-simple-1.7.30.jar" "$TRANS/slf4j-simple-1.7.30.jar")"
for j in ${CP//:/ }; do
  [[ -e "$j" ]] || { echo "compile-gate: missing classpath entry: $j" >&2; exit 1; }
done

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
