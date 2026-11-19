#!/usr/bin/env bash
#
# Build ANGLE (EGL + GLES on Metal) from a pinned upstream commit and stage
# the libEGL/libGLESv2 pair into dev/g2/angle-dist/ (issue #139).
#
# Electron 44+ links ANGLE into "Electron Framework" and no longer ships the
# standalone pair, so the newest bundle fetch-angle.sh can take is 43.x
# (chromium/7871, out of Google's support). This builds the branch of
# Chrome's Extended Stable milestone instead.
#
#   bash dev/g2/build-angle.sh            # fetch (first run ~GBs), build, stage
#   MACTAK_ANGLE_REV=<sha> ...            # another pinned commit
#
# The checkout, depot_tools and the build tree live under dev/g2/build/angle/
# (ignored). dev/g2/angle-patches/*.patch are applied on top of the pin
# (presented-times.patch: the exit run's on-screen timing, trap #77). Staging goes through fetch-angle.sh with MACTAK_ANGLE_SRC, so the
# pair gets the same arm64 / @rpath / signing / export checks as a bundle's.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2

# chromium/8078 = Chrome 156 (Extended Stable from 2026-11), the ANGLE that
# Electron 45 links in. Head of the branch on 2026-11-19.
ANGLE_BRANCH="chromium/8078"
ANGLE_REV="${MACTAK_ANGLE_REV:-0b547a1161fbc361df600d7976d8bd866bc65311}"
ANGLE_URL="https://chromium.googlesource.com/angle/angle"
DEPOT_TOOLS_URL="https://chromium.googlesource.com/chromium/tools/depot_tools.git"

# The app's floor (G3 trap 3: every bundled native library targets it).
MACOS_FLOOR="27.0"

WORK="$HERE/build/angle"
SRC="$WORK/angle"
OUT="$SRC/out/mactak-release"
PATCHES="$HERE/angle-patches"

log() { printf '[build-angle] %s\n' "$*"; }

# depot_tools reports usage to Google unless told not to.
export DEPOT_TOOLS_METRICS=0

require_metal_toolchain() {
  # ANGLE compiles its internal shaders with `xcrun metal`, which Xcode 26+
  # ships as a separate download; without it the build fails 3 steps in.
  xcrun metal --version >/dev/null 2>&1 || {
    echo "FATAL: no Metal Toolchain. Run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  }
}

fetch_depot_tools() {
  if [[ ! -d "$WORK/depot_tools/.git" ]]; then
    log "cloning depot_tools"
    git clone --quiet "$DEPOT_TOOLS_URL" "$WORK/depot_tools"
  fi
  export PATH="$WORK/depot_tools:$PATH"
}

fetch_angle() {
  if [[ ! -d "$SRC/.git" ]]; then
    log "cloning ANGLE"
    git clone --quiet "$ANGLE_URL" "$SRC"
  fi
  local have
  have="$(git -C "$SRC" rev-parse HEAD)"
  if [[ "$have" != "$ANGLE_REV" ]]; then
    git -C "$SRC" fetch --quiet origin "refs/heads/$ANGLE_BRANCH"
  fi
  # --force drops the previous run's patches, so apply_patches starts clean
  git -C "$SRC" checkout --quiet --force --detach "$ANGLE_REV"
  # bootstrap.py writes the standalone .gclient; gclient pulls the toolchain
  # (Chromium's clang, gn) and third_party deps pinned by ANGLE's DEPS.
  [[ -f "$SRC/.gclient" ]] || (cd "$SRC" && python3 scripts/bootstrap.py)
  log "gclient sync at $ANGLE_REV"
  (cd "$SRC" && gclient sync --no-history --shallow --delete_unversioned_trees)
}

apply_patches() {
  # macTAK's changes to ANGLE, one per file in dev/g2/angle-patches/ (made
  # with `git diff` in the checkout), applied in name order
  local p
  for p in "$PATCHES"/*.patch; do
    [[ -e "$p" ]] || continue
    log "patch $(basename "$p")"
    git -C "$SRC" apply --whitespace=nowarn "$p"
  done
}

configure() {
  # Metal only: no Vulkan, desktop GL, SwiftShader or null backends, no tests.
  # symbol_level=1 keeps line tables so stack samples symbolize (trap #77).
  # treat_warnings_as_errors=false: Chrome targets macOS 12, so upstream never
  # sees what the macOS 27 floor deprecates (MTLGPUFamilyMac2 in
  # apple_platform_utils.mm); deprecated still works, and -Werror stops the build.
  local args=(
    'treat_warnings_as_errors=false'
    'is_debug=false'
    'is_component_build=false'
    'target_cpu="arm64"'
    "mac_deployment_target=\"$MACOS_FLOOR\""
    'symbol_level=1'
    'angle_enable_metal=true'
    'angle_enable_vulkan=false'
    'angle_enable_gl=false'
    'angle_enable_swiftshader=false'
    'angle_enable_null=false'
    'angle_enable_wgpu=false'
    'angle_build_tests=false'
  )
  log "gn gen ${OUT#"$HERE/"}"
  (cd "$SRC" && gn gen "$OUT" --args="${args[*]}")
}

build() {
  log "ninja libEGL libGLESv2"
  (cd "$SRC" && autoninja -C "$OUT" libEGL libGLESv2)
}

stage() {
  MACTAK_ANGLE_SRC="$OUT" bash "$HERE/fetch-angle.sh"
  {
    echo "angle_branch: $ANGLE_BRANCH"
    echo "angle_rev: $ANGLE_REV"
    local p
    for p in "$PATCHES"/*.patch; do
      [[ -e "$p" ]] && echo "angle_patch: $(basename "$p") $(shasum -a 256 "$p" | cut -d' ' -f1)"
    done
    echo "gn_args: $(tr '\n' ' ' < "$OUT/args.gn")"
    echo "min_macos: $(otool -l "$HERE/angle-dist/libGLESv2.dylib" | awk '/LC_BUILD_VERSION/ { f = 1 } f && $1 == "minos" && !done { print $2; done = 1 }')"
  } >> "$HERE/angle-dist/PROVENANCE.txt"
  log "built from $ANGLE_BRANCH @ $ANGLE_REV"
}

require_metal_toolchain
mkdir -p "$WORK"
fetch_depot_tools
fetch_angle
apply_patches
configure
build
stage
