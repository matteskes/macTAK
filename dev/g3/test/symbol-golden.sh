#!/usr/bin/env bash
#
# The symbol golden test, the kernel's leg (G3.7, make test-symbol-golden):
# takkernel's own CotUtils.mil2525cFromCotType, with 5.5's 2525 providers
# on missioncommand's public renderers, maps the CoT types the Swift port
# (CotSymbols) is tested on (SymbolOracle.java). Its answers must match
# dev/g3/test/symbol-golden/expected, which the Swift tests read; and the
# app's renderer (mactak.engine.Symbols) must draw exactly the codes the
# kernel's does.
#
# usage: symbol-golden.sh [--write]   (--write regenerates expected/)
# needs: dev/g1/kernel/build-kernel-jars.sh's patched takkernel, JDK 21
# exit:  0 match; 1 mismatch; 2 usage or preflight
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g3/test
ROOT="$(cd "$HERE/../../.." && pwd)"
KERNEL_DIR="$ROOT/dev/g1/kernel"
WORK="$KERNEL_DIR/build"
GOLDEN="$HERE/symbol-golden"
source "$ROOT/dev/jdk.sh"

die() { printf '[symbol-golden] FATAL: %s\n' "$*" >&2; exit 2; }

mode="check"
case "${1:-}" in
  --write) mode="write" ;;
  "") ;;
  *) die "usage: symbol-golden.sh [--write]" ;;
esac

[[ -x "$WORK/takkernel/gradlew" ]] || die "no patched takkernel in $WORK — run dev/g1/kernel/build-kernel-jars.sh"
JDK="$(mactak_jdk_home 21)" || die "JDK 21 not found (dev/jdk.sh)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
(
  cd "$WORK/takkernel"
  JAVA_HOME="$JDK" ./gradlew --no-daemon -q \
    -I "$HERE/symbol-oracle.gradle" \
    -Dmaven.repo.local="$WORK/m2" -PkernelBuildTarget=java \
    -PmacTakOracleDir="$HERE" -PmacTakRenderSrcDir="$ROOT/dev/g2/render/src" -PmacTakOutDir="$tmp" \
    :shared:macTakSymbolOracle
) || { echo "[symbol-golden] FAIL: the oracle failed" >&2; exit 1; }

if [[ "$mode" == write ]]; then
  mkdir -p "$GOLDEN/expected"
  cp "$tmp/cot-to-2525c.tsv" "$tmp/renderable.tsv" "$GOLDEN/expected/"
  echo "[symbol-golden] wrote $GOLDEN/expected"
  exit 0
fi

status=0
for f in cot-to-2525c.tsv renderable.tsv; do
  if ! diff -u "$GOLDEN/expected/$f" "$tmp/$f" >"$tmp/$f.diff"; then
    echo "[symbol-golden] FAIL: $f differs from the kernel's answers:" >&2
    head -n 40 "$tmp/$f.diff" >&2
    status=1
  fi
done
[[ $status -eq 0 ]] && echo "[symbol-golden] PASS: the kernel's mapping matches expected/"
exit "$status"
