#!/usr/bin/env bash
#
# G2.4b: build the GDAL SWIG Java bindings (org.gdal.* → gdal.jar +
# libgdalalljni.dylib) against the Homebrew libgdal the engine already links,
# and stage them into dev/g2/gdal-java-dist/.
#
# Why this exists: the engine's raster path (GdalTileReader, GdalLayerInfo,
# GdalDatasetProjection2 — 22 classes) binds org.gdal, which the transplant
# jar does not ship and Homebrew gdal does not build (trap 17, NOTES.md).
# Upstream builds them in takthirdparty/mk/gdal.mk from its gdal-2.4.4-mod
# tree; here they must match the *installed* GDAL, so the wrapper sources
# are generated from the matching release tarball and linked against
# $(gdal-config --libs) — one libgdal instance in the process, shared with
# libtakengine.
#
# What gets done:
#   - gdal-<ver>.tar.gz (OSGeo release, sha256-pinned) → dev/g2/build/gdal-java/
#   - swig -java for gdalconst (C) + gdal ogr osr gnm (C++), exactly as
#     swig/java/CMakeLists.txt does (-Wall, -package org.gdal.<pkg>)
#   - clang++ → libgdalalljni.dylib (install name @rpath/…, adhoc-signed)
#   - javac --release 21 → gdal.jar
#   - PROVENANCE.txt: versions, tarball sha256, artifact sha256s
#
# Requires: brew swig gdal; JDK 21 (dev/jdk.sh finds it).
# Usage: dev/g2/fetch-gdal-java.sh [dest-dir]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2
ROOT="$(cd "$HERE/../.." && pwd)"
DEST="${1:-$HERE/gdal-java-dist}"
WORK="$HERE/build/gdal-java"

log() { printf '[fetch-gdal-java] %s\n' "$*"; }
die() { printf '[fetch-gdal-java] FATAL: %s\n' "$*" >&2; exit 1; }

# Pinned release tarballs: the bindings are generated from the SWIG interface
# files of the *same* GDAL version Homebrew installed (ABI + API must match).
# Add a case when Homebrew bumps gdal; the script refuses an unpinned version.
pinned_sha256() {
  case "$1" in
    3.13.3) echo 5e0c388d83da2d686cc00a40272882432cdb54edff43d4af173e532844a0a0ea ;;
    *) echo "" ;;
  esac
}

command -v swig >/dev/null || die "swig not found (brew install swig)"
command -v gdal-config >/dev/null || die "gdal-config not found (brew install gdal)"
# shellcheck source=SCRIPTDIR/../jdk.sh
source "$ROOT/dev/jdk.sh"
JDK="$(mactak_jdk_home 21 || true)"
[[ -n "$JDK" && -x "$JDK/bin/javac" ]] || die "JDK 21 not found (dev/jdk.sh)"

VER="$(gdal-config --version)"
SHA="$(pinned_sha256 "$VER")"
[[ -n "$SHA" ]] || die "installed gdal $VER has no pinned tarball sha256 — add it to pinned_sha256 in $0"
GDAL_LIB="$(gdal-config --prefix)/lib/libgdal.dylib"
[[ -f "$GDAL_LIB" ]] || die "libgdal.dylib not at $GDAL_LIB"
# The engine links Homebrew's libgdal by install name; the wrapper must too.
ENGINE="$ROOT/dev/g1/native-dist/libtakengine.dylib"
if [[ -f "$ENGINE" ]]; then
  eng_gdal="$(otool -L "$ENGINE" | awk '/libgdal/ { print $1 }')"
  [[ -n "$eng_gdal" ]] || die "libtakengine.dylib does not link a libgdal"
  [[ "$(otool -D "$GDAL_LIB" | awk 'NR == 2 { print $1 }')" == "$eng_gdal" ]] \
    || die "engine links $eng_gdal but gdal-config points at $GDAL_LIB — rebuild one or the other"
fi

mkdir -p "$WORK" "$DEST"
TARBALL="$WORK/gdal-$VER.tar.gz"
SRC="$WORK/gdal-$VER"
if [[ ! -f "$TARBALL" ]] || ! echo "$SHA  $TARBALL" | shasum -a 256 -c - >/dev/null 2>&1; then
  log "downloading gdal-$VER.tar.gz"
  rm -f "$TARBALL"
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --retry-max-time 600 \
    -o "$TARBALL.tmp" "https://github.com/OSGeo/gdal/releases/download/v$VER/gdal-$VER.tar.gz"
  echo "$SHA  $TARBALL.tmp" | shasum -a 256 -c - >/dev/null || { rm -f "$TARBALL.tmp"; die "sha256 mismatch for gdal-$VER.tar.gz"; }
  mv "$TARBALL.tmp" "$TARBALL"
fi
if [[ ! -d "$SRC/swig/include/java" ]]; then
  log "extracting swig/ from the tarball"
  rm -rf "$SRC"
  # osr.i %includes ../../ogr/ogr_srs_api.h from the source tree.
  tar -xzf "$TARBALL" -C "$WORK" "gdal-$VER/swig/include" "gdal-$VER/ogr/ogr_srs_api.h" "gdal-$VER/VERSION"
fi
[[ "$(tr -d '[:space:]' < "$SRC/VERSION")" == "$VER" ]] || die "tarball VERSION != $VER"

# --- swig ------------------------------------------------------------------
GEN="$WORK/gen"
rm -rf "$GEN"; mkdir -p "$GEN"
SWIG_INC=(-I"$SRC/swig/include" -I"$SRC/swig/include/java")
swig_pkg() {  # <pkg> [-c++]
  local pkg="$1"; shift
  local ext=c; [[ "${1:-}" == "-c++" ]] && ext=cpp
  mkdir -p "$GEN/org/gdal/$pkg"
  # Matches swig/java/CMakeLists.txt's gdal_java_wrap(); run from the
  # source's swig/java dir like it does (relative %includes).
  (cd "$SRC/swig/include" && swig -Wall "${SWIG_INC[@]}" -outdir "$GEN/org/gdal/$pkg/" \
     -package "org.gdal.$pkg" "$@" -java -o "$GEN/org/gdal/$pkg/${pkg}_wrap.$ext" "$SRC/swig/include/$pkg.i") \
     > "$WORK/swig-$pkg.log" 2>&1 || { cat "$WORK/swig-$pkg.log" >&2; die "swig failed for $pkg"; }
  log "swig $pkg → $(find "$GEN/org/gdal/$pkg" -name '*.java' | wc -l | tr -d ' ') classes"
}
swig_pkg gdalconst
for pkg in gdal ogr osr gnm; do swig_pkg "$pkg" -c++; done

# --- native ----------------------------------------------------------------
JNI_LIB="$DEST/libgdalalljni.dylib"
log "compiling libgdalalljni.dylib against $(gdal-config --prefix)"
OBJ="$WORK/obj"; rm -rf "$OBJ"; mkdir -p "$OBJ"
# -fno-strict-aliasing: required by SWIG's upcast code (GDAL changeset 16006).
read -r -a GDAL_CFLAGS <<< "$(gdal-config --cflags)"
CFLAGS_COMMON=(-arch arm64 -O2 -fno-strict-aliasing -Wno-deprecated-declarations
  "${GDAL_CFLAGS[@]}" -I"$ROOT/dev/g1/jdk-include" -I"$ROOT/dev/g1/jdk-include/darwin")
: > "$WORK/clang.log"
for pkg in gdal ogr osr gnm; do
  clang++ "${CFLAGS_COMMON[@]}" -std=c++17 -c "$GEN/org/gdal/$pkg/${pkg}_wrap.cpp" -o "$OBJ/$pkg.o" \
    >> "$WORK/clang.log" 2>&1 || { tail -40 "$WORK/clang.log" >&2; die "clang++ failed on $pkg (full log: $WORK/clang.log)"; }
done
clang "${CFLAGS_COMMON[@]}" -c "$GEN/org/gdal/gdalconst/gdalconst_wrap.c" -o "$OBJ/gdalconst.o" \
  >> "$WORK/clang.log" 2>&1 || { tail -40 "$WORK/clang.log" >&2; die "clang failed on gdalconst (full log: $WORK/clang.log)"; }
# shellcheck disable=SC2046
clang++ -arch arm64 -dynamiclib -o "$JNI_LIB" -install_name "@rpath/libgdalalljni.dylib" \
  "$OBJ"/*.o $(gdal-config --libs) \
  >> "$WORK/clang.log" 2>&1 || { tail -40 "$WORK/clang.log" >&2; die "link failed (full log: $WORK/clang.log)"; }
# Keep stderr: a swallowed codesign failure exits undiagnosable (fetch-angle trap).
codesign --force --sign - "$JNI_LIB" >/dev/null
# grep without -q: early exit + pipefail = SIGPIPE false failure (G1 trap 2).
otool -L "$JNI_LIB" | grep 'libgdal' >/dev/null || die "libgdalalljni does not link libgdal"
nm -gU "$JNI_LIB" | grep ' T _Java_org_gdal_gdal_gdalJNI_AllRegister$' >/dev/null || die "libgdalalljni lacks the JNI exports"

# --- jar -------------------------------------------------------------------
CLASSES="$WORK/classes"
rm -rf "$CLASSES"; mkdir -p "$CLASSES"
log "javac org.gdal.* (--release 21)"
find "$GEN/org" -name '*.java' -print0 | xargs -0 "$JDK/bin/javac" --release 21 -nowarn -encoding UTF-8 \
  -d "$CLASSES" > "$WORK/javac.log" 2>&1 || { tail -40 "$WORK/javac.log" >&2; die "javac failed (full log: $WORK/javac.log)"; }
printf 'Manifest-Version: 1.0\nImplementation-Title: GDAL Java bindings\nImplementation-Version: %s\nImplementation-Vendor: OSGeo (built by macTAK dev/g2/fetch-gdal-java.sh)\n' "$VER" > "$WORK/MANIFEST.MF"
"$JDK/bin/jar" cfm "$DEST/gdal.jar" "$WORK/MANIFEST.MF" -C "$CLASSES" org
"$JDK/bin/jar" tf "$DEST/gdal.jar" | grep '^org/gdal/gdal/gdal.class$' >/dev/null || die "gdal.jar lacks org.gdal.gdal.gdal"

{
  echo "gdal: $VER ($(gdal-config --prefix))"
  echo "libgdal: $(otool -D "$GDAL_LIB" | awk 'NR == 2 { print $1 }')"
  echo "swig: $(swig -version | awk '/SWIG Version/ { print $3 }')"
  echo "jdk: $("$JDK/bin/javac" -version 2>&1)"
  echo "source: https://github.com/OSGeo/gdal/releases/download/v$VER/gdal-$VER.tar.gz"
  echo "sha256 gdal-$VER.tar.gz: $SHA"
  echo "staged: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "license: GDAL, MIT/X (https://gdal.org/license.html)"
  for f in gdal.jar libgdalalljni.dylib; do echo "sha256 $f: $(shasum -a 256 "$DEST/$f" | cut -d' ' -f1)"; done
} > "$DEST/PROVENANCE.txt"
log "GDAL Java bindings staged in $DEST"
sed 's/^/[fetch-gdal-java]   /' "$DEST/PROVENANCE.txt"
