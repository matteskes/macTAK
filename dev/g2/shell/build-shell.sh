#!/usr/bin/env bash
#
# Build the G2 test harness, mactak-shell: since G3.0 a product of the Swift
# package at app/ (`swift build -c release --product mactak-shell`: CJavaBoot
# + MacTAKCore + app/Sources/mactak-shell), copied to dev/g2/build/mactak-shell,
# whose path this prints (run.sh captures it). SwiftPM rebuilds only what
# changed; an up-to-date build takes about a second.
#
# Building needs no GUI session, no engine and no JDK (jni.h is the repo's
# pinned copy, app/Package.swift): this is the CI gate; the run that opens
# the window is `make test-shell` on the dev Mac (same split as M3.0's
# compile-only smoke-window). Swift 6.4.2/arm64 verified locally.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # dev/g2/shell
G2="$(cd "$HERE/.." && pwd)"
APP="$(cd "$G2/../../app" && pwd)"
OUT="$G2/build/mactak-shell"

command -v swift >/dev/null 2>&1 \
  || { echo "build-shell.sh: swift not on PATH — Xcode command line tools required" >&2; exit 2; }

# SwiftPM's progress goes to stderr: stdout carries only the path.
swift build -c release --package-path "$APP" --product mactak-shell >&2
BIN_DIR="$(swift build -c release --package-path "$APP" --show-bin-path)"
mkdir -p "$(dirname "$OUT")"
if ! cmp -s "$BIN_DIR/mactak-shell" "$OUT"; then
  cp "$BIN_DIR/mactak-shell" "$OUT.tmp"
  mv "$OUT.tmp" "$OUT"
fi

echo "$OUT"
