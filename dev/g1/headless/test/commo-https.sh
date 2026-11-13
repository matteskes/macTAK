#!/usr/bin/env bash
#
# commo's https canary (`make test-commo-https`; issues #157 and #146):
# commo's curl path, through certificate enrollment's first request
# (CommoHttpsTest), against loopback HTTPS servers that record each request
# (http-witness.py --tls). A throwaway PKI: CA 1 signs both servers, CA 2
# signs nothing; server "named" carries IP:127.0.0.1, server "misnamed"
# IP:10.255.255.1, and "clientonly" is named right but issued for clients
# only (extendedKeyUsage=clientAuth).
#
#   trusted     CA 1, server named:        the handshake completes; the
#                                          request reaches the server
#   untrusted   CA 2, server named:        refused, SSL_UNTRUSTED_SERVER,
#                                          no request; commo doesn't crash
#   host-match  CA 1 + verifyHost, named:  reaches the server
#   host-wrong  CA 1 + verifyHost, misnamed: refused, no request
#   client-only CA 1, server clientonly:   refused, no request: curl's
#                                          OpenSSL checks the TLS-server
#                                          purpose (G1.14 finding 1's rule)
#   no-ca       no CA, server named:       reaches the server; commo's
#                                          documented behaviour: with no CA
#                                          it accepts any certificate, so a
#                                          caller must always pass one (#146)
#
# Before #157, commo linked Apple's libcurl (LibreSSL): the CA legs crashed
# the JVM in SSL_CTX_free or hung. The legs need commo built against
# fetch-curl.sh's curl (dev/g1/build-commo.sh).
#
# usage: test/commo-https.sh   (needs dev/g1/native-dist from build-commo.sh)
# env:   COMMO_HTTPS_VERBOSE=1 prints commo's whole log
# shellcheck disable=SC2317,SC2329  # invoked via trap (SC2317 on shellcheck < 0.10)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g1/headless/test
G1="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$G1/../.." && pwd)"
DIST="$G1/native-dist"
PASS=atakatak

log() { printf '[commo-https] %s\n' "$*"; }
die() { printf '[commo-https] FATAL: %s\n' "$*" >&2; exit 1; }

for f in libcommoncommo.dylib libcommoncommojni.dylib jcommoncommo.jar; do
  [[ -f "$DIST/$f" ]] || die "$DIST/$f missing — run dev/g1/build-commo.sh"
done
# shellcheck source=SCRIPTDIR/../../../jdk.sh
source "$ROOT/dev/jdk.sh"
JDK="$(mactak_jdk_home 21)" || die "JDK 21 not found (dev/jdk.sh)"
OPENSSL_CLI="$(brew --prefix openssl@3)/bin/openssl"
[[ -x "$OPENSSL_CLI" ]] || die "brew openssl@3 missing"

WORK="$(mktemp -d)"
SERVERS=()
cleanup() {
  local pid
  for pid in ${SERVERS[@]+"${SERVERS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

log "PKI: CA 1 signs three servers (named, misnamed, client-only); CA 2 signs nothing"
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$WORK/ca.ext"
for ca in ca1 ca2; do
  "$OPENSSL_CLI" req -new -newkey rsa:2048 -nodes -keyout "$WORK/$ca.key" -out "$WORK/$ca.csr" \
    -subj "/CN=mactak-https-test-$ca" 2>/dev/null
  "$OPENSSL_CLI" x509 -req -in "$WORK/$ca.csr" -signkey "$WORK/$ca.key" -out "$WORK/$ca.crt" \
    -days 2 -extfile "$WORK/ca.ext" 2>/dev/null
  "$OPENSSL_CLI" pkcs12 -export -nokeys -in "$WORK/$ca.crt" -out "$WORK/$ca.p12" \
    -passout "pass:$PASS" -name "$ca"
done
for server in named:127.0.0.1:serverAuth misnamed:10.255.255.1:serverAuth clientonly:127.0.0.1:clientAuth; do
  IFS=: read -r name ip usage <<<"$server"
  printf 'extendedKeyUsage=%s\nsubjectAltName=IP:%s\n' "$usage" "$ip" > "$WORK/$name.ext"
  "$OPENSSL_CLI" req -new -newkey rsa:2048 -nodes -keyout "$WORK/$name.key" -out "$WORK/$name.csr" \
    -subj "/CN=$ip" 2>/dev/null
  "$OPENSSL_CLI" x509 -req -in "$WORK/$name.csr" -CA "$WORK/ca1.crt" -CAkey "$WORK/ca1.key" \
    -CAcreateserial -out "$WORK/$name.crt" -days 2 -extfile "$WORK/$name.ext" 2>/dev/null
done

# start_server NAME — an HTTPS witness presenting NAME's certificate
start_server() {
  : > "$WORK/$1.requests"
  python3 -I "$HERE/http-witness.py" "$WORK/$1.port" "$WORK/$1.requests" \
    --tls "$WORK/$1.crt" "$WORK/$1.key" > "$WORK/$1.server.log" 2>&1 &
  SERVERS+=("$!")
  local _
  for _ in $(seq 1 50); do [[ -s "$WORK/$1.port" ]] && return 0; sleep 0.1; done
  die "the $1 server did not start: $(cat "$WORK/$1.server.log")"
}
start_server named
start_server misnamed
start_server clientonly

"$JDK/bin/javac" --release 21 -Xlint:all -Werror -cp "$DIST/jcommoncommo.jar" \
  -d "$WORK/classes" "$HERE/CommoHttpsTest.java"

rc=0
# leg NAME TRUSTSTORE VERIFYHOST SERVER EXPECT — EXPECT is "reach" (the
# request arrives) or an SSL status the leg must end in, with no request
leg() {
  local name="$1" truststore="$2" verify="$3" server="$4" expect="$5"
  local port before after ec=0 result
  port="$(tr -d '[:space:]' < "$WORK/$server.port")"
  before="$(wc -l < "$WORK/$server.requests" | tr -d ' ')"
  "$JDK/bin/java" -cp "$DIST/jcommoncommo.jar:$WORK/classes" CommoHttpsTest \
    "$DIST/libcommoncommo.dylib" "$DIST/libcommoncommojni.dylib" \
    "$port" "$truststore" "$verify" > "$WORK/$name.log" 2>&1 || ec=$?
  after="$(wc -l < "$WORK/$server.requests" | tr -d ' ')"
  result="$(grep -m1 '^RESULT ' "$WORK/$name.log" | cut -c8- || true)"
  if (( ec != 0 )); then
    log "FAIL $name: the JVM exited $ec (a crash is the #157 signature)"
    sed 's/^/    /' "$WORK/$name.log" | tail -n 15; rc=1; return
  fi
  if [[ "$expect" == reach ]]; then
    if (( after > before )); then
      log "ok   $name: the request reached the server ($result)"
    else
      log "FAIL $name: the request never reached the server ($result)"; rc=1
    fi
  else
    if (( after > before )); then
      log "FAIL $name: the request reached the server; the certificate should have been refused"; rc=1
    elif [[ "$result" == "$expect"* ]]; then
      log "ok   $name: refused before any request ($result)"
    else
      log "FAIL $name: no request, but ended in '$result', not $expect"; rc=1
    fi
  fi
}

leg trusted    "$WORK/ca1.p12" false named    reach
leg untrusted  "$WORK/ca2.p12" false named    SSL_UNTRUSTED_SERVER
leg host-match "$WORK/ca1.p12" true  named    reach
leg host-wrong "$WORK/ca1.p12" true  misnamed SSL_
leg client-only "$WORK/ca1.p12" false clientonly SSL_
leg no-ca      none            false named    reach

if (( rc == 0 )); then
  log "PASS: commo's https path verifies the CA it is given; refuses another CA, a wrong host name and a client-only certificate; doesn't crash"
else
  log "FAIL"
fi
exit "$rc"
