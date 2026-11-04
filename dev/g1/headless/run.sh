#!/usr/bin/env bash
#
# G1.2 — live CoT round-trip smoke: atak-headless ↔ FreeTAKServer.
#
# Assumes a FreeTAKServer (plaintext CoT) is listening on 127.0.0.1:8087,
# e.g.:  docker run -d --name freetakserver --network host \
#            vigsecdrone/freetakserver:latest
# Verifies the port, runs the headless client with a marker for DURATION
# seconds, and passes only when the interface came up, presence and the
# marker went out, and at least one CoT arrived back from the server —
# the full tx + rx loop on the commoncommo stack.
#
# usage: run.sh [DURATION] [LAT] [LON]
# env:   FTS_HOST (default 127.0.0.1), FTS_PORT (default 8087)
# CI: also runs hermetically against dev/g1/headless/fake-cot-server.py (.github/workflows/cot-roundtrip.yml)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DURATION="${1:-12}"
LAT="${2:-37.7749}"
LON="${3:--122.4194}"
FTS_HOST="${FTS_HOST:-127.0.0.1}"
FTS_PORT="${FTS_PORT:-8087}"
LOG="$(mktemp -t g1-roundtrip.XXXXXX).log"

nc -z -G 2 "$FTS_HOST" "$FTS_PORT" >/dev/null 2>&1 \
  || { echo "run.sh: no TAK server on $FTS_HOST:$FTS_PORT — start FreeTAKServer first" >&2; exit 1; }
echo "[g1-roundtrip] server reachable at $FTS_HOST:$FTS_PORT — running atak-headless ${DURATION}s"

set +e
bash "$HERE/atak-headless" --connect "$FTS_HOST:$FTS_PORT" \
    --uid "g1-roundtrip-$(date +%s)" --callsign G1RT \
    --duration "$DURATION" --send-marker "$LAT" "$LON" \
    > "$LOG" 2>&1
rc=$?
set -e

grep -E '^headless: |commo\[ERROR\]' "$LOG" || true

fail=0
grep -q 'headless: iface-up' "$LOG" \
  || { echo "[g1-roundtrip] FAIL: interface never came up" >&2; fail=1; }
grep -q 'headless: presence-sent' "$LOG" \
  || { echo "[g1-roundtrip] FAIL: presence never announced" >&2; fail=1; }
grep -q 'headless: marker-sent' "$LOG" \
  || { echo "[g1-roundtrip] FAIL: marker never sent" >&2; fail=1; }
grep -q 'headless: cot-received' "$LOG" \
  || { echo "[g1-roundtrip] FAIL: no CoT received back from the server" >&2; fail=1; }
[[ "$rc" -eq 0 ]] \
  || { echo "[g1-roundtrip] FAIL: client exited $rc" >&2; fail=1; }

if [[ "$fail" -eq 0 ]]; then
  echo "[g1-roundtrip] PASS — iface up, presence+marker tx, CoT rx round-trip"
  rm -f "$LOG"
else
  echo "[g1-roundtrip] client log kept: $LOG" >&2
  exit 1
fi
