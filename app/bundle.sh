#!/usr/bin/env bash
#
# Assemble the macTAK app bundle (G3.0, `make app`): build/MacTAK.app with
#
#   Contents/MacOS/MacTAK              the SwiftUI app (swift build -c release)
#   Contents/Frameworks/               every native library the app loads:
#                                      the engine and its JNI glue, commo and
#                                      OpenSSL's legacy provider module,
#                                      ANGLE, GDAL's Java bindings, our own
#                                      GDAL/PROJ/libspatialite and the
#                                      Homebrew libraries they link, all
#                                      @rpath-relative (dev/deps/stage-runtime.py)
#   Contents/Resources/engine/
#     java/classes/                    the render-side classes (env.sh's javac pass)
#     java/*.jar                       gdal.jar, the takkernel jars, slf4j-simple
#     gdal/, proj/                     GDAL_DATA and PROJ's proj.db (dev/deps/dist/share)
#     data/                            the map's starting data (--layer etc.)
#     RUNTIME-MANIFEST.txt             each staged library's source and SHA-256
#     launch.json                      what the app boots with (LaunchConfig.swift)
#   Contents/Resources/egm96-15.grid   the EGM96 geoid, for altitudes in MSL (G3.6)
#   Contents/Resources/licenses/       third-party notices, every component's
#                                      license text and the GPL-3.0 source offer
#                                      (dev/deps/stage-licenses.py, check-licenses.py)
#
# The natives load nothing from the build machine (issue #152):
# dev/deps/check-bundle.py checks every Mach-O file, and the build fails
# unless it passes. Still to come before the bundle is distributable (G5):
# it starts the JDK 21 that /usr/libexec/java_home finds, and it is ad-hoc
# signed, like the dylibs it carries.
#
# Usage: app/bundle.sh [--layer FILE] [--basemap FILE] [--elevation PATH] (each repeatable)
#   With no data option, the map opens on the San Francisco landmarks
#   fixture, and on the G2 exit run's NAIP imagery and 3DEP terrain when
#   `make exit-run` has fetched them (dev/g2/build/exit-data).
# Prereqs: as dev/g2/shell/run.sh (an ANGLE engine build, the kernel jars,
#   `make gdal-java`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/app
REPO="$(cd "$HERE/.." && pwd)"
APP_OUT="$REPO/build/MacTAK.app"

layers=() basemaps=() elevations=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --layer|--basemap|--elevation)
      [[ $# -ge 2 ]] || { echo "bundle.sh: $1 needs a value" >&2; exit 2; }
      [[ -e "$2" ]] || { echo "bundle.sh: no such file: $2" >&2; exit 2; }
      case "$1" in
        --layer) layers+=("$2") ;;
        --basemap) basemaps+=("$2") ;;
        --elevation) elevations+=("$2") ;;
      esac
      shift 2 ;;
    *) echo "bundle.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
if [[ ${#layers[@]} -eq 0 && ${#basemaps[@]} -eq 0 && ${#elevations[@]} -eq 0 ]]; then
  layers=("$REPO/dev/g1/headless/test/fixtures/sf-landmarks.geojson")
  exit_data="$REPO/dev/g2/build/exit-data"
  if [[ -f "$exit_data/sf-naip-2024.tif" && -f "$exit_data/sf-3dep-13.tif" ]]; then
    basemaps=("$exit_data/sf-naip-2024.tif")
    elevations=("$exit_data/sf-3dep-13.tif")
  fi
fi

# The render-side build environment: compiles the classes when stale and
# sets DIST, OUT (the classes), CP (the jars) and GDAL_JAVA.
# shellcheck source=SCRIPTDIR/../dev/g2/render/env.sh
source "$REPO/dev/g2/render/env.sh"

swift build -c release --package-path "$HERE" --product MacTAK
BIN_DIR="$(swift build -c release --package-path "$HERE" --show-bin-path)"

rm -rf "$APP_OUT"
CONTENTS="$APP_OUT/Contents"
ENGINE="$CONTENTS/Resources/engine"
FRAMEWORKS="$CONTENTS/Frameworks"
mkdir -p "$CONTENTS/MacOS" "$ENGINE/java" "$ENGINE/data"
cp "$BIN_DIR/MacTAK" "$CONTENTS/MacOS/MacTAK"
cp "$HERE/Info.plist" "$CONTENTS/Info.plist"

cp -R "$OUT" "$ENGINE/java/classes"
jars=()
IFS=':' read -r -a cp_entries <<<"$CP"
for jar in "${cp_entries[@]}"; do
  cp "$jar" "$ENGINE/java/"
  jars+=("java/$(basename "$jar")")
done
# The natives and everything they load, relinked to find each other in
# Frameworks. commo goes in when it's built (dev/g1/build-commo.sh).
roots=("$DIST/libtakengine.dylib" "$DIST/libtakenginejni.dylib" "$DIST/libEGL.dylib" "$DIST/libGLESv2.dylib"
       "$GDAL_JAVA/libgdalalljni.dylib")
for f in "$DIST/libcommoncommo.dylib" "$DIST/libcommoncommojni.dylib"; do
  [[ -f "$f" ]] && roots+=("$f")
done
# OpenSSL's legacy provider, which commo loads for PKCS#12 files in RC2 or
# 3DES (ATAK's own, and the Keychain's exports); the app points
# OPENSSL_MODULES at Frameworks (CommsRuntime.swift, G3 trap 7)
legacy="$(brew --prefix openssl@3)/lib/ossl-modules/legacy.dylib"
[[ -f "$legacy" ]] || { echo "bundle.sh: no OpenSSL legacy provider at $legacy" >&2; exit 1; }
roots+=("$legacy")
python3 -I "$REPO/dev/deps/stage-runtime.py" "$FRAMEWORKS" "${roots[@]}"
# codesign treats every file in Frameworks as code: the manifest goes beside the data
mv "$FRAMEWORKS/RUNTIME-MANIFEST.txt" "$ENGINE/"
# ship only the Homebrew versions Brewfile.lock.json pins (#151)
python3 -I "$REPO/dev/deps/brew-pins.py" --manifest "$ENGINE/RUNTIME-MANIFEST.txt" \
  || { echo "bundle.sh: the bundle would ship unpinned Homebrew libraries" >&2; exit 1; }
cp -R "$DEPS/share/gdal" "$ENGINE/gdal"
cp -R "$DEPS/share/proj" "$ENGINE/proj"
# the EGM96 geoid for altitudes in MSL (G3.6): the engine's own grid
cp "$HERE/Resources/egm96-15.grid" "$CONTENTS/Resources/egm96-15.grid"

# Third-party notices, every component's license text and the GPL-3.0
# source offer (docs/license-audit.md): a pure function of licenses/,
# staged before codesign seals Resources.
python3 -I "$REPO/dev/deps/stage-licenses.py" "$CONTENTS/Resources/licenses" \
  || { echo "bundle.sh: license staging failed" >&2; exit 1; }

# copy one data file or directory into data/; print its bundle-relative path
stage() {
  cp -R "$1" "$ENGINE/data/"
  printf 'data/%s\n' "$(basename "$1")"
}
json_list() {   # the arguments as a JSON array of strings
  local out="" s
  for s in "$@"; do out+="${out:+, }\"${s//\"/\\\"}\""; done
  printf '[%s]' "$out"
}
staged_layers=() staged_basemaps=() staged_elevations=()
for f in ${layers[@]+"${layers[@]}"}; do staged_layers+=("$(stage "$f")"); done
for f in ${basemaps[@]+"${basemaps[@]}"}; do staged_basemaps+=("$(stage "$f")"); done
for f in ${elevations[@]+"${elevations[@]}"}; do staged_elevations+=("$(stage "$f")"); done

cat > "$ENGINE/launch.json" <<JSON
{
  "classpath": $(json_list java/classes "${jars[@]}"),
  "libs": ["../../Frameworks/libtakengine.dylib", "../../Frameworks/libtakenginejni.dylib"],
  "egl": "../../Frameworks/libEGL.dylib",
  "gles": "../../Frameworks/libGLESv2.dylib",
  "environment": {"GDAL_DATA": "\${ENGINE}/gdal", "PROJ_DATA": "\${ENGINE}/proj"},
  "jvmOptions": $(json_list "-Djava.library.path=\${ENGINE}/../../Frameworks" \
      "-Djava.awt.headless=true" "-XX:+UseZGC" "-XX:+ZGenerational" \
      "-Dmactak.gdal.data=\${ENGINE}/gdal" \
      "-Dorg.slf4j.simpleLogger.defaultLogLevel=${MACTAK_LOG_LEVEL:-warn}"),
  "layers": $(json_list ${staged_layers[@]+"${staged_layers[@]}"}),
  "basemaps": $(json_list ${staged_basemaps[@]+"${staged_basemaps[@]}"}),
  "elevations": $(json_list ${staged_elevations[@]+"${staged_elevations[@]}"})
}
JSON

codesign --force --sign - "$APP_OUT" >/dev/null 2>&1 \
  || { echo "bundle.sh: ad-hoc codesign failed" >&2; exit 1; }
python3 -I "$REPO/dev/deps/check-bundle.py" "$APP_OUT" \
  || { echo "bundle.sh: the bundle loads something from outside itself" >&2; exit 1; }
python3 -I "$REPO/dev/deps/check-licenses.py" --bundle "$APP_OUT" \
  || { echo "bundle.sh: the bundle carries something the license inventory doesn't know" >&2; exit 1; }
echo "bundle.sh: $APP_OUT ($(du -sh "$APP_OUT" | cut -f1))"
