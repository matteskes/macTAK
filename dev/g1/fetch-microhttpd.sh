#!/usr/bin/env bash
#
# libmicrohttpd for commo, without HTTPS: static, no GnuTLS. build-commo.sh
# runs this first; the build is cached.
#
# commo runs libmicrohttpd as its mission-package web server, started
# without TLS (MHD_start_daemon with MHD_USE_SELECT_INTERNALLY |
# MHD_ALLOW_SUSPEND_RESUME, core/impl/missionpackagemanager.cpp). Homebrew's
# libmicrohttpd links GnuTLS for HTTPS, which brought GnuTLS, nettle, gmp,
# p11-kit, libtasn1, libidn2 and libunistring into the process: a second
# TLS stack beside OpenSSL 3 that nothing uses. This build is the release
# Homebrew packages, configured --disable-https, as a static archive
# libcommoncommo links in (build-commo.sh puts it ahead of Homebrew's).
#
# usage: fetch-microhttpd.sh   → dev/g1/build-microhttpd/prefix/{include,lib}
# needs: make, curl (the system one fetches), shasum
set -euo pipefail

G1="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g1
WORK="$G1/build-microhttpd/src"
PREFIX="$G1/build-microhttpd/prefix"
VERSION="1.0.10"
# Homebrew's libmicrohttpd formula pins the same tarball and checksum
SHA256="04bfe8ef75db7d629a33de767599765cecadc56274a39822d5d081030d577685"
# GNU's own server first. ftpmirror.gnu.org redirects to a nearby volunteer
# mirror, and on 2026-11-25 the one a CI runner was sent to had an expired
# certificate (curl exit 60 on every retry, all sent to the same mirror), so
# it is only the fallback. The checksum holds the tarball, whichever serves it.
URLS=(
  "https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-$VERSION.tar.gz"
  "https://ftpmirror.gnu.org/libmicrohttpd/libmicrohttpd-$VERSION.tar.gz"
)

log() { printf '[g1-microhttpd] %s\n' "$*"; }
die() { printf '[g1-microhttpd] FATAL: %s\n' "$*" >&2; exit 2; }

for t in curl make shasum; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done

STAMP="$PREFIX/.version-$VERSION-nohttps"
if [[ -f "$PREFIX/lib/libmicrohttpd.a" && -f "$STAMP" ]]; then
  log "libmicrohttpd $VERSION (no HTTPS) already built in $PREFIX"
  exit 0
fi

rm -rf "$WORK" "$PREFIX"
mkdir -p "$WORK"
tarball="$WORK/libmicrohttpd-$VERSION.tar.gz"
fetched=""
for url in "${URLS[@]}"; do
  log "fetching $url"
  if curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "$tarball" "$url"; then
    fetched="$url"
    break
  fi
  log "failed from $url"
done
[[ -n "$fetched" ]] || die "libmicrohttpd $VERSION couldn't be fetched from any of: ${URLS[*]}"
echo "$SHA256  $tarball" | shasum -a 256 -c - >/dev/null || die "libmicrohttpd tarball checksum mismatch"
tar -xzf "$tarball" -C "$WORK"

log "configuring (static, --disable-https: no GnuTLS)"
(cd "$WORK/libmicrohttpd-$VERSION" && \
  MACOSX_DEPLOYMENT_TARGET=27.0 ./configure \
    --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-https --without-gnutls \
    --disable-doc --disable-examples --disable-tools --disable-curl \
    >"$WORK/configure.log" 2>&1) \
  || { tail -n 30 "$WORK/configure.log" >&2; die "configure failed (log: $WORK/configure.log)"; }
if ! make -C "$WORK/libmicrohttpd-$VERSION" -j"$(sysctl -n hw.ncpu)" >"$WORK/build.log" 2>&1 \
   || ! make -C "$WORK/libmicrohttpd-$VERSION" install >>"$WORK/build.log" 2>&1; then
  tail -n 30 "$WORK/build.log" >&2
  die "build failed (log: $WORK/build.log)"
fi

[[ -f "$PREFIX/lib/libmicrohttpd.a" && -f "$PREFIX/include/microhttpd.h" ]] \
  || die "libmicrohttpd.a or microhttpd.h missing from $PREFIX"
# no TLS library inside: capture, then grep (no grep -q at a pipe's end)
syms="$(nm -u "$PREFIX/lib/libmicrohttpd.a" 2>/dev/null)"
if grep -E '_gnutls_|_gcry_' <<<"$syms" >/dev/null; then
  die "libmicrohttpd.a still references GnuTLS"
fi
touch "$STAMP"
log "PASS: libmicrohttpd $VERSION static, without HTTPS, in $PREFIX"
