#!/usr/bin/env bash
#
# G2 spike: stage an ANGLE (EGL + GLES on Metal) runtime into
# dev/g2/angle-dist/ so it can occupy the engine's GLES-stub link slot.
#
# Source, in order:
#   1. $MACTAK_ANGLE_SRC — a directory holding libEGL.dylib + libGLESv2.dylib
#      (e.g. your own ANGLE build: out/Release)
#   2. an installed Electron app's bundled ANGLE (VS Code by default; any
#      Electron app works — see ELECTRON_APPS). Electron ships upstream ANGLE
#      (BSD-3) with the Metal backend enabled; this is a spike-grade source,
#      the port builds ANGLE from source at G5 (see NOTES.md).
#   3. the official Electron release zip (darwin-arm64, sha256-pinned below)
#      downloaded into dev/g2/build/ — hermetic path for CI runners.
#      MACTAK_ANGLE_SOURCE=release forces it even when an app is installed.
#
# What gets done to the copies:
#   - lipo -thin arm64 (Electron ships universal)
#   - install names rewritten to @rpath/<name>.dylib (Electron's are "./x")
#   - ad-hoc re-signed (install_name_tool invalidates the original signature)
#   - PROVENANCE.txt records source, versions, sha256
#
# Usage: dev/g2/fetch-angle.sh [dest-dir]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2
DEST="${1:-$HERE/angle-dist}"

ELECTRON_APPS=(
  "/Applications/Visual Studio Code.app"
  "/Applications/Visual Studio Code - Insiders.app"
  "/Applications/Slack.app"
  "/Applications/Discord.app"
  "/Applications/Obsidian.app"
)

# Pinned Electron release for the download path (SHASUMS256.txt of the release).
# Must stay <= 43.x: from Electron 44/45 (Chrome >= 144) ANGLE is linked into
# "Electron Framework" and no standalone libEGL/libGLESv2 ship any more.
ELECTRON_VER="${MACTAK_ELECTRON_VER:-43.7.7}"
ELECTRON_SHA256="${MACTAK_ELECTRON_SHA256:-9327d8ba5bc9e279d1a2f7da90235301c65a2e80eb4ad3bc5610d28d483340f9}"

log() { printf '[fetch-angle] %s\n' "$*"; }

SRC=""
APP=""
if [[ -n "${MACTAK_ANGLE_SRC:-}" ]]; then
  SRC="$MACTAK_ANGLE_SRC"
elif [[ "${MACTAK_ANGLE_SOURCE:-}" != release ]]; then
  for app in "${ELECTRON_APPS[@]+"${ELECTRON_APPS[@]}"}"; do
    cand="$app/Contents/Frameworks/Electron Framework.framework/Libraries"
    if [[ -f "$cand/libEGL.dylib" && -f "$cand/libGLESv2.dylib" ]]; then
      SRC="$cand"; APP="$app"; break
    fi
  done
fi
if [[ -z "$SRC" ]]; then
  zip="$HERE/build/electron-v$ELECTRON_VER-darwin-arm64.zip"
  unpacked="$HERE/build/electron-v$ELECTRON_VER"
  if [[ ! -d "$unpacked/Electron.app" ]]; then
    log "no local Electron app; downloading electron v$ELECTRON_VER (darwin-arm64, ~120 MB)"
    mkdir -p "$HERE/build"
    # --retry-all-errors: a dropped mid-transfer connection (curl 56, e.g. a
    # 504 from the release CDN) is outside curl's default transient set, and
    # a single-shot 120 MB fetch fails the whole CI job when it happens.
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --retry-max-time 600 -o "$zip.tmp" \
      "https://github.com/electron/electron/releases/download/v$ELECTRON_VER/electron-v$ELECTRON_VER-darwin-arm64.zip"
    echo "$ELECTRON_SHA256  $zip.tmp" | shasum -a 256 -c - >/dev/null \
      || { rm -f "$zip.tmp"; echo "FATAL: electron zip checksum mismatch" >&2; exit 1; }
    mv "$zip.tmp" "$zip"
    rm -rf "$unpacked"; mkdir -p "$unpacked"
    ditto -x -k "$zip" "$unpacked"   # ditto preserves the framework symlinks unzip mangles
  fi
  APP="$unpacked/Electron.app"
  SRC="$APP/Contents/Frameworks/Electron Framework.framework/Libraries"
fi
[[ -f "$SRC/libEGL.dylib" && -f "$SRC/libGLESv2.dylib" ]] || {
  echo "FATAL: no ANGLE at $SRC. Set MACTAK_ANGLE_SRC=<dir with libEGL.dylib + libGLESv2.dylib>" >&2
  exit 1
}
log "source: $SRC"

mkdir -p "$DEST"
for lib in libEGL libGLESv2; do
  in="$SRC/$lib.dylib"; out="$DEST/$lib.dylib"
  # capture, then grep: grep -q at a pipe's end under pipefail (G1 trap 2)
  arch_info="$(lipo -info "$in" 2>/dev/null || true)"
  if grep -q 'arm64' <<<"$arch_info"; then
    if grep -q 'Non-fat' <<<"$arch_info"; then cp -f "$in" "$out"; else lipo -thin arm64 "$in" -output "$out"; fi
  else
    echo "FATAL: $in has no arm64 slice" >&2; exit 1
  fi
  chmod u+w "$out"
  # The install-name rewrite is the point of the staging: Electron's copies
  # carry "./x" ids, and a silently skipped rewrite leaves them for dyld to
  # trip over far from here. Run install_name_tool with its stderr intact
  # and assert the result (otool -D's second line, first field) instead of
  # discarding its output.
  install_name_tool -id "@rpath/$lib.dylib" "$out"
  got_id="$(otool -D "$out" | awk 'NR == 2 { print $1 }')"
  [[ "$got_id" == "@rpath/$lib.dylib" ]] \
    || { echo "FATAL: install-name rewrite failed for $out (otool -D: ${got_id:-none})" >&2; exit 1; }
  # Keep stderr (stdout is quiet): under set -e a swallowed codesign failure
  # would exit with zero diagnostics — same rationale as install_name_tool above.
  codesign --force --sign - "$out" >/dev/null
  log "staged $out ($(stat -f %z "$out") bytes)"
done

# libEGL is ANGLE's thin loader: it dlopens libGLESv2 from its own directory,
# so no install-name edit is needed for the pair to find each other.
nm -gU "$DEST/libGLESv2.dylib" | grep ' T _glDrawArrays$' >/dev/null \
  || { echo "FATAL: libGLESv2 lacks GL ES exports" >&2; exit 1; }
nm -gU "$DEST/libEGL.dylib" | grep ' T _eglGetPlatformDisplayEXT$' >/dev/null \
  || { echo "FATAL: libEGL lacks eglGetPlatformDisplayEXT (ANGLE platform selection)" >&2; exit 1; }
egl_linkage="$(otool -L "$DEST/libEGL.dylib")"
grep -q 'Metal.framework' <<<"$egl_linkage" \
  || log "WARNING: libEGL does not link Metal.framework — backend may not be Metal"

{
  echo "source_dir: $SRC"
  if [[ -n "$APP" ]]; then
    echo "source_app: $APP $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
    fw="$APP/Contents/Frameworks/Electron Framework.framework/Electron Framework"
    # awk, not grep -m1: early exit + pipefail = SIGPIPE false failure (G1 trap 2)
    [[ -f "$fw" ]] && echo "electron: $(strings "$fw" | awk '/^Chrome\/[0-9.]+ Electron\/[0-9.]+$/ && !f { print; f=1 }')"
  fi
  echo "staged: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "license: ANGLE, BSD-3-Clause (https://chromium.googlesource.com/angle/angle)"
  for lib in libEGL libGLESv2; do echo "sha256 $lib.dylib: $(shasum -a 256 "$DEST/$lib.dylib" | cut -d' ' -f1)"; done
} > "$DEST/PROVENANCE.txt"
log "ANGLE staged in $DEST"
sed 's/^/[fetch-angle]   /' "$DEST/PROVENANCE.txt"
