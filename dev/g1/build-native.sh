#!/usr/bin/env bash
#
# G1.0 — deterministic native build of the takkernel C++ engine (macOS arm64).
#
# The 5.5 baseline (TAK-Product-Center/atak-civ @ 9f6893d, takkernel 8.30.5;
# re-pinned from 4.6 — dev/spike/g55/NOTES.md), without touching the
# evidence tree or /tmp:
#   src/takkernel/engine/src/main  →  dev/g1/build/engine (throwaway copy)
#   + dev/g1/patches/*.patch (gdal-drift-* first, then the rest, sorted;
#     --fuzz=0)
#   + GLES stub as the libGLESv2 slot, or ANGLE on Metal (MACTAK_GLES=angle;
#     staged by dev/g2/fetch-angle.sh) — G2
#   + third-party headers 5.5 compiles on every platform: tinygltf (upstream's
#     depends/tinygltf-2.4.1-mod.tar.gz, Git LFS), tinygltfloader (in-tree),
#     assimp (Homebrew)
#   - formats/c3dt and the glue's c3dt/ (3D Tiles: cesium-native + draco,
#     which upstream's macOS build does not wire) and LAS (dead upstream)
#   → libtakengine.dylib staged in dev/g1/native-dist/
#   → canary: dlopen + GTest subset of engine/src/test/cpp
#
# G1.1 addition: also builds the JNI glue (engine/src/main/jni) into
# libtakenginejni.dylib so the engine loads IN-PROCESS from a real JVM
# (System.load + named Java_* exports), and canaries that with
# dev/g1/smoke/run.sh: open a SQLite db through the engine's own JNI
# stack and read back 42.
#
# Everything lands under g1/build (wiped each run) for reproducibility.
# A clean build is ~4–5 min at -j$(hw.ncpu). Ninja runs with -k 0, so a
# failed build lists every failing source (dev/g1/build/summary.txt).
set -euo pipefail

DEV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # <repo>/dev — this script lives at dev/g1/
ROOT="$(cd "$DEV/.." && pwd)"                             # <repo>
G1="$DEV/g1"
WORK="$G1/build"
OUT="$G1/native-dist"
ENGINE_MAIN="$ROOT/src/takkernel/engine/src/main"
TESTS_DIR="$ROOT/src/takkernel/engine/src/test/cpp"
KHRONOS="$ROOT/src/khronos"
TINYGLTF_TGZ="$ROOT/src/depends/tinygltf-2.4.1-mod.tar.gz"
TINYGLTFLOADER="$ROOT/src/takengine/thirdparty/tinygltfloader"
JOBS="$(sysctl -n hw.ncpu)"

log() { printf '\n[g1] %s\n' "$*"; }
die() { printf '\n[g1] FATAL: %s\n' "$*" >&2; exit 1; }

# Minimal EXIT trap: on failure, report context; always, kill any lingering
# background job and sweep the throwaway build tree if we created it.
# G1_CLEANED_ON_EXIT=1 skips the sweep so $WORK survives a failed build for
# post-mortem inspection (documented by the post-G0 audit; the knob existed
# but was referenced nowhere else).
_rc=0
trap '_rc=$?; if (( _rc != 0 )); then
        printf "[g1] build FAILED (exit %s) at line %s — inspect %s if present\n" "$_rc" "${LINENO:-?}" "$WORK" >&2
      fi
      # Only our own background jobs: `kill -- -$$` signalled the whole
      # process group, and when run from a terminal this script LEADS its
      # group — it SIGTERMed itself, exiting 143 after a successful build
      # and skipping the rest of this trap (failure cleanup).
      { kill $(jobs -p) 2>/dev/null || true; }
      if [[ -n "${WORK:-}" && -d "$WORK" && "${G1_CLEANED_ON_EXIT:-0}" != 1 && _rc -ne 0 ]]; then
        rm -rf "$WORK"
      fi' EXIT

# --- preflight -----------------------------------------------------------
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
  || die "requires macOS arm64 (got $(uname -s) $(uname -m))"
for t in cmake ninja rsync clang patch python3 brew; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
[[ -d "$ENGINE_MAIN/cpp" ]] \
  || die "engine tree missing at $ENGINE_MAIN — populate src/ per CONTRIBUTING.md (Setup)"
[[ -d "$TESTS_DIR" ]] || die "engine C++ tests missing at $TESTS_DIR"
[[ -f "$KHRONOS/OpenGL/api/GLES3/gl3.h" ]] || die "no khronos headers at $KHRONOS"
[[ -f "$TINYGLTFLOADER/tiny_gltf_loader.h" ]] || die "no tinygltfloader at $TINYGLTFLOADER"
gzip -t "$TINYGLTF_TGZ" 2>/dev/null \
  || die "$TINYGLTF_TGZ is missing or an LFS pointer — (cd src && git lfs pull --include=depends/tinygltf-2.4.1-mod.tar.gz)"
compgen -G "$G1/jni-include/*.h" >/dev/null \
  || die "no JNI headers in $G1/jni-include — run dev/g1/kernel/build-kernel-jars.sh"
# 5.5 adds mdbtools + glib (formats/msaccess; mdbtools.h includes glib.h),
# assimp (the ASSIMP scene SPI) and openssl@3 (the glue's libcurl client)
for f in proj geos gdal libspatialite minizip nlohmann-json laszip googletest libxml2 mdbtools glib assimp openssl@3; do
  brew list --versions "$f" >/dev/null 2>&1 \
    || die "brew formula missing: $f
       → brew install proj geos gdal libspatialite laszip minizip nlohmann-json googletest libxml2 mdbtools glib assimp openssl@3 ninja"
done
GLIB="$(brew --prefix glib)"
OPENSSL="$(brew --prefix openssl@3)"

# GLES slot: the G0 no-op stub (default; CI has no ANGLE) or the ANGLE
# runtime staged in dev/g2/angle-dist (install name @rpath/libGLESv2.dylib,
# resolved via @loader_path once staged next to the engine in native-dist).
GLES="${MACTAK_GLES:-stub}"
ANGLE_DIST="$DEV/g2/angle-dist"
case "$GLES" in
  stub)  GLES_LIB="$WORK/gles-stub/libGLESv2.dylib"; GLES_RPATH="$WORK/gles-stub" ;;
  angle) GLES_LIB="$ANGLE_DIST/libGLESv2.dylib";      GLES_RPATH="$ANGLE_DIST"
         [[ -f "$GLES_LIB" && -f "$ANGLE_DIST/libEGL.dylib" ]] \
           || die "MACTAK_GLES=angle but $ANGLE_DIST is not staged — run dev/g2/fetch-angle.sh" ;;
  *)     die "MACTAK_GLES must be 'stub' or 'angle' (got '$GLES')" ;;
esac

log "preflight ok (root=$ROOT, -j$JOBS, GLES=$GLES)"

# --- work tree -----------------------------------------------------------
rm -rf "$WORK"
mkdir -p "$WORK/gles-stub" "$WORK/overlay" "$OUT"

log "copying engine tree → $WORK/engine"
rsync -a --exclude .git "$ENGINE_MAIN/" "$WORK/engine/"

log "applying the patch series (-p3 → cpp/..., java/..., jni/...)"
# gdal-drift-* first, then the rest sorted: the order the 5.5 series was
# ported and verified in (dev/spike/g55/NOTES.md §The patch port)
shopt -s nullglob
series=("$G1"/patches/gdal-drift-*.patch)
for p in "$G1"/patches/*.patch; do
  [[ "$(basename "$p")" == gdal-drift-* ]] || series+=("$p")
done
shopt -u nullglob
(( ${#series[@]} > 0 )) || die "no patches in $G1/patches"
for p in "${series[@]}"; do
  # --fuzz=0: a hunk whose context no longer matches must fail loudly, not
  # land "close enough" (megatexture-sharetile applied with fuzz 1 for weeks;
  # g55 traps 1–2: fuzz 3 placed hunks in the wrong method)
  patch --forward --silent --no-backup-if-mismatch --fuzz=0 -p3 -d "$WORK/engine" < "$p" \
    || die "patch failed: $(basename "$p")"
done
log "  applied ${#series[@]} patches"

log "building GLES stub (no-op libGLESv2 covering all of gl3.h; ANGLE replaces it)"
clang -arch arm64 -dynamiclib -O2 \
  -I"$KHRONOS/OpenGL/api" -I"$KHRONOS/EGL/api" \
  -o "$WORK/gles-stub/libGLESv2.dylib" "$DEV/g2/jni-extra/mactak_gles_stub.c"

log "third-party headers: tinygltf (upstream tarball), tinygltfloader (in-tree)"
mkdir -p "$WORK/overlay/tinygltf" "$WORK/overlay/tinygltfloader" "$WORK/tinygltf-src"
tar xzf "$TINYGLTF_TGZ" -C "$WORK/tinygltf-src"
tiny_gltf_h="$(find "$WORK/tinygltf-src" -name tiny_gltf.h -print -quit)"
[[ -n "$tiny_gltf_h" ]] || die "no tiny_gltf.h in $(basename "$TINYGLTF_TGZ")"
cp "$(dirname "$tiny_gltf_h")"/*.h "$WORK/overlay/tinygltf/"
# the engine includes <tinygltf/json.hpp>; tinygltf's own copy if it ships
# one, else nlohmann-json (G0's stand-in)
json_hpp="$(find "$WORK/tinygltf-src" -name json.hpp -print -quit)"
cp "${json_hpp:-$(brew --prefix nlohmann-json)/include/nlohmann/json.hpp}" "$WORK/overlay/tinygltf/json.hpp"
# tiny_gltf_loader.h includes "./json.hpp": its own copy, beside it (g55 run 2)
cp "$TINYGLTFLOADER"/*.h "$TINYGLTFLOADER"/json.hpp "$WORK/overlay/tinygltfloader/"

log "generating wrapper CMakeLists"
cat > "$WORK/wrapper-CMakeLists.txt.in" <<'CMAKE'
cmake_minimum_required(VERSION 3.5)
cmake_policy(SET CMP0079 NEW)
project(takengine LANGUAGES C CXX)

set(SRC @ROOT@)
set(WORK @WORK@)

add_subdirectory(${WORK}/engine/cpp engine-cpp)

# SQLITE_HAS_CODEC needs SQLCipher; upstream's #else branch degrades
# gracefully (warning + ignore passphrase). Revisit at the encryption rung.
get_target_property(_takdefs takengine COMPILE_DEFINITIONS)
list(REMOVE_ITEM _takdefs SQLITE_HAS_CODEC)
set_target_properties(takengine PROPERTIES COMPILE_DEFINITIONS "${_takdefs}")

if(TARGET takengine)
    # Homebrew deps replace the ttp-dist bundle the macOS branch expects.
    target_include_directories(takengine PRIVATE
        /opt/homebrew/include
        ${SRC}/src/khronos/OpenGL/api   # GLES3/gl3.h (GLES-stub slot)
        ${SRC}/src/khronos/EGL/api      # EGL + KHR/khrplatform.h
        ${WORK}/overlay                 # tinygltf/, tinygltfloader/
        @GLIB@/include/glib-2.0         # mdbtools.h includes glib.h
        @GLIB@/lib/glib-2.0/include     # glibconfig.h
    )
    target_link_directories(takengine PRIVATE /opt/homebrew/lib)

    # libkml's renamed minizip -> Homebrew minizip (same signatures); the
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
        libkml_unzStringFileNameCompare=unzStringFileNameCompare   # util/ZipFile.cpp (5.5)
    )
    target_compile_definitions(takengine PRIVATE ${_minizip_renames})
    target_link_libraries(takengine PRIVATE minizip)

    # libLAS is dead upstream — exclude the LAS TUs (self-contained SPI).
    # formats/c3dt (3D Tiles) needs cesium-native + draco, which upstream's
    # macOS build does not wire; left out until 3D Tiles is needed.
    get_target_property(_srcs takengine SOURCES)
    set(_kept)
    foreach(_s IN LISTS _srcs)
        if(NOT _s MATCHES "LASScene|las/LAS\\.cpp|/formats/c3dt/")
            list(APPEND _kept ${_s})
        endif()
    endforeach()
    set_target_properties(takengine PROPERTIES SOURCES "${_kept}")

    # Drop ttp-dist libs; GLESv2 -> stub; append sqlite3. Bare `sqlite3`
    # resolves to /usr/lib (system) and then COLLIDES with libspatialite's
    # brew sqlite at runtime (two runtimes, SIGSEGV in findElementWithHash)
    # — pin the full brew path so the whole process shares one sqlite.
    get_target_property(_libs takengine LINK_LIBRARIES)
    list(REMOVE_ITEM _libs las las_c charset GLESv2)
    list(APPEND _libs @GLES_LIB@)
    list(APPEND _libs /opt/homebrew/opt/sqlite/lib/libsqlite3.dylib)
    # libxml2 (KMLDriverDefinition2 style parsing): keg-only, full path =
    # the same runtime libgdal already loads. The G0 stub used to no-op
    # these 11 symbols silently (found when ANGLE replaced the stub).
    list(APPEND _libs /opt/homebrew/opt/libxml2/lib/libxml2.dylib)
    list(APPEND _libs
        assimp                          # model/ASSIMPSceneSpi.cpp (5.5)
        curl                            # util/URIOfflineCache.cpp (5.5)
        @GLIB@/lib/libglib-2.0.dylib    # mdbtools.h's inline g_malloc/g_free
    )
    set_target_properties(takengine PROPERTIES LINK_LIBRARIES "${_libs}")
    set_target_properties(takengine PROPERTIES
        BUILD_RPATH "@loader_path;@GLES_RPATH@"
    )

    # ---------------------------------------------------------------
    # G1.0 canary: googletest subset of engine/src/test/cpp,
    # pure-logic TUs only (no GL, no fixtures). Grows as the port
    # matures.
    # ---------------------------------------------------------------
    get_target_property(_takincs takengine INCLUDE_DIRECTORIES)
    find_package(GTest CONFIG REQUIRED)
    add_executable(takengine-tests
        ${SRC}/src/takkernel/engine/src/test/cpp/MathUtilsTests.cpp
        ${SRC}/src/takkernel/engine/src/test/cpp/GeoPoint2Tests.cpp
        ${SRC}/src/takkernel/engine/src/test/cpp/TessellationTests.cpp
        ${SRC}/src/takkernel/engine/src/test/cpp/StringBuilderTests.cpp
        ${SRC}/src/takkernel/engine/src/test/cpp/GeometryFactoryTests.cpp
        ${SRC}/src/takkernel/engine/src/test/cpp/DatasetDescriptorTests.cpp
        ${SRC}/src/takkernel/engine/src/test/cpp/TakEngineTestsLogging.cpp
        # PRITests.cpp: upstream-broken at this pin — includes PRI.h which is
        # not in the tree, and needs a .NTF fixture. Revisit at G1.5.
        # NOTE: TakEngineTests{Hexdump,Resources}.cpp are NOT compiled:
        # Resources.cpp is Windows-only (Windows.h); Hexdump is link-unused
        # by the TUs above. Logging.cpp IS needed (TestLogger, portable).
    )
    target_include_directories(takengine-tests PRIVATE
        ${_takincs}
        /opt/homebrew/include
        ${SRC}/src/khronos/OpenGL/api
        ${SRC}/src/khronos/EGL/api
        ${WORK}/overlay
        @GLIB@/include/glib-2.0
        @GLIB@/lib/glib-2.0/include
        ${SRC}/src/takkernel/engine/src/main/cpp
        ${SRC}/src/takkernel/engine/src/test/cpp
    )
    target_compile_definitions(takengine-tests PRIVATE
        ${_takdefs}
    )
    target_link_libraries(takengine-tests PRIVATE takengine GTest::gtest_main)
    set_target_properties(takengine-tests PROPERTIES
        BUILD_RPATH "${CMAKE_BINARY_DIR}/engine-cpp;@GLES_RPATH@"
    )

    # ---------------------------------------------------------------
    # G1.1: JNI glue (engine/src/main/jni) -> libtakenginejni.dylib.
    # Named Java_* exports let the JVM load the engine in-process
    # (System.load; JNI_OnLoad in the glue's common.cpp wires globals).
    # Sources come from upstream's jni/cmake/{Common,MacOS}Sources.cmake;
    # c3dt/ and interop/formats/c3dt/ are dropped with the 3D-tiles rung.
    # The javac -h headers are a committed artifact (dev/g1/jni-include,
    # written by dev/g1/kernel/build-kernel-jars.sh, drift-checked in CI)
    # and dev/g1/jdk-include pins jni.h/jni_md.h so this native build
    # needs no JDK installed.
    # ---------------------------------------------------------------
    set(JNI_DIR ${WORK}/engine/jni)   # rsync flattens src/main/ into build/engine/
    set(SRC_DIR ${JNI_DIR})   # variable name upstream CommonSources.cmake expects
    include(${JNI_DIR}/cmake/CommonSources.cmake)
    include(${JNI_DIR}/cmake/MacOSSources.cmake)

    set(takenginejni_DEFS ${takenginejni_MACOS_DEFS})
    list(REMOVE_ITEM takenginejni_DEFS SQLITE_HAS_CODEC)  # same SQLCipher rung as core

    set(takenginejni_SRCS ${takenginejni_COMMON_SRCS} ${takenginejni_MACOS_SRCS})
    set(_jni_kept)
    foreach(_s IN LISTS takenginejni_SRCS)
        # c3dt: 3D tiles/GLTF rung. vsi_jfile.cpp rejoined 2026-11-09
        # (G2.4 b.1a): dev/g1/patches/vsi-jfile-gdal3-api.patch ports its
        # VSIFilesystemHandler/VSIVirtualHandle overrides to GDAL 3's
        # signatures, so GdalLibrary.init() can install the /vsijfile/
        # handler and complete (trap #50).
        if(NOT _s MATCHES "/c3dt/")
            list(APPEND _jni_kept ${_s})
        endif()
    endforeach()
    # macTAK shim: GDAL driver registration without the org.gdal SWIG
    # bindings (Android's path) — exposes the engine's GdalLibrary::init.
    list(APPEND _jni_kept ${SRC}/dev/g1/jni-extra/mactak_gdal.cpp)
    # macTAK shim (G2): EGL render context on ANGLE, dlopen-based so it
    # also builds in stub mode (init() just fails there).
    list(APPEND _jni_kept ${SRC}/dev/g2/jni-extra/mactak_egl.cpp)
    # macTAK shim (G2): android.opengl.GLES20/GLES30 JNI bodies forwarding
    # to the linked libGLESv2 (GENERATED by dev/g2/gen-gles-shim.py; in stub
    # mode they resolve against the no-op stub).
    list(APPEND _jni_kept ${SRC}/dev/g2/jni-extra/mactak_gles.c)

    add_library(takenginejni SHARED ${_jni_kept})
    target_compile_definitions(takenginejni PRIVATE ${takenginejni_DEFS} ${_minizip_renames})
    target_compile_options(takenginejni PRIVATE ${takenginejni_MACOS_OPTS})
    target_include_directories(takenginejni PRIVATE
        ${JNI_DIR}
        ${WORK}/engine/cpp
        /opt/homebrew/include
        ${SRC}/src/khronos/OpenGL/api   # GLES3/gl3.h (GLES-stub slot)
        ${SRC}/src/khronos/EGL/api      # EGL + KHR/khrplatform.h
        ${WORK}/overlay                 # tinygltf/, tinygltfloader/
        @GLIB@/include/glib-2.0
        @GLIB@/lib/glib-2.0/include
        ${SRC}/dev/g1/jni-include       # javac -h output (kernel/build-kernel-jars.sh)
        ${SRC}/dev/g1/jdk-include       # pinned jni.h + jni_md.h
    )
    target_link_directories(takenginejni PRIVATE /opt/homebrew/lib)
    target_link_libraries(takenginejni PRIVATE takengine
        @GLES_LIB@
        /opt/homebrew/opt/sqlite/lib/libsqlite3.dylib
        gdal
        minizip
        curl                            # jlibcurlhttpclientbuilder.cpp (5.5)
        @OPENSSL@/lib/libssl.dylib      # ... which also calls OPENSSL_init_ssl
    )
    set_target_properties(takenginejni PROPERTIES
        CXX_STANDARD 17                 # as upstream's jni/CMakeLists.txt: util/Tasking.h
        CXX_STANDARD_REQUIRED ON        # overloads on noexcept function types
        BUILD_RPATH "@loader_path;${CMAKE_BINARY_DIR}/engine-cpp;@GLES_RPATH@"
    )
endif()

    get_target_property(_jniincs takenginejni INCLUDE_DIRECTORIES)

    # ---------------------------------------------------------------
    # G1.9: JNI guard/behavior canary (dev/g1/jni-tests) — GTest over a
    # REAL desktop JVM (no fake JNIEnv; the JVM is the failure vector):
    #   guards mode (empty classpath): wave-5/6 class-init guards bail
    #     neutrally; JNI_OnLoad fails cleanly (JNI_ERR), not by crash.
    #   kernel mode (takkernel jars): the Java-backed IOProviderFactory
    #     proxy behaves on real files (the getFileCount isDirectory fix)
    #     and Java failures surface as TE_Err with a clean JNIEnv.
    #   noslf4j mode (kernel jars minus slf4j-api): JNI_OnLoad's
    #     ManagedLogger goes quiet instead of crashing the JVM (G1.17).
    # Needs no JDK to build — dev/g1/jni-tests/run.sh skips when none is
    # present (CI's native job installs JDK 21 before this script).
    # ---------------------------------------------------------------
    add_executable(takengine-jni-tests
        ${SRC}/dev/g1/jni-tests/jni_test_env.hpp
        ${SRC}/dev/g1/jni-tests/textformat2_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/interop_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/onload_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/featuredefinition_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/feature_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/db_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/elevation_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/core_renderer_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/rest_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/ioprovider_kernel_test.cpp
        ${SRC}/dev/g1/jni-tests/managedlogger_noslf4j_test.cpp
        # module_main.cpp links into BOTH products (no main() in it): the
        # binary needs takengine_jni_tests_env's definition too — weak
        # imports of undefined symbols don't link for executables on ld64
        ${SRC}/dev/g1/jni-tests/module_main.cpp
    )
    target_include_directories(takengine-jni-tests PRIVATE
        ${_jniincs}
        /opt/homebrew/include
        ${SRC}/dev/g1/jni-tests
    )
    target_compile_definitions(takengine-jni-tests PRIVATE
        ${takenginejni_DEFS}
    )
    target_link_directories(takengine-jni-tests PRIVATE /opt/homebrew/lib)
    target_link_libraries(takengine-jni-tests PRIVATE takenginejni takengine GTest::gtest_main)
    set_target_properties(takengine-jni-tests PROPERTIES
        # brew GTest (>=1.16) requires C++17 via its imported-target
        # compile features — those win over CXX_STANDARD, so the TUs
        # compile as C++17
        CXX_STANDARD 17
        # @loader_path: the binary is staged next to the dylibs in
        # native-dist (canary 3/4 runs it there, and `make test-jni` too)
        BUILD_RPATH "@loader_path;@loader_path/engine-cpp;${CMAKE_BINARY_DIR};${CMAKE_BINARY_DIR}/engine-cpp;@GLES_RPATH@"
    )
    # the engine codebase is C++14-era: its headers carry throw(X)
    # dynamic-exception specs, which are an error under C++17. Downgrade
    # to warning (clang then treats them as noexcept(false)); takenginejni
    # dodges this only because its TUs compile with the compiler default
    # (gnu++14) — this target can't, with GTest in the link
    target_compile_options(takengine-jni-tests PRIVATE -Wno-error=dynamic-exception-spec)

    # kernel mode runs UNDER THE JAVA LAUNCHER (the smoke's proven boot —
    # a raw JNI_CreateJavaVM boot crashes inside hotspot's jni_FindClass
    # when IT invokes JNI_OnLoad on Zulu 8 aarch64): the same TUs as a
    # shared library, loaded by JniTestsMain after the launcher has
    # System.load'ed the engine dylibs (gtest, NOT gtest_main — the
    # module's entry is Java_JniTestsMain_takengineJniTestsMain)
    add_library(takengine-jni-tests-module SHARED
        ${SRC}/dev/g1/jni-tests/textformat2_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/interop_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/onload_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/featuredefinition_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/feature_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/db_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/elevation_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/core_renderer_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/rest_guards_test.cpp
        ${SRC}/dev/g1/jni-tests/ioprovider_kernel_test.cpp
        ${SRC}/dev/g1/jni-tests/managedlogger_noslf4j_test.cpp
        ${SRC}/dev/g1/jni-tests/module_main.cpp
    )
    target_include_directories(takengine-jni-tests-module PRIVATE
        ${_jniincs}
        /opt/homebrew/include
        ${SRC}/dev/g1/jni-tests
    )
    target_compile_definitions(takengine-jni-tests-module PRIVATE
        ${takenginejni_DEFS}
    )
    target_link_directories(takengine-jni-tests-module PRIVATE /opt/homebrew/lib)
    target_link_libraries(takengine-jni-tests-module PRIVATE takenginejni takengine GTest::gtest)
    set_target_properties(takengine-jni-tests-module PROPERTIES
        CXX_STANDARD 17
        BUILD_RPATH "@loader_path;@loader_path/engine-cpp;${CMAKE_BINARY_DIR};${CMAKE_BINARY_DIR}/engine-cpp;@GLES_RPATH@"
    )
    target_compile_options(takengine-jni-tests-module PRIVATE -Wno-error=dynamic-exception-spec)
CMAKE
sed -e "s|@ROOT@|$ROOT|g" -e "s|@WORK@|$WORK|g" \
    -e "s|@GLES_LIB@|$GLES_LIB|g" -e "s|@GLES_RPATH@|$GLES_RPATH|g" \
    -e "s|@GLIB@|$GLIB|g" -e "s|@OPENSSL@|$OPENSSL|g" \
    "$WORK/wrapper-CMakeLists.txt.in" > "$WORK/CMakeLists.txt"
rm "$WORK/wrapper-CMakeLists.txt.in"

# --- configure + build ---------------------------------------------------
log "configuring (RelWithDebInfo, arm64, Ninja)"
cmake -S "$WORK" -B "$WORK/cmake" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_OSX_ARCHITECTURES=arm64

log "building libtakengine.dylib + test canary (ninja -k 0, -j$JOBS, ~4–5 min clean)"
# -k 0: one run lists every failing source, not just the first
# (dev/g1/summarize-build.py: first error per source, undefined symbols)
set +e
ninja -C "$WORK/cmake" -k 0 -j "$JOBS" >"$WORK/build.log" 2>&1
build_rc=$?
set -e
if (( build_rc != 0 )); then
  python3 "$G1/summarize-build.py" "$WORK/build.log" "$WORK/engine" | tee "$WORK/summary.txt" >&2
  die "ninja exit $build_rc (full log: $WORK/build.log)"
fi

# --- canary --------------------------------------------------------------
log "canary 1/4: dlopen"
python3 - "$WORK/cmake/engine-cpp/libtakengine.dylib" <<'PY'
import ctypes, sys
ctypes.CDLL(sys.argv[1])
print("[g1] dlopen OK:", sys.argv[1])
PY

log "canary 2/4: engine C++ tests (GTest)"
# Two upstream tests are stale at 5.5, excluded by name so any other
# failure still fails here: 5.5 rewrote Tessellate_polygon's ring path and
# dropped 4.6's `counts[i] < 3u → TE_InvalidArg` check, so fewer than 3
# points, or a stride that makes the ring degenerate, now tessellate to
# nothing and return TE_Ok; the tests still expect an error (every read
# stays inside the test's buffer). dev/spike/g55/NOTES.md trap 10.
STALE_UPSTREAM_TESTS="TessellationTests.tessellate_polygon_InvalidPointCount:TessellationTests.tessellate_polygon_InvalidSrcStride"
"$WORK/cmake/takengine-tests" --gtest_filter="-$STALE_UPSTREAM_TESTS" \
  --gtest_output=xml:"$OUT/takengine-tests.xml"

# --- stage ---------------------------------------------------------------
log "staging → $OUT"
cp "$WORK/cmake/engine-cpp/libtakengine.dylib" "$OUT/"
cp "$WORK/cmake/libtakenginejni.dylib" "$OUT/"
cp "$WORK/cmake/takengine-jni-tests" "$OUT/"
cp "$WORK/cmake/libtakengine-jni-tests-module.dylib" "$OUT/libtakengine-jni-tests.dylib"
rm -f "$OUT/libGLESv2-stub.dylib" "$OUT/libGLESv2.dylib" "$OUT/libEGL.dylib"
if [[ "$GLES" == angle ]]; then
  cp "$ANGLE_DIST/libEGL.dylib" "$ANGLE_DIST/libGLESv2.dylib" "$OUT/"   # @loader_path siblings
else
  cp "$WORK/gles-stub/libGLESv2.dylib" "$OUT/libGLESv2-stub.dylib"
fi
# Re-sign the staged copies in place (2026-11-06 incident, dev/g2/NOTES.md
# §M3.1): re-staged linker-signed dylibs were SIGKILLed on dlopen under macOS
# provenance enforcement while `codesign -v --strict` still passed; a fresh
# adhoc signature over the staged file fixes it.
for f in "$OUT"/*.dylib "$OUT/takengine-jni-tests"; do
  cs_out="$(codesign --force --sign - "$f" 2>&1)" || die "codesign failed on staged $f: $cs_out"
done

# --- canary --------------------------------------------------------------
# G1.9: the JNI guard/behavior pins ride the same gate — they exercise the
# staged artifacts (binary + dylibs signed above), in-process on a real
# desktop JVM. Skips (exit 0) when no JDK is present.
log "canary 3/4: JNI guard/behavior unit tests (real desktop JVM)"
bash "$DEV/g1/jni-tests/run.sh" "$OUT"

# --- canary --------------------------------------------------------------
log "canary 4/4: JVM in-process load (JNI glue)"
nm -gU "$WORK/cmake/libtakenginejni.dylib" | grep 'Java_com_atakmap_database_impl_DatabaseImpl_openImpl' >/dev/null \
  || die "libtakenginejni.dylib is missing the DatabaseImpl JNI exports"
nm -gU "$WORK/cmake/libtakenginejni.dylib" | grep 'Java_mactak_headless_NativeGdal_init' >/dev/null \
  || die "libtakenginejni.dylib is missing the macTAK GDAL-init shim (dev/g1/jni-extra)"
nm -gU "$WORK/cmake/libtakenginejni.dylib" | grep 'Java_mactak_render_NativeEgl_init' >/dev/null \
  || die "libtakenginejni.dylib is missing the macTAK EGL shim (dev/g2/jni-extra)"
nm -gU "$WORK/cmake/libtakenginejni.dylib" | grep 'Java_android_opengl_GLES20_glDrawArrays' >/dev/null \
  || die "libtakenginejni.dylib is missing the macTAK GLES shim (dev/g2/jni-extra/mactak_gles.c)"
"$DEV/g1/smoke/run.sh" "$OUT"

file "$OUT/libtakengine.dylib" "$OUT/libtakenginejni.dylib"
otool -L "$OUT/libtakenginejni.dylib" | sed 's/^/  /'
ls -lh "$OUT"

log "G1.0/G1.1 OK — dylibs built, canaries green (4/4), artifacts in g1/native-dist/"
