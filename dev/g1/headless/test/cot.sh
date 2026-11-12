#!/usr/bin/env bash
# CoT text-path canary: CotEvent.parse (receive) and CotXml (send) — escaping,
# --send-marker coordinate checks, direct-child <point>/<contact> lookup,
# XXE refusal, and presence/marker events parsed back. Pure Java (both
# classes are JDK-only), so this needs no natives and no server. Runs on
# JDK 21 (CI) and any JDK >= 8.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../src/mactak/headless"

for tool in javac java; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "cot-canary: $tool not found in PATH — the canary needs a JDK >= 8" >&2
        exit 1
    }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactak-cot-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

javac -d "$WORK" "$SRC/CotEvent.java" "$SRC/CotXml.java" \
    "$HERE/CotEventSelfTest.java"
java -cp "$WORK" mactak.headless.CotEventSelfTest
