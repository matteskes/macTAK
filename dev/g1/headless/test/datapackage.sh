#!/usr/bin/env bash
# G1.5 canary: the --datapackage importer resolves an ATAK data package.
# Pure Java (DataPackage.java + ConnectOptions.java are JDK-only), so this
# needs no natives and no server: build the synthetic fixture, compile the
# importer, the flag/package precedence merge and DataPackageSelfTest.java,
# run the assertions. Runs on JDK 21 (CI) and any JDK >= 8.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../src/mactak/headless"

for tool in javac java; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "datapackage-canary: $tool not found in PATH — the canary needs a JDK >= 8" >&2
        exit 1
    }
done

WORK="$(mktemp -d /tmp/mactak-dp-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

DP="$WORK/fixture.dp"
"$HERE/fixtures/make-datapackage.sh" "$DP" DP-UNIT

CLASSES="$WORK/classes"
mkdir -p "$CLASSES"
javac -d "$CLASSES" "$SRC/DataPackage.java" "$SRC/ConnectOptions.java" \
    "$HERE/DataPackageSelfTest.java"
java -cp "$CLASSES" mactak.headless.DataPackageSelfTest "$DP" DP-UNIT