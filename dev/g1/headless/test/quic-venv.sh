#!/usr/bin/env bash
#
# The aioquic venv that fake-quic-server.py runs in, built from the
# hash-pinned requirements-quic.txt (--require-hashes) and rebuilt whenever
# that file changes. Prints the venv's python on stdout; progress goes to
# stderr. Used by test/quic.sh and by `make test-app` (G3.2's QUIC leg).
#
# usage: test/quic-venv.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g1/headless/test
VENV="$HERE/../build/quic-venv"
REQUIREMENTS="$HERE/requirements-quic.txt"

if ! cmp -s "$REQUIREMENTS" "$VENV/requirements-quic.txt" 2>/dev/null; then
  printf '[quic-venv] aioquic (--require-hashes) → %s\n' "$VENV" >&2
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check --require-hashes -r "$REQUIREMENTS" >&2
  cp "$REQUIREMENTS" "$VENV/requirements-quic.txt"
fi
printf '%s\n' "$(cd "$VENV" && pwd)/bin/python"
