#!/usr/bin/env bash
#
# QUIC canary (`make test-quic`): commo's streaming QUIC client on ngtcp2's
# ossl backend against fake-quic-server.py (aioquic, ALPN "takstream"). One
# throwaway CA signs a serverAuth leaf, a clientAuth-only impostor and the
# client's own certificate:
#
#   accept  the server presents the serverAuth leaf: the handshake
#           completes and the client's marker arrives over QUIC
#   refuse  the server presents the impostor: commo refuses it
#           (CONN_SSL_PEER_CERT_NOT_TRUSTED), as patches/commo/0002 makes
#           it on TCP — G1 security finding #1, on the QUIC path
#   cause   nothing listens: the handshake's read fails with ECONNREFUSED,
#           and commo's log must say so (g55 trap 8, patches/commo/0006)
#
# From spike 2 (dev/spike/g55/NOTES.md §Commo). aioquic installs into a
# venv from the hash-pinned requirements-quic.txt (--require-hashes).
#
# usage: test/quic.sh   (needs dev/g1/native-dist from build-commo.sh)
# env:   QUIC_TEST_PORT (default 18190; the refuse leg uses +1, the cause
#        leg +2, which must have no listener),
#        QUIC_TEST_VERBOSE=1 prints commo's whole log
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g1/headless/test
G1="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$G1/../.." && pwd)"
DIST="$G1/native-dist"
WORK="$G1/headless/build/quic-test"
VENV="$G1/headless/build/quic-venv"
REQUIREMENTS="$HERE/requirements-quic.txt"
PORT="${QUIC_TEST_PORT:-18190}"
PASS=atakatak

log() { printf '[quic-test] %s\n' "$*"; }
die() { printf '[quic-test] FATAL: %s\n' "$*" >&2; exit 1; }

for f in libcommoncommo.dylib libcommoncommojni.dylib jcommoncommo.jar; do
  [[ -f "$DIST/$f" ]] || die "$DIST/$f missing — run dev/g1/build-commo.sh"
done
# shellcheck source=SCRIPTDIR/../../../jdk.sh
source "$ROOT/dev/jdk.sh"
JDK="$(mactak_jdk_home 21)" || die "JDK 21 not found (dev/jdk.sh)"
OPENSSL_CLI="$(brew --prefix openssl@3)/bin/openssl"
[[ -x "$OPENSSL_CLI" ]] || die "brew openssl@3 missing"

# The venv is rebuilt whenever requirements-quic.txt changes.
if ! cmp -s "$REQUIREMENTS" "$VENV/requirements-quic.txt" 2>/dev/null; then
  log "aioquic venv (--require-hashes) → $VENV"
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check --require-hashes -r "$REQUIREMENTS"
  cp "$REQUIREMENTS" "$VENV/requirements-quic.txt"
fi

rm -rf "$WORK"
mkdir -p "$WORK/classes"

log "PKI: one CA; serverAuth leaf, clientAuth-only impostor, client"
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$WORK/ca.ext"
"$OPENSSL_CLI" req -new -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.csr" \
  -subj "/CN=mactak-quic-test-ca" 2>/dev/null
"$OPENSSL_CLI" x509 -req -in "$WORK/ca.csr" -signkey "$WORK/ca.key" -out "$WORK/ca.crt" \
  -days 2 -extfile "$WORK/ca.ext" 2>/dev/null
for name in server impostor client; do
  case "$name" in
    server) printf 'extendedKeyUsage=serverAuth\n' > "$WORK/$name.ext" ;;
    *)      printf 'extendedKeyUsage=clientAuth\n' > "$WORK/$name.ext" ;;
  esac
  "$OPENSSL_CLI" req -new -newkey rsa:2048 -nodes -keyout "$WORK/$name.key" \
    -out "$WORK/$name.csr" -subj "/CN=$name" 2>/dev/null
  "$OPENSSL_CLI" x509 -req -in "$WORK/$name.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
    -CAcreateserial -out "$WORK/$name.crt" -days 2 -extfile "$WORK/$name.ext" 2>/dev/null
  "$OPENSSL_CLI" pkcs12 -export -in "$WORK/$name.crt" -inkey "$WORK/$name.key" \
    -certfile "$WORK/ca.crt" -out "$WORK/$name.p12" -passout "pass:$PASS" -name "$name"
done
"$OPENSSL_CLI" pkcs12 -export -nokeys -in "$WORK/ca.crt" \
  -out "$WORK/truststore.p12" -passout "pass:$PASS" -name ca

"$JDK/bin/javac" --release 21 -Xlint:all -Werror -cp "$DIST/jcommoncommo.jar" \
  -d "$WORK/classes" "$HERE/QuicStreamingTest.java"

quic_server=""
# shellcheck disable=SC2317,SC2329  # invoked via trap
stop_server() {
  if [[ -n "$quic_server" ]]; then kill "$quic_server" 2>/dev/null || true; fi
}
trap stop_server EXIT

quic_leg() {   # quic_leg SERVER_CERT accept|refuse PORT
  local server_log="$WORK/quic-$1.server.log"
  "$VENV/bin/python" "$HERE/fake-quic-server.py" "$3" "$WORK/$1.crt" "$WORK/$1.key" \
    > "$server_log" 2>&1 &
  quic_server=$!
  sleep 1
  log "$2 leg: the server presents the $1 certificate (:$3)"
  "$JDK/bin/java" -cp "$DIST/jcommoncommo.jar:$WORK/classes" QuicStreamingTest \
    "$DIST/libcommoncommo.dylib" "$DIST/libcommoncommojni.dylib" \
    "$WORK/client.p12" "$WORK/truststore.p12" "$3" "$2"
  kill "$quic_server" 2>/dev/null || true
  wait "$quic_server" 2>/dev/null || true
  quic_server=""
  sed 's/^/    /' "$server_log" | cut -c1-160
  if [[ "$2" == accept ]]; then
    grep -q 'fake-quic-server: handshake alpn=takstream' "$server_log" \
      || die "the QUIC server saw no takstream handshake"
    grep -q 'quic-streaming-marker' "$server_log" \
      || die "the QUIC server never received the marker"
    log "PASS: takstream handshake completed, marker received over QUIC"
  fi
}
quic_leg server accept "$PORT"
quic_leg impostor refuse "$((PORT + 1))"

log "cause leg: nothing listens on :$((PORT + 2))"
"$JDK/bin/java" -cp "$DIST/jcommoncommo.jar:$WORK/classes" QuicStreamingTest \
  "$DIST/libcommoncommo.dylib" "$DIST/libcommoncommojni.dylib" \
  "$WORK/client.p12" "$WORK/truststore.p12" "$((PORT + 2))" cause

log "PASS: commo streams over QUIC, refuses a clientAuth-only server certificate, and names a failed handshake's cause"
