#!/usr/bin/env bash
#
# libcurl for commo, on the OpenSSL commo already uses. build-commo.sh runs
# this first; the build is cached.
#
# commo's https paths (enrollment, FTPS file transfers, mission packages)
# verify a server by handing curl a callback that edits curl's OpenSSL
# SSL_CTX with OpenSSL calls of its own (CURLOPT_SSL_CTX_FUNCTION). That
# works only if curl's TLS library is the very OpenSSL commo links. Without
# this script commo linked Apple's /usr/lib/libcurl (LibreSSL) and its JNI
# library Homebrew's (openssl@4): given a CA, commo put an openssl@3 object
# into LibreSSL's SSL_CTX, and the process crashed in SSL_CTX_free or hung
# (G1 issue #157). So: the release Homebrew packages, built here against
# Homebrew's openssl@3, static, with only the protocols commo uses (HTTP,
# HTTPS, FTP, FTPS) and no default CA bundle (commo always passes its own
# CA, or turns verification off; nothing should trust a bundle we didn't
# choose).
#
# Symbol hiding is off: libcommoncommo links this archive and must export
# curl's API, because the JNI library calls curl_global_init and has to
# reach that copy, not link a second one (build-commo.sh). A hidden-symbol
# build leaves even curl_easy_init private to libcommoncommo.
#
# usage: fetch-curl.sh               → dev/g1/build-curl/prefix/{bin,include,lib}
# needs: brew openssl@3, pkg-config, make, curl (the system one fetches)
set -euo pipefail

G1="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g1
WORK="$G1/build-curl/src"
PREFIX="$G1/build-curl/prefix"
VERSION="8.23.0"
# Homebrew's curl formula pins the same tarball and checksum
SHA256="95b22eb32bf6d1fa6e3e9463bdb61cece3efc56d86576a9b3cbd428246a6d854"
URL="https://curl.se/download/curl-$VERSION.tar.bz2"

log() { printf '[g1-curl] %s\n' "$*"; }
die() { printf '[g1-curl] FATAL: %s\n' "$*" >&2; exit 2; }

for t in curl pkg-config make shasum; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
OPENSSL="$(brew --prefix openssl@3 2>/dev/null || true)"
[[ -n "$OPENSSL" && -d "$OPENSSL/lib" ]] || die "brew openssl@3 missing — brew install openssl@3"

# the version file also records the OpenSSL it was built against: a new
# openssl@3 from brew means a rebuild, not a curl compiled against old headers
openssl_version="$(PKG_CONFIG_PATH="$OPENSSL/lib/pkgconfig" pkg-config --modversion openssl)"
STAMP="$PREFIX/.version-$VERSION-openssl-$openssl_version"
if [[ -f "$PREFIX/lib/libcurl.a" && -f "$STAMP" ]]; then
  log "curl $VERSION (openssl@3 $openssl_version) already built in $PREFIX"
  exit 0
fi

rm -rf "$WORK" "$PREFIX"
mkdir -p "$WORK"
tarball="$WORK/curl-$VERSION.tar.bz2"
log "fetching $URL"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "$tarball" "$URL"
echo "$SHA256  $tarball" | shasum -a 256 -c - >/dev/null || die "curl tarball checksum mismatch"
tar -xjf "$tarball" -C "$WORK"

log "configuring against openssl@3 $openssl_version (static; HTTP(S) and FTP(S) only)"
(cd "$WORK/curl-$VERSION" && \
  PKG_CONFIG_PATH="$OPENSSL/lib/pkgconfig" ./configure \
    --prefix="$PREFIX" --disable-shared --enable-static \
    --with-openssl="$OPENSSL" --without-ca-bundle --without-ca-path \
    --without-libpsl --without-brotli --without-zstd --without-libidn2 \
    --without-nghttp2 --without-ngtcp2 --without-nghttp3 \
    --without-libssh2 --without-librtmp \
    --disable-ldap --disable-ldaps --disable-rtsp --disable-dict \
    --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
    --disable-smb --disable-smtp --disable-gopher --disable-mqtt \
    --disable-docs --disable-manual --disable-websockets --disable-ipfs \
    --disable-symbol-hiding \
    >"$WORK/configure.log" 2>&1) \
  || { tail -n 30 "$WORK/configure.log" >&2; die "configure failed (log: $WORK/configure.log)"; }
if ! make -C "$WORK/curl-$VERSION/lib" -j"$(sysctl -n hw.ncpu)" >"$WORK/build.log" 2>&1 \
   || ! make -C "$WORK/curl-$VERSION" install-exec install-data >>"$WORK/build.log" 2>&1; then
  tail -n 30 "$WORK/build.log" >&2
  die "build failed (log: $WORK/build.log)"
fi

[[ -f "$PREFIX/lib/libcurl.a" && -f "$PREFIX/include/curl/curl.h" && -x "$PREFIX/bin/curl-config" ]] \
  || die "libcurl.a, its headers or curl-config missing from $PREFIX"
"$PREFIX/bin/curl-config" --ssl-backends | grep -q '^OpenSSL' \
  || die "curl's TLS backend is not OpenSSL: $("$PREFIX/bin/curl-config" --ssl-backends)"
touch "$STAMP"
log "PASS: curl $VERSION static on openssl@3 $openssl_version in $PREFIX ($("$PREFIX/bin/curl-config" --protocols | tr '\n' ' '))"
