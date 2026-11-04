#!/usr/bin/env bash
#
# G1.2 — live CoT round-trip smoke: two atak-headless clients ↔ a TAK server.
#
# Client A listens; client B announces presence and drops a marker. PASS
# only when both interfaces came up, B's presence + marker went out, A
# received B's marker and saw B as a contact, and B received A's presence
# — the full tx + rx loop on the commoncommo stack, relayed by the server.
#
# Two clients because a TAK server does not reflect a client's own events
# back to it: the one-client form only passed on FreeTAKServer, which
# sends a welcome GeoChat and echoes the sender's marker. OpenTAKServer
# (and TAK Server) do neither. Verified against both.
#
# usage: run.sh [DURATION] [LAT] [LON]
# env:   TAK_HOST (default 127.0.0.1), TAK_PORT (default 8087 — FreeTAKServer
#        plaintext; OpenTAKServer uses 8088). FTS_HOST/FTS_PORT still honoured.
#        e.g. FreeTAKServer: docker run -d --name freetakserver --network host \
#                                vigsecdrone/freetakserver:latest
# CI: also runs hermetically against dev/g1/headless/fake-cot-server.py (.github/workflows/cot-roundtrip.yml)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DURATION="${1:-12}"
LAT="${2:-37.7749}"
LON="${3:--122.4194}"
TAK_HOST="${TAK_HOST:-${FTS_HOST:-127.0.0.1}}"
TAK_PORT="${TAK_PORT:-${FTS_PORT:-8087}}"
RUN="$(date +%s)"
UID_A="g1-rt-$RUN-a"
UID_B="g1-rt-$RUN-b"
LOG_A="$(mktemp -t g1-roundtrip-a.XXXXXX).log"
LOG_B="$(mktemp -t g1-roundtrip-b.XXXXXX).log"

nc -z -G 2 "$TAK_HOST" "$TAK_PORT" >/dev/null 2>&1 \
  || { echo "run.sh: no TAK server on $TAK_HOST:$TAK_PORT — start one first (set TAK_HOST/TAK_PORT)" >&2; exit 1; }
echo "[g1-roundtrip] server reachable at $TAK_HOST:$TAK_PORT — running two atak-headless clients ${DURATION}s"

set +e
bash "$HERE/atak-headless" --connect "$TAK_HOST:$TAK_PORT" \
    --uid "$UID_A" --callsign G1RT-A --duration "$DURATION" \
    > "$LOG_A" 2>&1 &
pid_a=$!
sleep 1   # A is registered before B's first (and only) marker goes out
bash "$HERE/atak-headless" --connect "$TAK_HOST:$TAK_PORT" \
    --uid "$UID_B" --callsign G1RT-B --duration "$DURATION" --send-marker "$LAT" "$LON" \
    > "$LOG_B" 2>&1
rc_b=$?
wait "$pid_a"
rc_a=$?
set -e

for side in A B; do
  log="LOG_$side"
  echo "--- client $side ---"
  grep -E '^headless: |commo\[ERROR\]' "${!log}" | grep -v 'presence-heartbeat' | cut -c1-200 || true
done

fail=0
check() {   # check LOG PATTERN MESSAGE
  grep -q -- "$2" "$1" || { echo "[g1-roundtrip] FAIL: $3" >&2; fail=1; }
}
check "$LOG_A" 'headless: iface-up'              "A: interface never came up"
check "$LOG_B" 'headless: iface-up'              "B: interface never came up"
check "$LOG_B" 'headless: presence-sent'         "B: presence never announced"
check "$LOG_B" 'headless: marker-sent'           "B: marker never sent"
check "$LOG_A" "headless: contact-added $UID_B"  "A: never saw B as a contact"
check "$LOG_A" "uid='$UID_B-m1'\\|uid=\"$UID_B-m1\"" "A: B's marker never arrived"
check "$LOG_B" "uid='$UID_A'\\|uid=\"$UID_A\""   "B: A's presence never arrived"
[[ "$rc_a" -eq 0 ]] || { echo "[g1-roundtrip] FAIL: client A exited $rc_a" >&2; fail=1; }
[[ "$rc_b" -eq 0 ]] || { echo "[g1-roundtrip] FAIL: client B exited $rc_b" >&2; fail=1; }

if [[ "$fail" -eq 0 ]]; then
  echo "[g1-roundtrip] PASS — both ifaces up, B's presence+marker relayed to A, A's presence relayed to B"
  rm -f "$LOG_A" "$LOG_B"
else
  echo "[g1-roundtrip] client logs kept: $LOG_A $LOG_B" >&2
  exit 1
fi
