#!/usr/bin/env bash
# android.net.Uri stand-in canary: fromFile round trips for paths holding
# URI syntax (# ? % + space, non-ASCII), Android's encode/decode rules, and
# the parse behaviour the engine already relied on. Pure Java (the class is
# JDK-only), so this needs no natives. Runs on JDK 21 (CI) and any JDK >= 8.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test
SRC="$HERE/../src/android/net"

for tool in javac java; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "uri-canary: $tool not found in PATH — the canary needs a JDK >= 8" >&2
        exit 1
    }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactak-uri-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

javac -encoding UTF-8 -d "$WORK" "$SRC/Uri.java" "$HERE/UriSelfTest.java"
java -cp "$WORK" UriSelfTest
