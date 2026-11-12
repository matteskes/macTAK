#!/usr/bin/env bash
#
# Spike 2 (docs/rebase-study-5.5.md step 2, NOTES.md §Commo): 5.5 commo on
# macOS, its QUIC on ngtcp2's ossl backend over Homebrew openssl@3.
#
#   1. ngtcp2 1.26.0 against openssl@3            (commo/fetch-ngtcp2.sh)
#   2. 5.5 commoncommo + patches/commo, built by dev/g1/build-commo.sh
#      (its MACTAK_COMMO_* overrides) into build/commo-dist beside the
#      4.6 engine dylibs from dev/g1/native-dist: the headless launcher
#      and its tests need both, and the 5.5 engine needs a JDK the
#      launcher does not run on yet
#   3. linkage: one OpenSSL (openssl@3), ngtcp2 linked in statically
#   4. streaming QUIC, accept and refuse legs     (commo/QuicStreamingTest.java
#      against commo/fake-quic-server.py, aioquic in a pinned venv)
#   5. TLS server-purpose canary                  (dev/g1/headless/test/tls-purpose.sh)
#   6. CoT round-trip vs fake-cot-server.py       (dev/g1/headless/run.sh)
#
# usage: commo.sh UPSTREAM_55   (needs dev/g1/native-dist from build-native.sh,
#                                and what build-commo.sh needs)
# exit:  0 every step green; non-zero the first that failed
set -euo pipefail

G55="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$G55/../../.." && pwd)"
G1="$ROOT/dev/g1"
# shellcheck source-path=SCRIPTDIR source=runtime.sh
source "$G55/runtime.sh"
DIST="$G55/build/commo-dist"
NGTCP2="$G55/build/ngtcp2"
WORK="$G55/build/commo-test"
QUIC_PORT="${QUIC_TEST_PORT:-18190}"
AIOQUIC_VERSION="1.7.2"
COT_PORT="${COT_TEST_PORT:-18087}"
PASS=atakatak

step() { printf '\n[g55-commo] %s\n' "$*"; }
die() { printf '\n[g55-commo] FATAL: %s\n' "$*" >&2; exit 2; }

[[ $# -eq 1 ]] || die "usage: commo.sh UPSTREAM_55"
UPSTREAM="$(cd "$1" && pwd)" || die "no such directory: $1"
[[ -d "$UPSTREAM/commoncommo/core/impl" ]] || die "no commoncommo in $UPSTREAM (sparse-checkout add commoncommo)"
for f in libtakengine.dylib libtakenginejni.dylib; do
  [[ -f "$G1/native-dist/$f" ]] || die "$G1/native-dist/$f missing — run dev/g1/build-native.sh"
done
JDK8="$(g55_jdk_home 8)" || die "no JDK 8 (or set G55_JDK8_HOME)"
OPENSSL_CLI="$(brew --prefix openssl@3)/bin/openssl"

step "1/6 ngtcp2 against openssl@3"
bash "$G55/commo/fetch-ngtcp2.sh"

step "2/6 5.5 commo (build-commo.sh) → $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"
for f in "$G1"/native-dist/libtakengine.dylib "$G1"/native-dist/libtakenginejni.dylib \
         "$G1"/native-dist/libEGL.dylib "$G1"/native-dist/libGLESv2.dylib; do
  [[ -f "$f" ]] && cp "$f" "$DIST/"
done
JAVA_HOME="$JDK8" \
MACTAK_COMMO_SRC="$UPSTREAM/commoncommo" \
MACTAK_COMMO_PATCHES="$G55/patches/commo" \
MACTAK_COMMO_WORK="$G55/build/commo" \
MACTAK_NATIVE_DIST="$DIST" \
MACTAK_NGTCP2_PREFIX="$NGTCP2" \
  bash "$G1/build-commo.sh"

step "3/6 linkage: openssl@3 only, ngtcp2 static"
for lib in libcommoncommo libcommoncommojni; do
  linkage="$(otool -L "$DIST/$lib.dylib")"
  if grep -Eq 'openssl@4|libngtcp2' <<<"$linkage"; then
    die "$lib.dylib links a second OpenSSL or a shared ngtcp2: $(grep -E 'openssl|ngtcp2' <<<"$linkage" | tr -s ' ')"
  fi
done
nm -gU "$DIST/libcommoncommo.dylib" | grep -q '_ngtcp2_crypto_ossl_configure_client_session' \
  || die "libcommoncommo.dylib does not carry ngtcp2's ossl backend"
echo "[g55-commo] ok: one OpenSSL runtime (openssl@3), ngtcp2 + crypto_ossl inside libcommoncommo"

step "4/6 streaming QUIC (commo client → fake-quic-server.py, ngtcp2 ossl backend)"
rm -rf "$WORK"
mkdir -p "$WORK/classes"
VENV="$G55/build/quic-venv"
if ! "$VENV/bin/python" -c "import aioquic; assert aioquic.__version__ == '$AIOQUIC_VERSION'" 2>/dev/null; then
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q "aioquic==$AIOQUIC_VERSION"
fi
make_pki() {   # one CA; a serverAuth leaf, a clientAuth-only impostor, a client
  printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$WORK/ca.ext"
  "$OPENSSL_CLI" req -new -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.csr" \
    -subj "/CN=mactak-quic-test-ca" 2>/dev/null
  "$OPENSSL_CLI" x509 -req -in "$WORK/ca.csr" -signkey "$WORK/ca.key" -out "$WORK/ca.crt" \
    -days 2 -extfile "$WORK/ca.ext" 2>/dev/null
  local name ext
  for name in server impostor client; do
    case "$name" in
      server)   ext="extendedKeyUsage=serverAuth" ;;
      *)        ext="extendedKeyUsage=clientAuth" ;;
    esac
    printf '%s\n' "$ext" > "$WORK/$name.ext"
    "$OPENSSL_CLI" req -new -newkey rsa:2048 -nodes -keyout "$WORK/$name.key" \
      -out "$WORK/$name.csr" -subj "/CN=$name" 2>/dev/null
    "$OPENSSL_CLI" x509 -req -in "$WORK/$name.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
      -CAcreateserial -out "$WORK/$name.crt" -days 2 -extfile "$WORK/$name.ext" 2>/dev/null
    "$OPENSSL_CLI" pkcs12 -export -in "$WORK/$name.crt" -inkey "$WORK/$name.key" \
      -certfile "$WORK/ca.crt" -out "$WORK/$name.p12" -passout "pass:$PASS" -name "$name"
  done
  "$OPENSSL_CLI" pkcs12 -export -nokeys -in "$WORK/ca.crt" \
    -out "$WORK/truststore.p12" -passout "pass:$PASS" -name ca
}
make_pki
"$JDK8/bin/javac" -Xlint:all -Werror -cp "$DIST/jcommoncommo.jar" -d "$WORK/classes" \
  "$G55/commo/QuicStreamingTest.java"
quic_server=""
# shellcheck disable=SC2317,SC2329  # invoked via trap
stop_servers() {
  if [[ -n "$quic_server" ]]; then kill "$quic_server" 2>/dev/null || true; fi
  if [[ -n "${cot_server:-}" ]]; then kill "$cot_server" 2>/dev/null || true; fi
}
trap stop_servers EXIT
quic_leg() {   # quic_leg SERVER_CERT accept|refuse PORT
  local server_log="$WORK/quic-$1.server.log"
  "$VENV/bin/python" "$G55/commo/fake-quic-server.py" "$3" "$WORK/$1.crt" "$WORK/$1.key" \
    > "$server_log" 2>&1 &
  quic_server=$!
  sleep 1
  "$JDK8/bin/java" -cp "$DIST/jcommoncommo.jar:$WORK/classes" QuicStreamingTest \
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
    echo "PASS: the server completed a takstream handshake and received the marker over QUIC"
  fi
}
quic_leg server accept "$QUIC_PORT"
quic_leg impostor refuse "$((QUIC_PORT + 1))"

# The headless launcher against 5.5 commo: its own class dir, and no
# -Werror on deprecations (5.5 deprecates the addStreamingInterface
# overload HeadlessCLI calls; NOTES.md §Commo)
export JAVA_HOME="$JDK8" MACTAK_NATIVE_DIST="$DIST"
export MACTAK_HEADLESS_CLASSES="$G55/build/headless-classes" MACTAK_JAVAC_LINT="all,-deprecation"

step "5/6 TLS server-purpose canary on 5.5 commo"
bash "$G1/headless/test/tls-purpose.sh"

step "6/6 CoT round-trip on 5.5 commo vs fake-cot-server.py :$COT_PORT"
python3 "$G1/headless/fake-cot-server.py" "$COT_PORT" > "$WORK/cot-server.log" 2>&1 &
cot_server=$!
sleep 1
TAK_PORT="$COT_PORT" bash "$G1/headless/run.sh" 15

step "PASS: 5.5 commo builds on openssl@3, speaks QUIC, and passes the G1 TLS and round-trip gates"
