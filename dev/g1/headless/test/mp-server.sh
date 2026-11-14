#!/usr/bin/env bash
#
# commo's mission-package web server canary (`make test-mp-server`; bundling
# plan PR B): MissionPackageServerTest starts commo's local web server on a
# plain port and on its HTTPS port, and a GET for a transfer that doesn't
# exist must come back 404 from both.
#
# The server is libmicrohttpd, which macTAK builds without HTTPS
# (dev/g1/fetch-microhttpd.sh: Homebrew's linked GnuTLS, a second TLS
# stack). commo's HTTPS port never used libmicrohttpd's TLS: it is commo's
# own OpenSSL proxy (core/impl/httpsproxy.cpp) in front of the plain server.
# This pins that both still answer.
#
# usage: test/mp-server.sh   (needs dev/g1/native-dist from build-commo.sh)
# env:   MP_SERVER_VERBOSE=1 prints commo's whole log
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g1/headless/test
G1="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$G1/../.." && pwd)"
DIST="$G1/native-dist"
PASS=atakatak

log() { printf '[mp-server] %s\n' "$*"; }
die() { printf '[mp-server] FATAL: %s\n' "$*" >&2; exit 1; }

for f in libcommoncommo.dylib libcommoncommojni.dylib jcommoncommo.jar; do
  [[ -f "$DIST/$f" ]] || die "$DIST/$f missing — run dev/g1/build-commo.sh"
done
# shellcheck source=SCRIPTDIR/../../../jdk.sh
source "$ROOT/dev/jdk.sh"
JDK="$(mactak_jdk_home 21)" || die "JDK 21 not found (dev/jdk.sh)"
OPENSSL_CLI="$(brew --prefix openssl@3)/bin/openssl"
[[ -x "$OPENSSL_CLI" ]] || die "brew openssl@3 missing"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# the HTTPS port's certificate: self-signed, a PKCS#12 with its key, as commo takes it
"$OPENSSL_CLI" req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/server.key" -out "$WORK/server.crt" \
  -subj "/CN=127.0.0.1" -days 2 -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null
"$OPENSSL_CLI" pkcs12 -export -in "$WORK/server.crt" -inkey "$WORK/server.key" \
  -out "$WORK/server.p12" -passout "pass:$PASS" -name server

"$JDK/bin/javac" --release 21 -Xlint:all -Werror -cp "$DIST/jcommoncommo.jar" \
  -d "$WORK/classes" "$HERE/MissionPackageServerTest.java"

ec=0
"$JDK/bin/java" -cp "$DIST/jcommoncommo.jar:$WORK/classes" MissionPackageServerTest \
  "$DIST/libcommoncommo.dylib" "$DIST/libcommoncommojni.dylib" "$WORK/server.p12" \
  > "$WORK/run.log" 2>&1 || ec=$?
http="$(awk '$1 == "RESULT" && $2 == "http" { print $3 }' "$WORK/run.log")"
https="$(awk '$1 == "RESULT" && $2 == "https" { print $3 }' "$WORK/run.log")"

rc=0
for leg in "plain:$http" "https:$https"; do
  name="${leg%%:*}" code="${leg#*:}"
  if [[ "$code" == 404 ]]; then
    log "ok   $name: the web server answered 404 for an unknown transfer"
  else
    log "FAIL $name: expected 404, got '${code:-no response}'"; rc=1
  fi
done
if (( ec > 1 )); then
  log "FAIL: the JVM exited $ec"; rc=1
fi
if (( rc != 0 )); then
  sed 's/^/    /' "$WORK/run.log" | tail -n 20
  log "FAIL"
  exit 1
fi
log "PASS: commo's mission-package web server answers on its plain port and through its HTTPS proxy"
