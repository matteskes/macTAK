#!/usr/bin/env bash
#
# Guard: the GDAL in dev/deps/dist registers exactly the drivers listed in
# dev/deps/gdal-drivers.txt, so a GDAL bump can't quietly add one (or lose
# one the engine needs). Builds a ten-line C program against that libgdal.
#
# Usage: dev/deps/check-gdal-drivers.sh [deps-dist]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/deps
DIST="$(cd "${1:-${MACTAK_DEPS_DIST:-$HERE/dist}}" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/drivers.c" <<'C'
#include <stdio.h>
#include <gdal.h>
int main(void)
{
    GDALAllRegister();
    for (int i = 0; i < GDALGetDriverCount(); i++)
        puts(GDALGetDriverShortName(GDALGetDriver(i)));
    return 0;
}
C
clang -arch arm64 -I"$DIST/include" "$WORK/drivers.c" -L"$DIST/lib" -lgdal \
  -Wl,-rpath,"$DIST/lib" -o "$WORK/drivers"
"$WORK/drivers" | LC_ALL=C sort > "$WORK/actual"
grep -vE '^\s*(#|$)' "$HERE/gdal-drivers.txt" | LC_ALL=C sort > "$WORK/expected"

if diff "$WORK/expected" "$WORK/actual" > "$WORK/diff"; then
  echo "[gdal-drivers] PASS: $(wc -l < "$WORK/actual" | tr -d ' ') drivers, as dev/deps/gdal-drivers.txt lists"
else
  echo "[gdal-drivers] FAIL: registered drivers differ from dev/deps/gdal-drivers.txt (< expected, > registered):"
  sed 's/^/    /' "$WORK/diff"
  exit 1
fi
