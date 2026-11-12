#!/usr/bin/env bash
#
# G1.14 TLS server-purpose canary (security audit finding #1): commo must
# accept a TAK server's cert and refuse a cert from the same CA that is
# only fit for a TLS *client* — the impostor an enrolled user could present.
#
# One throwaway CA signs three leaf certs; fake-cot-server.py --tls presents
# each in turn to an atak-headless client that trusts that CA:
#
#   server (serverAuth EKU)       -> must connect   (headless: iface-up)
#   server (no EKU at all)        -> must connect   (OpenSSL's server purpose
#                                    accepts a leaf without extendedKeyUsage)
#   impostor (clientAuth EKU only) -> must be refused
#                                    (headless: iface-error CONN_SSL_PEER_CERT_NOT_TRUSTED,
#                                     and no iface-up)
#
# Two more leaves carry OpenTAKServer's own profiles, read from
# fixtures/ots-cert-profiles.cnf (pinned from its ca_config.py; a nightly
# drift check keeps the copy honest): its server certificate must connect,
# and a user certificate, which every enrolled user holds, must be refused.
#
# Needs the staged engine + comms stack (build-native.sh + build-commo.sh),
# JDK 21 (atak-headless finds it), python3 and openssl (any; macOS LibreSSL is fine).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g1/headless/test
CLI="$HERE/../atak-headless"
OTS_PROFILES="$HERE/fixtures/ots-cert-profiles.cnf"
SERVER="$HERE/../fake-cot-server.py"
PASS=atakatak
DURATION=6
BASE_PORT="${TLS_TEST_PORT:-18089}"

for tool in openssl python3; do
  command -v "$tool" >/dev/null 2>&1 \
    || { echo "[tls-test] $tool not found in PATH" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactak-tls-test.XXXXXX")"
SERVER_PID=""
# shellcheck disable=SC2317,SC2329  # invoked via trap (SC2317 on shellcheck < 0.10)
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- PKI: one CA, three leaves --------------------------------------------
# -extfile with bare key=value lines works in both OpenSSL and LibreSSL.
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$WORK/ca.ext"
openssl req -new -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.csr" \
  -subj "/CN=mactak-tls-test-ca" 2>/dev/null
openssl x509 -req -in "$WORK/ca.csr" -signkey "$WORK/ca.key" -out "$WORK/ca.crt" \
  -days 2 -extfile "$WORK/ca.ext" 2>/dev/null

leaf() {   # leaf NAME EXT_LINE
  local name="$1" ext="$2"
  printf '%s\n' "$ext" > "$WORK/$name.ext"
  openssl req -new -newkey rsa:2048 -nodes -keyout "$WORK/$name.key" \
    -out "$WORK/$name.csr" -subj "/CN=$name" 2>/dev/null
  openssl x509 -req -in "$WORK/$name.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
    -CAcreateserial -out "$WORK/$name.crt" -days 2 -extfile "$WORK/$name.ext" 2>/dev/null
}
leaf server-eku   "extendedKeyUsage=serverAuth"
leaf server-noeku "basicConstraints=CA:FALSE"
leaf impostor     "extendedKeyUsage=clientAuth"
leaf client       "extendedKeyUsage=clientAuth"

# The active lines of one section of the pinned OpenTAKServer profiles.
ots_profile() {   # ots_profile SECTION
  awk -v want="[ $1 ]" '
    /^\[/ { in_section = ($0 == want); next }
    in_section && NF && $0 !~ /^#/
  ' "$OTS_PROFILES"
}
for section in server client; do
  [[ -n "$(ots_profile "$section")" ]] \
    || { echo "[tls-test] no [ $section ] section in $OTS_PROFILES" >&2; exit 1; }
  leaf "ots-$section" "$(ots_profile "$section")"
done

# The client's own pair, as an ATAK data package ships it: client.p12
# (cert + key) and a key-less truststore.p12 holding the CA.
openssl pkcs12 -export -in "$WORK/client.crt" -inkey "$WORK/client.key" \
  -out "$WORK/client.p12" -passout "pass:$PASS" -name client 2>/dev/null
openssl pkcs12 -export -nokeys -in "$WORK/ca.crt" \
  -out "$WORK/truststore.p12" -passout "pass:$PASS" -name ca 2>/dev/null

# --- one leg: serve CERT, connect, capture the client's log ----------------
rc=0
port="$BASE_PORT"
run_leg() {   # run_leg NAME EXPECT(accept|refuse)
  local name="$1" expect="$2" log="$WORK/$1.client.log" ok=1
  python3 "$SERVER" "$port" --tls "$WORK/$name.crt" "$WORK/$name.key" \
    > "$WORK/$name.server.log" 2>&1 &
  SERVER_PID=$!
  sleep 1
  MACTAK_CERT_PASS="$PASS" MACTAK_CA_PASS="$PASS" \
    "$CLI" --connect "127.0.0.1:$port" --cert "$WORK/client.p12" \
    --ca "$WORK/truststore.p12" --uid "tls-test-$name" --callsign "TLS-$name" \
    --duration "$DURATION" > "$log" 2>&1 || true
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
  port=$((port + 1))

  if [[ "$expect" == accept ]]; then
    grep -q '^headless: iface-up' "$log" || ok=0
  else
    grep -q '^headless: iface-error CONN_SSL_PEER_CERT_NOT_TRUSTED' "$log" || ok=0
    if grep -q '^headless: iface-up' "$log"; then ok=0; fi
  fi
  if [[ "$ok" == 1 ]]; then
    echo "[tls-test] ok   $name: $expect"
  else
    echo "[tls-test] FAIL $name: expected $expect"; rc=1
  fi
  grep -E '^headless: (iface|connecting)|commo\[ERROR\]' "$log" | sed 's/^/    /' || true
}

run_leg server-eku   accept
run_leg server-noeku accept
run_leg impostor     refuse
run_leg ots-server   accept
run_leg ots-client   refuse

if [[ "$rc" == 0 ]]; then
  echo "[tls-test] PASS: server certs accepted, client-only impostors refused (OpenTAKServer profiles included)"
else
  echo "[tls-test] FAIL"
fi
exit "$rc"
