#!/usr/bin/env bash
#
# Shell argument canary: a value option given last (`--out` with nothing
# after it) must end in exit 2 and a message naming the option, not in a
# Swift array-index trap. Argument parsing runs before the JVM starts and
# before any window opens, so this needs no GUI session, no engine build
# and no ANGLE: only the compiled shell (build-shell.sh).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/shell/test
BIN="$(bash "$HERE/../build-shell.sh")"
ERR="$(mktemp "${TMPDIR:-/tmp}/shell-args.XXXXXX")"
trap 'rm -f "$ERR"' EXIT

rc_all=0
for opt in --classpath --lib --prop --egl --gles --size --frames --settle --linger \
           --out --layer --basemap --layer-db --res --at --live --resize-to --frame-log; do
  set +e
  "$BIN" "$opt" > /dev/null 2> "$ERR"
  rc=$?
  set -e
  if [[ "$rc" -eq 2 ]] && grep -q -- "$opt needs a value" "$ERR"; then
    echo "[shell-args] ok   $opt"
  else
    echo "[shell-args] FAIL $opt: exit $rc, expected 2 with '$opt needs a value'" >&2
    head -n 3 "$ERR" | sed 's/^/    /' >&2
    rc_all=1
  fi
done

if [[ "$rc_all" -eq 0 ]]; then
  echo "[shell-args] PASS: every value option reports a missing value"
fi
exit "$rc_all"
