#!/usr/bin/env bash
#
# Build macTAK's own GDAL, PROJ and libspatialite from the pinned tarballs in
# dev/deps/deps.lock into dev/deps/dist (bin, include, lib, share).
#
# Why not Homebrew's bottles: Homebrew's GDAL links OpenSSL 4 directly and
# through libpq, thrift and its curl, and pulls in ~85 packages (PDF, NetCDF,
# HDF5, Arrow, PostgreSQL, ...) for formats macTAK refuses to open. This build
# has no curl and no TLS at all, and only the drivers macTAK allows
# (dev/g1/jni-extra/mactak_gdal.cpp's allowlist), so the process keeps one TLS
# stack, OpenSSL 3, and a GDAL bump is a deliberate edit to deps.lock.
#
# What still comes from Homebrew (no TLS in any of them): sqlite (one runtime
# for the whole process: PROJ, GDAL, libspatialite and the engine), geos,
# libtiff (PROJ's grids), openjpeg (JP2OpenJPEG), libkml with minizip and
# uriparser (LIBKML), freexl, minizip and librttopo (libspatialite).
# GDAL builds its own internal libtiff, libgeotiff, libjpeg, libpng, giflib
# and json-c, with renamed symbols: Homebrew's libgeotiff links Homebrew's
# PROJ, which would put two PROJs in the process.
#
# Every library's install name is @rpath/<name>, with @loader_path as its
# rpath, so the set can be staged next to the engine.
#
# Skips the build when dist/BUILD-STAMP matches the hash of deps.lock and this
# script (CI caches dist on the same key); --force rebuilds.
#
# Needs: Homebrew cmake ninja pkgconf sqlite geos libtiff openjpeg libkml
#        minizip uriparser freexl librttopo; curl and shasum.
# Usage: dev/deps/build-deps.sh [--force]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/deps
LOCK="$HERE/deps.lock"
DIST="${MACTAK_DEPS_DIST:-$HERE/dist}"
WORK="$HERE/build"
HB="$(brew --prefix)"
JOBS="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET=27.0

log() { printf '\n[deps] %s\n' "$*"; }
die() { printf '\n[deps] FATAL: %s\n' "$*" >&2; exit 1; }

BREW_NEEDS=(cmake ninja pkgconf sqlite geos libtiff jpeg-turbo webp xz zstd openjpeg libkml minizip uriparser freexl librttopo)
# the Homebrew libraries these link, at the versions Brewfile.lock.json pins
# (#151): a cached dist is only as good as the libraries it was built against
python3 -I "$HERE/brew-pins.py" "${BREW_NEEDS[@]}" || die "Homebrew drifted from Brewfile.lock.json (above)"

# the pins, this script, and the Homebrew versions the result links (a moved
# Homebrew pin rebuilds against the new library, as CI's cache key does)
stamp() { cat "$LOCK" "${BASH_SOURCE[0]}" "$HERE/../../Brewfile.lock.json" | shasum -a 256 | cut -d' ' -f1; }
if [[ "${1:-}" != "--force" && -f "$DIST/BUILD-STAMP" && "$(cat "$DIST/BUILD-STAMP")" == "$(stamp)" ]]; then
  log "dist is current ($DIST); --force rebuilds"
  exit 0
fi

for f in "${BREW_NEEDS[@]}"; do
  brew list --versions "$f" >/dev/null 2>&1 || die "brew formula missing: $f (brew bundle, see Brewfile)"
done

# pin NAME -> "version sha256 url" from deps.lock
pin() {
  awk -v n="$1" '$1 == n { print $2, $3, $4 }' "$LOCK"
}

# fetch NAME: download and verify the pinned tarball, extract it fresh;
# prints the source directory
fetch() {
  local name="$1" sha url tarball
  read -r _ sha url <<<"$(pin "$name")"
  [[ -n "$url" ]] || die "$name is not in $LOCK"
  tarball="$WORK/$(basename "$url")"
  if [[ ! -f "$tarball" ]] || ! echo "$sha  $tarball" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$tarball.tmp" "$url" >&2
    echo "$sha  $tarball.tmp" | shasum -a 256 -c - >/dev/null \
      || { rm -f "$tarball.tmp"; die "sha256 mismatch for $(basename "$url")"; }
    mv "$tarball.tmp" "$tarball"
  fi
  rm -rf "$WORK/src/$name"
  mkdir -p "$WORK/src/$name"
  tar -xzf "$tarball" -C "$WORK/src/$name" --strip-components 1
  echo "$WORK/src/$name"
}

SQLITE="$HB/opt/sqlite"
CMAKE_COMMON=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$DIST"
  -DCMAKE_INSTALL_NAME_DIR=@rpath
  -DCMAKE_INSTALL_RPATH=@loader_path
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_PREFIX_PATH="$DIST;$HB"
  -DBUILD_TESTING=OFF
  # one sqlite for the whole process: Homebrew's, by its opt path, as the
  # engine links it (dev/g1/build-native.sh)
  -DSQLite3_INCLUDE_DIR="$SQLITE/include"
  -DSQLite3_LIBRARY="$SQLITE/lib/libsqlite3.dylib"
)

# a clean build every time: Ninja would reuse objects from the last pin
rm -rf "$DIST" "$WORK/proj" "$WORK/gdal"
mkdir -p "$WORK" "$DIST"

# --- PROJ -------------------------------------------------------------------
log "PROJ $(pin proj | cut -d' ' -f1): no curl, no network grids"
src="$(fetch proj)"
cmake -S "$src" -B "$WORK/proj" "${CMAKE_COMMON[@]}" \
  -DENABLE_CURL=OFF \
  -DENABLE_TIFF=ON \
  -DBUILD_APPS=OFF \
  -DEXE_SQLITE3="$SQLITE/bin/sqlite3" \
  > "$WORK/proj-configure.log" 2>&1 || { tail -30 "$WORK/proj-configure.log" >&2; die "PROJ configure failed"; }
cmake --build "$WORK/proj" -j "$JOBS" > "$WORK/proj-build.log" 2>&1 \
  || { tail -30 "$WORK/proj-build.log" >&2; die "PROJ build failed"; }
cmake --install "$WORK/proj" > /dev/null

# --- GDAL -------------------------------------------------------------------
# Only the drivers mactak_gdal.cpp's allowlist names, with no network code.
# Some drivers come with others from the same source: SQLite (GPKG needs
# it), COG (GTiff), BIGGIF (GIF), RPFTOC and ECRGTOC (NITF), and GeoJSONSeq,
# ESRIJSON and TopoJSON (GeoJSON). keepOffline() skips them all at runtime.
# VRT always builds and registers (GDAL uses it internally, and 3.13's CMake
# defines FRMT_vrt even with GDAL_ENABLE_DRIVER_VRT=OFF); it is skipped at
# runtime like the rest. dev/deps/check-gdal-drivers.sh fails on any other
# driver.
log "GDAL $(pin gdal | cut -d' ' -f1): the allowlisted drivers only, no curl"
src="$(fetch gdal)"
cmake -S "$src" -B "$WORK/gdal" "${CMAKE_COMMON[@]}" \
  -DGDAL_USE_EXTERNAL_LIBS=OFF \
  -DGDAL_USE_INTERNAL_LIBS=ON \
  -DGDAL_USE_SQLITE3=ON \
  -DGDAL_USE_GEOS=ON \
  -DGDAL_USE_OPENJPEG=ON \
  -DGDAL_USE_LIBKML=ON \
  -DGDAL_USE_EXPAT=ON \
  -DGDAL_USE_ICONV=ON \
  -DGDAL_BUILD_OPTIONAL_DRIVERS=OFF \
  -DOGR_BUILD_OPTIONAL_DRIVERS=OFF \
  -DGDAL_ENABLE_DRIVER_GTIFF=ON \
  -DGDAL_ENABLE_DRIVER_NITF=ON \
  -DGDAL_ENABLE_DRIVER_DTED=ON \
  -DGDAL_ENABLE_DRIVER_SRTMHGT=ON \
  -DGDAL_ENABLE_DRIVER_JP2OPENJPEG=ON \
  -DGDAL_ENABLE_DRIVER_PNG=ON \
  -DGDAL_ENABLE_DRIVER_JPEG=ON \
  -DGDAL_ENABLE_DRIVER_GIF=ON \
  -DOGR_ENABLE_DRIVER_GEOJSON=ON \
  -DOGR_ENABLE_DRIVER_SQLITE=ON \
  -DOGR_ENABLE_DRIVER_GPKG=ON \
  -DOGR_ENABLE_DRIVER_KML=ON \
  -DOGR_ENABLE_DRIVER_LIBKML=ON \
  -DOGR_ENABLE_DRIVER_SHAPE=ON \
  -DOGR_ENABLE_DRIVER_GPX=ON \
  -DOGR_ENABLE_DRIVER_FLATGEOBUF=ON \
  -DENABLE_GNM=OFF \
  -DBUILD_APPS=OFF \
  -DBUILD_PYTHON_BINDINGS=OFF \
  -DBUILD_JAVA_BINDINGS=OFF \
  -DBUILD_CSHARP_BINDINGS=OFF \
  > "$WORK/gdal-configure.log" 2>&1 || { tail -40 "$WORK/gdal-configure.log" >&2; die "GDAL configure failed"; }
cmake --build "$WORK/gdal" -j "$JOBS" > "$WORK/gdal-build.log" 2>&1 \
  || { tail -40 "$WORK/gdal-build.log" >&2; die "GDAL build failed"; }
cmake --install "$WORK/gdal" > /dev/null

# --- libspatialite ----------------------------------------------------------
# Rebuilt only so it links this PROJ: Homebrew's links Homebrew's PROJ.
# Configured as Homebrew's formula is (geocallbacks, rttopo), but without
# libxml2: that is its XmlBLOB functions and its WFS client, whose HTTP calls
# libxml2 2.15 removed (Homebrew patches them out). The engine uses neither.
# Include paths are per package: a blanket $HB/include would put Homebrew's
# installed spatialite headers ahead of these.
log "libspatialite $(pin libspatialite | cut -d' ' -f1): against this PROJ"
src="$(fetch libspatialite)"
(
  cd "$src"
  export PKG_CONFIG_PATH="$DIST/lib/pkgconfig:$HB/opt/freexl/lib/pkgconfig:$HB/opt/librttopo/lib/pkgconfig:$HB/opt/minizip/lib/pkgconfig:$SQLITE/lib/pkgconfig"
  export CPPFLAGS="-I$DIST/include -I$SQLITE/include -I$HB/opt/freexl/include -I$HB/opt/librttopo/include -I$HB/opt/minizip/include -I$HB/opt/geos/include"
  export LDFLAGS="-L$DIST/lib -L$SQLITE/lib -L$HB/opt/freexl/lib -L$HB/opt/librttopo/lib -L$HB/opt/minizip/lib -L$HB/opt/geos/lib -Wl,-rpath,@loader_path"
  ./configure --prefix="$DIST" --disable-static --disable-examples \
    --enable-geocallbacks --enable-rttopo=yes --disable-libxml2 \
    --with-geosconfig="$HB/opt/geos/bin/geos-config" \
    > "$WORK/spatialite-configure.log" 2>&1 || { tail -30 "$WORK/spatialite-configure.log" >&2; exit 1; }
  make -j "$JOBS" > "$WORK/spatialite-build.log" 2>&1 || { tail -30 "$WORK/spatialite-build.log" >&2; exit 1; }
  make install > /dev/null
) || die "libspatialite build failed (logs in $WORK)"
# libtool records the absolute install path; make it @rpath like the rest
for lib in "$DIST"/lib/libspatialite*.dylib "$DIST"/lib/mod_spatialite*.dylib; do
  [[ -f "$lib" && ! -L "$lib" ]] || continue
  install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null
done

# --- checks -----------------------------------------------------------------
log "checking install names and links"
bad=0
for lib in "$DIST"/lib/*.dylib; do
  [[ -L "$lib" ]] && continue
  id="$(otool -D "$lib" | awk 'NR == 2')"
  [[ "$id" == @rpath/* ]] || { echo "  $lib: install name $id, want @rpath/..." >&2; bad=1; }
  # nothing may link a Homebrew PROJ/GDAL/libspatialite, curl or a TLS library
  links="$(otool -L "$lib" | tail -n +2)"
  if grep -E 'opt/(proj|gdal|libspatialite|curl|openssl|gnutls|libpq)/|libcurl|libssl|libcrypto' <<<"$links" >/dev/null; then
    echo "  $lib links a forbidden library:" >&2
    grep -E 'opt/(proj|gdal|libspatialite|curl|openssl|gnutls|libpq)/|libcurl|libssl|libcrypto' <<<"$links" >&2
    bad=1
  fi
done
(( bad == 0 )) || die "dist failed its link checks"

{
  echo "macTAK native deps, built $(date -u +%Y-%m-%dT%H:%M:%SZ) by dev/deps/build-deps.sh"
  grep -vE '^\s*(#|$)' "$LOCK"
  echo "macOS deployment target: $MACOSX_DEPLOYMENT_TARGET"
} > "$DIST/PROVENANCE.txt"
stamp > "$DIST/BUILD-STAMP"
log "OK: GDAL, PROJ and libspatialite in $DIST"
