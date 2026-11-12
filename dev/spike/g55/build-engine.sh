#!/usr/bin/env bash
#
# Spike 1 (docs/rebase-study-5.5.md, next step 1): does the 5.5 engine
# (takkernel 8.30.5) build on macOS arm64 with Homebrew GDAL 3, without
# 3D Tiles?
#
# The core-engine half of dev/g1/build-native.sh, pointed at a 5.5 tree:
#   <5.5>/takkernel/engine/src/main  →  dev/spike/g55/build/engine (copy)
#   + dev/spike/g55/patches (the 5.5 series: gdal-drift-* first, then the
#     rest, sorted, at --fuzz=0 — build-native.sh's order and rule)
#   + GLES stub from <5.5>/khronos, nlohmann-json stand-in for tinygltf
#   → libtakengine.dylib, or the list of what failed to compile
#
# Differences from build-native.sh, each a spike decision (NOTES.md):
#   - 5.5 compiles the GLTF readers and the ASSIMP scene SPI on every
#     platform (4.6 wrapped them in #ifdef MSVC), so they need their
#     headers: tinygltf from upstream's own depends/tinygltf-2.4.1-mod
#     tarball (Git LFS), tinygltfloader from upstream's in-tree
#     takengine/thirdparty copy, assimp from Homebrew (upstream builds a
#     patched 4.0.1)
#   - formats/c3dt/ (cesium-native + draco, 3D Tiles) is left out, as G0
#     left out the LAS drivers; MacOSSources.cmake has no cesium-native
#     or draco paths, so a stock 5.5 macOS build cannot compile it. The
#     JNI glue's c3dt/ and interop/formats/c3dt/ go with it
#   - the JNI glue (libtakenginejni) compiles against the javac -h headers
#     committed in dev/spike/g55/jni-include (kernel/build-kernel-jars.sh)
#   - G1's JNI guard tests (dev/g1/jni-tests) build here; jni-tests.sh
#     and smoke.sh run them and the load canary
#   - ninja -k 0: one run lists every failing source, not just the first
#   - G55_GLES=angle links ANGLE (dev/g2/angle-dist) in the GLES slot, as
#     build-native.sh's MACTAK_GLES=angle; render.sh needs it
#
# usage: build-engine.sh UPSTREAM_55
#        UPSTREAM_55  root of an atak-civ checkout at 5.5.1.10 (needs
#                     takkernel/engine/src/main, khronos/,
#                     takengine/thirdparty/tinygltfloader/ and the LFS
#                     content of depends/tinygltf-2.4.1-mod.tar.gz)
# out:   dev/spike/g55/build/dist/         the staged, re-signed dylibs and
#                                          test binaries (+ ANGLE's EGL and
#                                          GLESv2 when G55_GLES=angle)
#        dev/spike/g55/build/build.log    full compiler output
#        dev/spike/g55/build/summary.txt  failing sources, first error each
# exit:  0 libtakengine and libtakenginejni linked; 1 compile or link failures; 2 usage or
#        preflight
set -euo pipefail

G55="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/spike/g55
DEV="$(cd "$G55/../.." && pwd)"                        # <repo>/dev
WORK="$G55/build"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

log() { printf '\n[g55] %s\n' "$*"; }
die() { printf '\n[g55] FATAL: %s\n' "$*" >&2; exit 2; }

[[ $# -eq 1 ]] || die "usage: build-engine.sh UPSTREAM_55"
UPSTREAM="$(cd "$1" && pwd)" || die "no such directory: $1"
ENGINE_MAIN="$UPSTREAM/takkernel/engine/src/main"
KHRONOS="$UPSTREAM/khronos"
TINYGLTF_TGZ="$UPSTREAM/depends/tinygltf-2.4.1-mod.tar.gz"
TINYGLTFLOADER="$UPSTREAM/takengine/thirdparty/tinygltfloader"
DIST="$WORK/dist"

# GLES slot, as build-native.sh: the no-op stub, or ANGLE on Metal
GLES="${G55_GLES:-stub}"
ANGLE_DIST="$DEV/g2/angle-dist"
case "$GLES" in
  stub)  GLES_LIB="$WORK/gles-stub/libGLESv2.dylib"; GLES_RPATH="$WORK/gles-stub" ;;
  angle) GLES_LIB="$ANGLE_DIST/libGLESv2.dylib";      GLES_RPATH="$ANGLE_DIST"
         [[ -f "$ANGLE_DIST/libGLESv2.dylib" && -f "$ANGLE_DIST/libEGL.dylib" ]] \
           || die "G55_GLES=angle but $ANGLE_DIST is not staged — run dev/g2/fetch-angle.sh" ;;
  *)     die "G55_GLES must be 'stub' or 'angle' (got '$GLES')" ;;
esac

# --- preflight -----------------------------------------------------------
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
  || die "requires macOS arm64 (got $(uname -s) $(uname -m))"
for t in cmake ninja rsync clang patch python3 brew; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
[[ -d "$ENGINE_MAIN/cpp" ]] || die "no 5.5 engine at $ENGINE_MAIN"
[[ -f "$KHRONOS/OpenGL/api/GLES3/gl3.h" ]] || die "no khronos headers at $KHRONOS"
[[ -f "$TINYGLTFLOADER/tiny_gltf_loader.h" ]] || die "no tinygltfloader at $TINYGLTFLOADER"
gzip -t "$TINYGLTF_TGZ" 2>/dev/null \
  || die "$TINYGLTF_TGZ is missing or an LFS pointer — git lfs pull --include=depends/tinygltf-2.4.1-mod.tar.gz"
compgen -G "$G55/jni-include/*.h" >/dev/null \
  || die "no JNI headers in $G55/jni-include — run kernel/build-kernel-jars.sh"
# build-native.sh's list + mdbtools (5.5's MS Access provider,
# formats/msaccess, links libmdb; its header includes glib's) + assimp +
# openssl@3 (5.5's JNI libcurl client calls OPENSSL_init_ssl) + googletest
# (the JNI guard tests)
for f in proj geos gdal libspatialite minizip nlohmann-json libxml2 mdbtools glib assimp openssl@3 googletest; do
  brew list --versions "$f" >/dev/null 2>&1 \
    || die "brew formula missing: $f
       → brew install proj geos gdal libspatialite minizip nlohmann-json libxml2 mdbtools glib assimp openssl@3 googletest ninja"
done
GLIB="$(brew --prefix glib)"
OPENSSL="$(brew --prefix openssl@3)"
log "preflight ok (upstream=$UPSTREAM, GLES=$GLES, -j$JOBS)"

# --- work tree -----------------------------------------------------------
# build/kernel (kernel/build-kernel-jars.sh) survives: its jars took a
# Gradle run to make
find "$WORK" -mindepth 1 -maxdepth 1 ! -name kernel -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$WORK/gles-stub" "$WORK/overlay/tinygltf"

log "copying engine tree → $WORK/engine"
rsync -a --exclude .git "$ENGINE_MAIN/" "$WORK/engine/"

log "applying the 5.5 patch series (-p3, --fuzz=0)"
shopt -s nullglob
series=("$G55"/patches/gdal-drift-*.patch)
for p in "$G55"/patches/*.patch; do
  [[ "$(basename "$p")" == gdal-drift-* ]] || series+=("$p")
done
shopt -u nullglob
(( ${#series[@]} > 0 )) || die "no patches in $G55/patches"
for p in "${series[@]}"; do
  patch --forward --silent --no-backup-if-mismatch --fuzz=0 -p3 -d "$WORK/engine" < "$p" \
    || die "patch failed: $(basename "$p")"
done
log "  applied ${#series[@]} patches"

log "building GLES stub against 5.5's khronos headers"
clang -arch arm64 -dynamiclib -O2 \
  -I"$KHRONOS/OpenGL/api" -I"$KHRONOS/EGL/api" \
  -o "$WORK/gles-stub/libGLESv2.dylib" "$DEV/g2/jni-extra/mactak_gles_stub.c"

log "third-party headers: tinygltf (upstream tarball), tinygltfloader (in-tree)"
mkdir -p "$WORK/tinygltf-src" "$WORK/overlay/tinygltfloader"
tar xzf "$TINYGLTF_TGZ" -C "$WORK/tinygltf-src"
tiny_gltf_h="$(find "$WORK/tinygltf-src" -name tiny_gltf.h -print -quit)"
[[ -n "$tiny_gltf_h" ]] || die "no tiny_gltf.h in $(basename "$TINYGLTF_TGZ")"
cp "$(dirname "$tiny_gltf_h")"/*.h "$WORK/overlay/tinygltf/"
# the engine includes <tinygltf/json.hpp> directly; tinygltf's own copy if
# it ships one, else nlohmann-json (G0's stand-in)
json_hpp="$(find "$WORK/tinygltf-src" -name json.hpp -print -quit)"
cp "${json_hpp:-$(brew --prefix nlohmann-json)/include/nlohmann/json.hpp}" "$WORK/overlay/tinygltf/json.hpp"
cp "$TINYGLTFLOADER"/*.h "$TINYGLTFLOADER"/json.hpp "$WORK/overlay/tinygltfloader/"

log "generating wrapper CMakeLists"
cat > "$WORK/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.5)
cmake_policy(SET CMP0079 NEW)
project(takengine55 LANGUAGES C CXX)

add_subdirectory($WORK/engine/cpp engine-cpp)

# SQLCipher rung, as build-native.sh
get_target_property(_takdefs takengine COMPILE_DEFINITIONS)
list(REMOVE_ITEM _takdefs SQLITE_HAS_CODEC)
set_target_properties(takengine PROPERTIES COMPILE_DEFINITIONS "\${_takdefs}")

target_include_directories(takengine PRIVATE
    /opt/homebrew/include
    $KHRONOS/OpenGL/api
    $KHRONOS/EGL/api
    $WORK/overlay
    $GLIB/include/glib-2.0       # mdbtools.h includes glib.h
    $GLIB/lib/glib-2.0/include   # glibconfig.h
)
target_link_directories(takengine PRIVATE /opt/homebrew/lib)

# libkml's renamed minizip -> Homebrew minizip, as build-native.sh; the
# JNI glue below needs the same renames
set(_minizip_renames
    libkml_unzClose=unzClose
    libkml_unzOpen=unzOpen
    libkml_unzOpenCurrentFile=unzOpenCurrentFile
    libkml_unzReadCurrentFile=unzReadCurrentFile
    libkml_unzGetGlobalInfo=unzGetGlobalInfo
    libkml_unzGetGlobalComment=unzGetGlobalComment
    libkml_unzGoToFirstFile=unzGoToFirstFile
    libkml_unzGoToNextFile=unzGoToNextFile
    libkml_unzLocateFile=unzLocateFile
    libkml_unzGetCurrentFileInfo=unzGetCurrentFileInfo
    libkml_unzStringFileNameCompare=unzStringFileNameCompare   # new in 5.5 (util/ZipFile.cpp)
)
target_compile_definitions(takengine PRIVATE \${_minizip_renames})
target_link_libraries(takengine PRIVATE minizip)

# LAS (dead upstream, as build-native.sh) and c3dt (3D Tiles, this spike)
get_target_property(_srcs takengine SOURCES)
set(_kept)
foreach(_s IN LISTS _srcs)
    if(NOT _s MATCHES "LASScene|las/LAS\\\\.cpp|/formats/c3dt/")
        list(APPEND _kept \${_s})
    endif()
endforeach()
set_target_properties(takengine PROPERTIES SOURCES "\${_kept}")

# ttp-dist libs out, the GLES slot in, Homebrew sqlite and libxml2 by full
# path (one runtime each, as build-native.sh)
get_target_property(_libs takengine LINK_LIBRARIES)
list(REMOVE_ITEM _libs las las_c charset GLESv2)
list(APPEND _libs
    $GLES_LIB
    /opt/homebrew/opt/sqlite/lib/libsqlite3.dylib
    /opt/homebrew/opt/libxml2/lib/libxml2.dylib
    assimp
    curl                               # new in 5.5: util URIOfflineCache
    $GLIB/lib/libglib-2.0.dylib)       # mdbtools.h's inline g_malloc/g_free
set_target_properties(takengine PROPERTIES LINK_LIBRARIES "\${_libs}")
set_target_properties(takengine PROPERTIES BUILD_RPATH "@loader_path;$GLES_RPATH")

# JNI glue -> libtakenginejni, as build-native.sh: upstream's source
# lists, c3dt dropped with the engine's, macTAK's shims added
set(JNI_DIR $WORK/engine/jni)
set(SRC_DIR \${JNI_DIR})   # the name upstream's CommonSources.cmake expects
include(\${JNI_DIR}/cmake/CommonSources.cmake)
include(\${JNI_DIR}/cmake/MacOSSources.cmake)

set(takenginejni_DEFS \${takenginejni_MACOS_DEFS})
list(REMOVE_ITEM takenginejni_DEFS SQLITE_HAS_CODEC)

set(_jni_kept)
foreach(_s IN LISTS takenginejni_COMMON_SRCS takenginejni_MACOS_SRCS)
    if(NOT _s MATCHES "/c3dt/")
        list(APPEND _jni_kept \${_s})
    endif()
endforeach()
list(APPEND _jni_kept
    $DEV/g1/jni-extra/mactak_gdal.cpp
    $DEV/g2/jni-extra/mactak_egl.cpp
    $DEV/g2/jni-extra/mactak_gles.c
)

add_library(takenginejni SHARED \${_jni_kept})
target_compile_definitions(takenginejni PRIVATE \${takenginejni_DEFS} \${_minizip_renames})
target_compile_options(takenginejni PRIVATE \${takenginejni_MACOS_OPTS})
target_include_directories(takenginejni PRIVATE
    \${JNI_DIR}
    $WORK/engine/cpp
    /opt/homebrew/include
    $KHRONOS/OpenGL/api
    $KHRONOS/EGL/api
    $WORK/overlay
    $GLIB/include/glib-2.0
    $GLIB/lib/glib-2.0/include
    $G55/jni-include              # javac -h output, kernel/build-kernel-jars.sh
    $DEV/g1/jdk-include           # pinned jni.h + jni_md.h
)
target_link_directories(takenginejni PRIVATE /opt/homebrew/lib)
target_link_libraries(takenginejni PRIVATE takengine
    $GLES_LIB
    /opt/homebrew/opt/sqlite/lib/libsqlite3.dylib
    gdal
    minizip
    curl                          # new in 5.5: jlibcurlhttpclientbuilder.cpp
    $OPENSSL/lib/libssl.dylib     # ... which also calls OPENSSL_init_ssl
)
set_target_properties(takenginejni PROPERTIES
    CXX_STANDARD 17               # as upstream's jni/CMakeLists.txt: util/Tasking.h
    CXX_STANDARD_REQUIRED ON      # overloads on noexcept function types
    BUILD_RPATH "@loader_path;\${CMAKE_BINARY_DIR}/engine-cpp;$GLES_RPATH"
)

# G1's JNI guard tests (dev/g1/jni-tests) against the 5.5 glue, as
# build-native.sh: the executable boots a JVM itself (guards mode), the
# module runs under the java launcher (kernel mode, jni-tests.sh)
find_package(GTest REQUIRED)
get_target_property(_jniincs takenginejni INCLUDE_DIRECTORIES)
set(_jni_test_srcs
    $G55/jni-tests/textformat2_guards_test.cpp   # 5.5 factory signature
    $DEV/g1/jni-tests/interop_guards_test.cpp
    $DEV/g1/jni-tests/onload_guards_test.cpp
    $DEV/g1/jni-tests/ioprovider_kernel_test.cpp
    $DEV/g1/jni-tests/module_main.cpp
)
add_executable(takengine-jni-tests \${_jni_test_srcs})
add_library(takengine-jni-tests-module SHARED \${_jni_test_srcs})
target_link_libraries(takengine-jni-tests PRIVATE takenginejni takengine GTest::gtest_main)
target_link_libraries(takengine-jni-tests-module PRIVATE takenginejni takengine GTest::gtest)
foreach(_t takengine-jni-tests takengine-jni-tests-module)
    target_include_directories(\${_t} PRIVATE \${_jniincs} $DEV/g1/jni-tests)
    target_compile_definitions(\${_t} PRIVATE \${takenginejni_DEFS})
    target_compile_options(\${_t} PRIVATE -Wno-error=dynamic-exception-spec)
    target_link_directories(\${_t} PRIVATE /opt/homebrew/lib)
    set_target_properties(\${_t} PROPERTIES
        CXX_STANDARD 17
        BUILD_RPATH "@loader_path;\${CMAKE_BINARY_DIR};\${CMAKE_BINARY_DIR}/engine-cpp;$GLES_RPATH"
    )
endforeach()
CMAKE

log "configuring (Ninja)"
cmake -S "$WORK" -B "$WORK/cmake" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 >"$WORK/configure.log" 2>&1 \
  || { tail -n 40 "$WORK/configure.log" >&2; die "cmake configure failed (log: $WORK/configure.log)"; }

log "building with ninja -k 0 (every failing source, not just the first)"
set +e
ninja -C "$WORK/cmake" -k 0 -j "$JOBS" >"$WORK/build.log" 2>&1
build_rc=$?
set -e

python3 "$G55/summarize-build.py" "$WORK/build.log" "$WORK/engine" >"$WORK/summary.txt"
cat "$WORK/summary.txt"

if (( build_rc != 0 )) || [[ ! -f "$WORK/cmake/engine-cpp/libtakengine.dylib" \
                            || ! -f "$WORK/cmake/libtakenginejni.dylib" ]]; then
  log "FAIL: ninja exit $build_rc (full log: $WORK/build.log)"
  exit 1
fi

# as build-native.sh: one directory the runners load from; ANGLE beside
# the engine (@loader_path); every staged binary re-signed, since
# re-staged linker-signed dylibs were SIGKILLed on dlopen (dev/g2/NOTES.md
# §M3.1)
log "staging → $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"
cp "$WORK/cmake/engine-cpp/libtakengine.dylib" "$WORK/cmake/libtakenginejni.dylib" \
   "$WORK/cmake/takengine-jni-tests" "$DIST/"
cp "$WORK/cmake/libtakengine-jni-tests-module.dylib" "$DIST/libtakengine-jni-tests.dylib"
if [[ "$GLES" == angle ]]; then
  cp "$ANGLE_DIST/libEGL.dylib" "$ANGLE_DIST/libGLESv2.dylib" "$DIST/"
fi
for f in "$DIST"/*.dylib "$DIST/takengine-jni-tests"; do
  codesign --force --sign - "$f" 2>/dev/null || die "codesign failed on staged $f"
done

log "PASS: libtakengine.dylib and libtakenginejni.dylib linked from the 5.5 tree (GLES=$GLES)"
