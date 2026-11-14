#!/usr/bin/env bash
#
# Verify every committed transplant jar against its directory's SHA256SUMS
# (CONTRIBUTING "Binaries carry proof"). One check, three callers: the
# pre-commit hook, `make check-transplants`, and CI's lint job.
#
# Fails when, in any transplants directory:
#   - SHA256SUMS is missing,
#   - a listed file's hash doesn't match, or
#   - a *.jar is present but not listed. `shasum -c` alone only checks the
#     listed files, so an unlisted jar used to pass silently (G1 security
#     audit: the two slf4j transplants were never listed).
#
# Covers the committed jars only: dev/g1/transplants (slf4j-simple, the
# binding atak-headless runs with) and dev/spike/g0/transplants (the
# android-port base that dev/g1/kernel/android-port/build-android-port.py
# extends). The takkernel jars aren't transplants: build-kernel-jars.sh
# builds them from src/ into the gitignored dev/g1/kernel-dist, and
# dev/g1/kernel/classpath.sh logs when MACTAK_KERNEL_DIST points elsewhere
# (issue #150).
#
# usage: dev/check-transplants.sh   (from anywhere in the checkout)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIRS=(dev/g1/transplants dev/spike/g0/transplants)

if command -v sha256sum >/dev/null 2>&1; then
  SUM=(sha256sum)            # Linux (CI's lint runner)
else
  SUM=(shasum -a 256)        # macOS
fi

fail=0
for rel in "${DIRS[@]}"; do
  dir="$ROOT/$rel"
  [[ -d "$dir" ]] || continue
  if [[ ! -f "$dir/SHA256SUMS" ]]; then
    echo "[check-transplants] FAIL $rel: no SHA256SUMS"
    fail=1
    continue
  fi
  # Plain -c (no --quiet: older macOS shasum lacks it); show only the
  # lines that aren't ": OK".
  if ! out="$(cd "$dir" && "${SUM[@]}" -c SHA256SUMS 2>&1)"; then
    printf '%s\n' "$out" | grep -v ': OK$' || true
    echo "[check-transplants] FAIL $rel: checksum mismatch (above)"
    fail=1
  fi
  for jar in "$dir"/*.jar; do
    [[ -e "$jar" ]] || continue
    name="$(basename "$jar")"
    if ! awk -v n="$name" '$2 == n || $2 == "*" n { found = 1 } END { exit !found }' "$dir/SHA256SUMS"; then
      echo "[check-transplants] FAIL $rel/$name: not listed in SHA256SUMS"
      fail=1
    fi
  done
done

if [[ "$fail" -ne 0 ]]; then
  echo "[check-transplants] FAILED"
  exit 1
fi
echo "[check-transplants] OK: every transplant jar is listed and matches"
