#!/usr/bin/env bash
#
# ngtcp2 for commo's QUIC (5.5 compiles it unconditionally), on the OpenSSL
# commo already uses. build-commo.sh runs this first; the build is cached.
#
# 5.5 commo links ngtcp2 with its quictls backend; upstream builds
# ngtcp2 1.6.0 against openssl-3.0.14-quic1 (takthirdparty), and OpenSSL
# 3.0 reached end of life on 2026-09-07. Homebrew's libngtcp2 ships the
# ossl backend (OpenSSL 3.5's own QUIC TLS API) but links openssl@4, a
# second OpenSSL runtime beside commo's openssl@3. So: the same ngtcp2
# release Homebrew packages, built here against Homebrew's openssl@3,
# static, library only (dev/spike/g55/NOTES.md §Commo).
#
# usage: fetch-ngtcp2.sh               → dev/g1/build-ngtcp2/prefix/{include,lib}
# needs: brew openssl@3 (≥ 3.5, for SSL_set_quic_tls_cbs), pkg-config, curl
set -euo pipefail

G1="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g1
WORK="$G1/build-ngtcp2/src"
PREFIX="$G1/build-ngtcp2/prefix"
VERSION="1.26.0"
# Homebrew's libngtcp2 formula pins the same tarball and checksum
SHA256="7804aa0fa1c39942ba322a90805824c37231f7675b08d0c3cc4332858a7b085e"
URL="https://github.com/ngtcp2/ngtcp2/releases/download/v$VERSION/ngtcp2-$VERSION.tar.xz"
MIN_OPENSSL="3.5"

log() { printf '[g1-ngtcp2] %s\n' "$*"; }
die() { printf '[g1-ngtcp2] FATAL: %s\n' "$*" >&2; exit 2; }

for t in curl pkg-config make shasum; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
OPENSSL="$(brew --prefix openssl@3 2>/dev/null || true)"
[[ -n "$OPENSSL" && -d "$OPENSSL/lib" ]] || die "brew openssl@3 missing — brew install openssl@3"
openssl_version="$(PKG_CONFIG_PATH="$OPENSSL/lib/pkgconfig" pkg-config --modversion openssl)"
[[ "$(printf '%s\n%s\n' "$MIN_OPENSSL" "$openssl_version" | sort -V | head -1)" == "$MIN_OPENSSL" ]] \
  || die "openssl@3 is $openssl_version; the ossl backend needs ≥ $MIN_OPENSSL (SSL_set_quic_tls_cbs)"

if [[ -f "$PREFIX/lib/libngtcp2_crypto_ossl.a" && -f "$PREFIX/.version-$VERSION" ]]; then
  log "ngtcp2 $VERSION already built in $PREFIX"
  exit 0
fi

rm -rf "$WORK" "$PREFIX"
mkdir -p "$WORK"
tarball="$WORK/ngtcp2-$VERSION.tar.xz"
log "fetching $URL"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "$tarball" "$URL"
echo "$SHA256  $tarball" | shasum -a 256 -c - >/dev/null || die "ngtcp2 tarball checksum mismatch"
tar -xJf "$tarball" -C "$WORK"

log "configuring against openssl@3 $openssl_version (library only, static)"
(cd "$WORK/ngtcp2-$VERSION" && \
  PKG_CONFIG_PATH="$OPENSSL/lib/pkgconfig" ./configure \
    --prefix="$PREFIX" --enable-lib-only --disable-shared --enable-static \
    --with-openssl --without-gnutls --without-boringssl --without-picotls \
    --without-wolfssl --without-libnghttp3 --without-jemalloc \
    >"$WORK/configure.log" 2>&1) \
  || { tail -n 30 "$WORK/configure.log" >&2; die "configure failed (log: $WORK/configure.log)"; }
make -C "$WORK/ngtcp2-$VERSION" -j"$(sysctl -n hw.ncpu)" install >"$WORK/build.log" 2>&1 \
  || { tail -n 30 "$WORK/build.log" >&2; die "build failed (log: $WORK/build.log)"; }

[[ -f "$PREFIX/lib/libngtcp2.a" && -f "$PREFIX/lib/libngtcp2_crypto_ossl.a" \
   && -f "$PREFIX/include/ngtcp2/ngtcp2_crypto_ossl.h" ]] \
  || die "the ossl backend was not built (configure did not find OpenSSL's QUIC API?)"
touch "$PREFIX/.version-$VERSION"
log "PASS: ngtcp2 $VERSION + crypto_ossl (openssl@3 $openssl_version) in $PREFIX"
