#!/usr/bin/env bash
#
# G1.2 — deterministic macOS arm64 build of commoncommo (the CoT comms stack).
#
# Reproduces the comms layer atak-headless runs on, without touching the
# evidence tree:
#   src/commoncommo → dev/g1/build-commo/commo (throwaway copy)
#   + dev/g1/patches/commo/*.patch (-p1, relative to the copy root; separate
#     from dev/g1/patches/*.patch, which are -p3 ENGINE patches — keep it so)
#   + build-commo/shim: a takthirdparty-style layout made of Homebrew prefixes
#     (include/libxml2, include/openssl, include/google, microhttpd.h, lib/*)
#   → libcommoncommo.dylib   (core/impl Makefile; 2016 code pinned -std=c++11,
#                             protobuf objects precompiled -std=c++17 because
#                             brew protoc ≥27 no longer emits C++11)
#   → libcommoncommojni.dylib (jni/native Makefile TARGET=macos, Zulu 8 javah;
#                             classes are seeded with javac first so the
#                             Makefile's ant hook never fires)
#   → jcommoncommo.jar       (com.atakmap.commoncommo API classes)
#   staged in dev/g1/native-dist/ and wired together via @loader_path
#   (+ ad-hoc codesign — install_name_tool invalidates the linker signature
#   and arm64 refuses unsigned dylibs).
#
# Canaries: dlopen, Java_com_atakmap_commoncommo exports, and a JVM load that
# constructs + shuts down a real Commo instance (no server needed). The live
# CoT round-trip lives in dev/g1/headless/run.sh (needs FTS on 127.0.0.1:8087).
#
# Everything lands under g1/build-commo (wiped each run). A clean build is
# well under a minute at -j$(hw.ncpu).
set -euo pipefail

DEV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # <repo>/dev — this script lives at dev/g1/
ROOT="$(cd "$DEV/.." && pwd)"                             # <repo>
G1="$DEV/g1"
WORK="$G1/build-commo"
OUT="$G1/native-dist"
COMMOSRC="$ROOT/src/commoncommo"
JOBS="$(sysctl -n hw.ncpu)"
HB=/opt/homebrew

log() { printf '\n[g1-commo] %s\n' "$*"; }
die() { printf '\n[g1-commo] FATAL: %s\n' "$*" >&2; exit 1; }

# Minimal EXIT trap: on failure, report context; always, kill any lingering
# child process group and sweep the throwaway build tree if we created it.
_rc=0
trap '_rc=$?; if (( _rc != 0 )); then
        printf "[g1-commo] build FAILED (exit %s) at line %s — inspect %s if present\n" "$_rc" "${LINENO:-?}" "$WORK" >&2
      fi
      { kill -- -$$ 2>/dev/null || true; }
      if [[ -n "${WORK:-}" && -d "$WORK" && _rc -ne 0 ]]; then
        rm -rf "$WORK"
      fi' EXIT

# --- preflight -----------------------------------------------------------
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
  || die "requires macOS arm64 (got $(uname -s) $(uname -m))"
for t in make clang++ patch python3 brew rsync protoc git codesign; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
for f in openssl@3 libxml2 protobuf libmicrohttpd curl; do
  brew list --versions "$f" >/dev/null 2>&1 \
    || die "brew formula missing: $f
       → brew install openssl@3 libxml2 protobuf libmicrohttpd curl"
done
JDK="${JAVA_HOME:-$( /usr/libexec/java_home -v 1.8 2>/dev/null || true )}"
[[ -n "$JDK" && -x "$JDK/bin/javah" ]] \
  || die "Zulu 8 (JDK 1.8) with javah required — JAVA_HOME or /usr/libexec/java_home -v 1.8"
PROTOC="$(command -v protoc)"
CURL_CONF="$HB/opt/curl/bin/curl-config"
[[ -x "$CURL_CONF" ]] || CURL_CONF="$(command -v curl-config)"
[[ -d "$COMMOSRC/core/impl" ]] \
  || die "commoncommo tree missing — run: (cd $ROOT/src && git submodule update --init --recursive)"

log "preflight ok (root=$ROOT, -j$JOBS)"

# --- work tree -----------------------------------------------------------
rm -rf "$WORK"
mkdir -p "$WORK/shim" "$WORK/canary" "$OUT"

log "copying commoncommo tree → $WORK/commo"
rsync -a --exclude .git "$COMMOSRC/" "$WORK/commo/"

for p in "$G1"/patches/commo/*.patch; do
  [[ -e "$p" ]] || continue
  patch --forward --silent -p1 -d "$WORK/commo" < "$p"
  log "  applied $(basename "$p")"
done

# --- thirdparty shim (takthirdparty layout over Homebrew prefixes) -------
log "linking Homebrew prefixes into takthirdparty-style shim"
mkdir -p "$WORK/shim/include" "$WORK/shim/PGSC_Utils/include" "$WORK/shim/lib"
ln -sfn "$HB/opt/libxml2/include/libxml2"               "$WORK/shim/include/libxml2"
ln -sfn "$HB/opt/openssl@3/include/openssl"             "$WORK/shim/include/openssl"
ln -sfn "$HB/include/google"                            "$WORK/shim/include/google"
ln -sf  "$HB/opt/libmicrohttpd/include/microhttpd.h"    "$WORK/shim/include/microhttpd.h"
ln -sf  "$HB/opt/libxml2/lib/libxml2.dylib"             "$WORK/shim/lib/"
ln -sf  "$HB/opt/openssl@3/lib/libssl.dylib"            "$WORK/shim/lib/"
ln -sf  "$HB/opt/openssl@3/lib/libcrypto.dylib"         "$WORK/shim/lib/"
ln -sf  "$HB/opt/libmicrohttpd/lib/libmicrohttpd.dylib" "$WORK/shim/lib/"
ln -sf  "$HB/lib/libprotobuf-lite.dylib"                "$WORK/shim/lib/"

# --- protobuf codegen + objects ------------------------------------------
# New protoc emits code that no longer compiles as C++11; the 2016 core
# stays C++11, so the pb objects are precompiled here and make picks them
# up (newer than their .pb.cc/.pb.h, its implicit rule never fires).
log "generating protobuf C++ (brew protoc)"
make -C "$WORK/commo/core/impl" protogen \
  TAKTHIRDPARTYDIR="$WORK/shim" PROTOC="$PROTOC"
for cc in "$WORK"/commo/core/impl/protobuf/*.pb.cc; do
  clang++ -c -std=c++17 -g -O2 -fPIC \
    -I"$WORK/commo/core/impl/protobuf" -I"$WORK/shim/include" -I"$HB/include" \
    -o "${cc%.cc}.o" "$cc"
done
log "  protobuf objects precompiled (-std=c++17)"

# --- core library ---------------------------------------------------------
log "building libcommoncommo (core/impl, -j$JOBS)"
# Command-line CXXFLAGS replaces the Makefile's -Werror chain wholesale;
# everything the Makefile would have added is restated here (shim paths
# stand in for takthirdparty). curl/absl/utf8 are linked explicitly because
# the 2016 link line never lists them and ld64 does not chase protobuf's
# absl deps transitively (it records only libs that resolved a symbol, so
# the full absl sweep is cheap).
ABSL_LIBS=""
for f in "$HB/opt/abseil/lib"/libabsl_*.dylib; do
  [[ -e "$f" ]] || continue
  base="${f##*/}"        # libabsl_x.dylib
  base="${base#lib}"     # absl_x.dylib
  base="${base%.dylib}"  # absl_x
  ABSL_LIBS+=" -l$base"
done
CORE_CXXFLAGS="-g -O2 -fPIC -std=c++17 -Wall -fstack-protector-all \
 -D__STDC_FORMAT_MACROS -DCURL_STATICLIB \
 -I../include -I$WORK/shim/include/libxml2 -I$WORK/shim/include -I$HB/include \
 -Wl,-rpath,$HB/opt/protobuf/lib -Wl,-rpath,$HB/opt/abseil/lib \
 -L$HB/lib -lcurl \
 -L$HB/opt/abseil/lib -L$HB/opt/protobuf/lib $ABSL_LIBS -lutf8_validity -lutf8_range \
 -Wno-deprecated-declarations -Wno-deprecated \
 -Wno-unused-command-line-argument \
 -Wno-unused-variable -Wno-unused-parameter -Wno-unused-but-set-variable \
 -Wno-sign-compare"
make -C "$WORK/commo/core/impl" -j"$JOBS" all \
  TAKTHIRDPARTYDIR="$WORK/shim" PROTOC="$PROTOC" CXXFLAGS="$CORE_CXXFLAGS"

# --- Java API (seeded classes so the Makefile's ant hook never fires) -----
log "compiling com.atakmap.commoncommo API (Zulu 8)"
mkdir -p "$WORK/commo/jni/classes"
# Only the public API package; InternalNativeInitializer is the ant-selected
# alternative to ExternalNativeInitializer (both declare NativeInitializer) —
# atak-headless loads the dylibs itself, which is what the External variant
# is for. commoncommotest is a desktop test harness, not part of the API.
find "$WORK/commo/jni/com/atakmap/commoncommo" -maxdepth 1 -name '*.java' \
  ! -name 'InternalNativeInitializer.java' > "$WORK/java-srcs.txt"
"$JDK/bin/javac" -d "$WORK/commo/jni/classes" @"$WORK/java-srcs.txt"
# Fresh-mtime .class files sit next to the .java sources; make's %.class
# rule (which shells out to ant) is satisfied and never runs.
cp -R "$WORK/commo/jni/classes/com" "$WORK/commo/jni/"

# --- JNI glue --------------------------------------------------------------
log "building libcommoncommojni (jni/native TARGET=macos)"
JNI_CXXFLAGS="-g -O2 -fPIC -std=c++17 -Wall -Wno-unused \
 -D__STDC_LIMIT_MACROS -DCURL_STATICLIB -fstack-protector-all \
 -I$WORK/commo/core/include -I$WORK/shim/include \
 -I$WORK/shim/PGSC_Utils/include \
 -I$JDK/include -I$JDK/include/darwin -I$WORK/shim/include/libxml2 \
 -Wno-deprecated-declarations"
make -C "$WORK/commo/jni/native" -j"$JOBS" all TARGET=macos \
  JAVA_HOME="$JDK" TAKTHIRDPARTYDIR="$WORK/shim" CURL_CONF="$CURL_CONF" \
  CXXFLAGS="$JNI_CXXFLAGS" LINK_FLAGS="-shared"

# --- Java jar --------------------------------------------------------------
log "packing jcommoncommo.jar"
"$JDK/bin/jar" cf "$OUT/jcommoncommo.jar" -C "$WORK/commo/jni/classes" com

# --- stage + wire @loader_path --------------------------------------------
log "staging → $OUT (install_name wiring + ad-hoc codesign)"
cp "$WORK/commo/core/impl/libcommoncommo.so" "$OUT/libcommoncommo.dylib"
cp "$WORK/commo/jni/native/libcommoncommojni.dylib" "$OUT/"
CORE_ID="$(otool -D "$OUT/libcommoncommo.dylib" | sed -n 2p | sed 's/^[[:space:]]*//')"
install_name_tool -id "@loader_path/libcommoncommo.dylib" "$OUT/libcommoncommo.dylib"
install_name_tool -change "$CORE_ID" "@loader_path/libcommoncommo.dylib" \
  "$OUT/libcommoncommojni.dylib"
codesign --force --sign - "$OUT/libcommoncommo.dylib" "$OUT/libcommoncommojni.dylib"

# --- canaries ---------------------------------------------------------------
log "canary 1/3: dlopen (jni pulls core via @loader_path)"
python3 - "$OUT/libcommoncommojni.dylib" <<'PY'
import ctypes, sys
ctypes.CDLL(sys.argv[1])
print("[g1-commo] dlopen OK:", sys.argv[1])
PY

log "canary 2/3: JNI exports"
nm -gU "$OUT/libcommoncommojni.dylib" | grep 'Java_com_atakmap_commoncommo' >/dev/null \
  || die "libcommoncommojni.dylib is missing the commoncommo JNI exports"

log "canary 3/3: JVM in-process Commo create"
cat > "$WORK/canary/CommoLoadSmoke.java" <<'JAVA'
import com.atakmap.commoncommo.Commo;
import com.atakmap.commoncommo.CommoException;
import com.atakmap.commoncommo.CommoLogger;

public class CommoLoadSmoke {
    public static class Quiet implements CommoLogger {
        public void log(CommoLogger.Level l, CommoLogger.Type t,
                        String m, CommoLogger.LoggingDetail d) {
            if (l == CommoLogger.Level.ERROR) System.err.println("[commo] " + m);
        }
    }
    public static void main(String[] args) throws CommoException {
        System.load(args[0]); // libcommoncommo.dylib
        System.load(args[1]); // libcommoncommojni.dylib
        Commo c = new Commo(new Quiet(), "g1-commo-canary", "CANARY");
        c.shutdown();
        System.out.println("COMMO-LOAD-OK");
    }
}
JAVA
"$JDK/bin/javac" -cp "$OUT/jcommoncommo.jar" -d "$WORK/canary" "$WORK/canary/CommoLoadSmoke.java"
"$JDK/bin/java" -cp "$OUT/jcommoncommo.jar:$WORK/canary" CommoLoadSmoke \
  "$OUT/libcommoncommo.dylib" "$OUT/libcommoncommojni.dylib" \
  | tee "$WORK/canary/out.txt" | grep -q COMMO-LOAD-OK \
  || { cat "$WORK/canary/out.txt" >&2 || true; die "JVM Commo canary failed"; }

log "G1.2 comms stack OK — dylibs + jar staged in g1/native-dist/"
file "$OUT/libcommoncommo.dylib" "$OUT/libcommoncommojni.dylib"
otool -L "$OUT/libcommoncommojni.dylib" | sed 's/^/  /'
ls -lh "$OUT"

