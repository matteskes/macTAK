#!/usr/bin/env bash
#
# Assemble the macTAK app bundle (G3.0, `make app`): build/MacTAK.app with
#
#   Contents/MacOS/MacTAK              the SwiftUI app (swift build -c release)
#   Contents/Resources/engine/
#     java/classes/                    the render-side classes (env.sh's javac pass)
#     java/*.jar                       gdal.jar, the takkernel jars, slf4j-simple
#     lib/                             the engine natives and ANGLE (native-dist)
#     gdal/                            libgdalalljni.dylib (GDAL's Java bindings)
#     data/                            the map's starting data (--layer etc.)
#     launch.json                      what the app boots with (LaunchConfig.swift)
#
# A development bundle for this Mac, not a distributable one: it starts the
# JDK 21 that /usr/libexec/java_home finds, and the engine's natives still
# link Homebrew's GDAL, PROJ and friends by absolute path. A self-contained,
# signed bundle is G5's work. Ad-hoc signed, like the dylibs it carries.
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
GDAL_DATA_DIR="${GDAL_DATA:-$(gdal-config --datadir 2>/dev/null || echo /opt/homebrew/opt/gdal/share/gdal)}"

swift build -c release --package-path "$HERE" --product MacTAK
BIN_DIR="$(swift build -c release --package-path "$HERE" --show-bin-path)"

rm -rf "$APP_OUT"
CONTENTS="$APP_OUT/Contents"
ENGINE="$CONTENTS/Resources/engine"
mkdir -p "$CONTENTS/MacOS" "$ENGINE/java" "$ENGINE/lib" "$ENGINE/gdal" "$ENGINE/data"
cp "$BIN_DIR/MacTAK" "$CONTENTS/MacOS/MacTAK"
cp "$HERE/Info.plist" "$CONTENTS/Info.plist"

cp -R "$OUT" "$ENGINE/java/classes"
jars=()
IFS=':' read -r -a cp_entries <<<"$CP"
for jar in "${cp_entries[@]}"; do
  cp "$jar" "$ENGINE/java/"
  jars+=("java/$(basename "$jar")")
done
cp "$DIST"/*.dylib "$ENGINE/lib/"
cp "$GDAL_JAVA/libgdalalljni.dylib" "$ENGINE/gdal/"

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
  "libs": ["lib/libtakengine.dylib", "lib/libtakenginejni.dylib"],
  "egl": "lib/libEGL.dylib",
  "gles": "lib/libGLESv2.dylib",
  "jvmOptions": $(json_list "-Djava.library.path=\${ENGINE}/lib:\${ENGINE}/gdal" \
      "-Djava.awt.headless=true" "-XX:+UseZGC" "-XX:+ZGenerational" \
      "-Dmactak.gdal.data=$GDAL_DATA_DIR" \
      "-Dorg.slf4j.simpleLogger.defaultLogLevel=${MACTAK_LOG_LEVEL:-warn}"),
  "layers": $(json_list ${staged_layers[@]+"${staged_layers[@]}"}),
  "basemaps": $(json_list ${staged_basemaps[@]+"${staged_basemaps[@]}"}),
  "elevations": $(json_list ${staged_elevations[@]+"${staged_elevations[@]}"})
}
JSON

codesign --force --sign - "$APP_OUT" >/dev/null 2>&1 \
  || { echo "bundle.sh: ad-hoc codesign failed" >&2; exit 1; }
echo "bundle.sh: $APP_OUT ($(du -sh "$APP_OUT" | cut -f1))"
