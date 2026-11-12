#!/usr/bin/env bash
#
# RenderSmoke argument canary: a value option given last, or a value that
# is not a number, must end in exit 2 with a message naming the option,
# not in a Java stack trace and exit 1 (which reads as a render FAIL).
# Argument parsing runs before any native library loads.
#
# Needs what dev/g2/render/run.sh needs to start the JVM (env.sh).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test
ERR="$(mktemp "${TMPDIR:-/tmp}/render-args.XXXXXX")"
trap 'rm -f "$ERR"' EXIT

rc_all=0
expect_usage() {   # expect_usage MESSAGE ARGS...
  local want="$1" rc
  shift
  set +e
  bash "$HERE/../run.sh" "$@" > /dev/null 2> "$ERR"
  rc=$?
  set -e
  if [[ "$rc" -eq 2 ]] && grep -q -- "$want" "$ERR" && ! grep -q 'Exception' "$ERR"; then
    echo "[render-args] ok   $*"
  else
    echo "[render-args] FAIL $*: exit $rc, expected 2 with '$want' and no stack trace" >&2
    head -n 3 "$ERR" | sed 's/^/    /' >&2
    rc_all=1
  fi
}

expect_usage '--frames needs a value' --frames
expect_usage '--size needs a value'   --size
expect_usage '--at needs a value'     --at
expect_usage 'bad --frames'           --frames many
expect_usage 'bad --size'             --size 512
expect_usage 'bad --at'               --at 37.8
expect_usage '--expect needs a value' --expect
expect_usage 'bad --expect'           --expect 37.8,-122.4
expect_usage 'bad --expect'           --expect 37.8,-122.4,green
expect_usage '--elevation needs a value' --elevation
expect_usage 'bad --tilt'             --tilt steep
expect_usage 'bad --expect-height'    --expect-height 37.8,-122.4
expect_usage 'bad --expect-height'    --expect-height 37.8,-122.4,500,agl

if [[ "$rc_all" -eq 0 ]]; then
  echo "[render-args] PASS: bad arguments end in usage, exit 2"
fi
exit "$rc_all"
