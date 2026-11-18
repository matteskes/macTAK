#!/usr/bin/env bash
#
# The app bundle's natives run on their own (`make test-app-bundle`, issue
# #152). check-bundle.py proves statically that every Mach-O file in
# build/MacTAK.app links only what the bundle carries; this proves it at
# runtime: RenderSmoke, from the bundle's classes and jars, renders through
# the bundle's Frameworks with the bundle's GDAL and PROJ data, and dyld
# must load nothing from outside the bundle, /usr/lib, /System and the JDK.
# The app itself then starts commo (--check-comms-runtime), which must load
# OpenSSL's legacy provider from the bundle (G3.2d), and boots its JVM to
# draw MIL-STD-2525 symbols with the bundled renderers (--check-symbols, G3.7a).
#
# The render: the synthetic UTM 10N GeoTIFF (make-imagery.sh), reprojected
# to WGS 84 by PROJ (so proj.db must be the bundle's), with three ground
# points that must have their field's colour, plus the GeoJSON landmarks.
# dev/deps/dist, where the build tree's GDAL/PROJ and proj.db live, is moved
# aside for the run, so neither can stand in for the bundle's.
#
# Needs: build/MacTAK.app (make app), JDK 21, the GDAL CLI (make-imagery.sh).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/app/test
ROOT="$(cd "$HERE/../.." && pwd)"
APP="$ROOT/build/MacTAK.app"
FRAMEWORKS="$APP/Contents/Frameworks"
ENGINE="$APP/Contents/Resources/engine"
DEPS="$ROOT/dev/deps/dist"
DEPS_ASIDE="$ROOT/dev/deps/dist.aside-for-bundle-test"

log() { printf '[app-bundle] %s\n' "$*"; }
die() { log "FAIL: $*" >&2; exit 1; }

[[ -f "$FRAMEWORKS/libtakengine.dylib" ]] || die "no $APP — run make app"
# shellcheck source=SCRIPTDIR/../../dev/jdk.sh
source "$ROOT/dev/jdk.sh"
JDK="$(mactak_jdk_home 21)" || die "JDK 21 not found (dev/jdk.sh)"
JDK="$(cd "$JDK" && pwd -P)"

WORK="$(mktemp -d)"
restore() {
  [[ -d "$DEPS_ASIDE" ]] && mv "$DEPS_ASIDE" "$DEPS"
  rm -rf "$WORK"
}
trap restore EXIT

FIX="$ROOT/dev/g2/build/fixtures"
mkdir -p "$FIX"
bash "$ROOT/dev/g2/fixtures/make-imagery.sh" "$FIX/sf-imagery.tif" > /dev/null

# MakeImagery's field colour at a point (as render/test/geotiff.sh)
POINTS=("37.7725,-122.4775" "37.8175,-122.4125" "37.7875,-122.4375")
expects=()
for p in "${POINTS[@]}"; do
  colour="$(python3 -c '
import math, sys
lat, lon = (float(v) for v in sys.argv[1].split(","))
fields = ["3f7a4a", "5e8f3e", "2f6e73", "4c8a6a"]
print(fields[(math.floor(lon / 0.005) * 3 + math.floor(lat / 0.005) * 5) % 4])' "$p")"
  expects+=(--expect "$p,$colour")
done

# launch.json's classpath, in its order: the render classes shadow engine
# classes, and android-port must come last, as the app boots it
classpath="$(python3 -I -c '
import json, os, sys
engine = sys.argv[1]
print(":".join(os.path.join(engine, p) for p in json.load(open(os.path.join(engine, "launch.json")))["classpath"]))
' "$ENGINE")"

# smoke LOGNAME RENDER_ARGS... — RenderSmoke from the bundle alone, with
# dyld naming every image it loads; returns the smoke's exit code
smoke() {
  local name="$1"; shift
  set +e
  GDAL_DATA="$ENGINE/gdal" PROJ_DATA="$ENGINE/proj" MACTAK_HOME="$WORK" DYLD_PRINT_LIBRARIES=1 \
    "$JDK/bin/java" -classpath "$classpath" \
      -Djava.library.path="$FRAMEWORKS" -Djava.awt.headless=true \
      -Dmactak.gdal.data="$ENGINE/gdal" \
      -Dorg.slf4j.simpleLogger.defaultLogLevel=warn \
      mactak.render.RenderSmoke \
      --lib "$FRAMEWORKS/libtakengine.dylib" --lib "$FRAMEWORKS/libtakenginejni.dylib" \
      --egl "$FRAMEWORKS/libEGL.dylib" --gles "$FRAMEWORKS/libGLESv2.dylib" \
      --out "$WORK/$name.png" "$@" > "$WORK/$name.log" 2>&1
  local rc=$?
  set -e
  grep -E '^render-smoke: (basemap|layer|expect|PASS|FAIL)' "$WORK/$name.log" | sed 's/^/    /' || true
  return "$rc"
}

[[ -d "$DEPS" ]] && mv "$DEPS" "$DEPS_ASIDE"
status=0
log "1. GeoTIFF through GDAL, reprojected by PROJ: three ground points (dev/deps/dist moved aside)"
smoke imagery --basemap "$FIX/sf-imagery.tif" --at "37.795,-122.445" --res 15 "${expects[@]}" \
  || { log "FAIL: the imagery render failed"; tail -15 "$WORK/imagery.log" | sed 's/^/    | /'; status=1; }
grep -q 'render-smoke: basemap sf-imagery.tif type=native provider=gdal' "$WORK/imagery.log" \
  || { log "FAIL: the GeoTIFF was not described by GDAL"; status=1; }
log "2. GeoJSON through OGR into the feature store"
smoke layer --layer "$ROOT/dev/g1/headless/test/fixtures/sf-landmarks.geojson" \
  || { log "FAIL: the layer render failed"; tail -15 "$WORK/layer.log" | sed 's/^/    | /'; status=1; }

log "3. commo starts from the bundle and loads OpenSSL's legacy provider from it (G3 trap 7)"
set +e
DYLD_PRINT_LIBRARIES=1 "$APP/Contents/MacOS/MacTAK" --check-comms-runtime > "$WORK/comms.log" 2>&1
comms_rc=$?
set -e
grep '^check-comms-runtime:' "$WORK/comms.log" | sed 's/^/    /' || true
(( comms_rc == 0 )) || { log "FAIL: commo didn't load the legacy provider"; status=1; }
grep -qE "^dyld\[[0-9]+\]: (<[0-9A-F-]+> )?($(cd "$APP" && pwd -P)|$APP)/Contents/Frameworks/legacy.dylib$" "$WORK/comms.log" \
  || { log "FAIL: legacy.dylib didn't load from the bundle's Frameworks"; status=1; }

log "4. the bundle's JVM draws MIL-STD-2525 symbols, 2525C and 2525D (G3.7a)"
set +e
DYLD_PRINT_LIBRARIES=1 "$APP/Contents/MacOS/MacTAK" --check-symbols > "$WORK/symbols.log" 2>&1
symbols_rc=$?
set -e
grep '^check-symbols:' "$WORK/symbols.log" | sed 's/^/    /' || true
(( symbols_rc == 0 )) || { log "FAIL: the bundle's renderers didn't draw as expected"; status=1; }

# "dyld[PID]: <UUID> PATH" (or, on older systems, "dyld[PID]: PATH"); dyld's
# other lines ("move loaded to delayed: ...") name no path
loaded="$(sed -nE 's#^dyld\[[0-9]+\]: (<[0-9A-F-]+> )?(/.*)$#\2#p' "$WORK/imagery.log" "$WORK/layer.log" "$WORK/comms.log" "$WORK/symbols.log" | sort -u)"
[[ -n "$loaded" ]] || die "dyld reported no images (DYLD_PRINT_LIBRARIES had no effect?)"
app_real="$(cd "$APP" && pwd -P)"
outside="$(grep -vE "^($app_real/|$APP/|/usr/lib/|/System/|$JDK/)" <<<"$loaded" || true)"
from_app="$(grep -cE "^($app_real|$APP)/Contents/Frameworks/" <<<"$loaded" || true)"
if [[ -n "$outside" ]]; then
  log "FAIL: images loaded from outside the bundle, /usr/lib, /System and the JDK:"
  while IFS= read -r image; do printf '    %s\n' "$image"; done <<<"$outside"
  status=1
fi
(( status == 0 )) || exit 1
log "PASS: both renders ran on the bundle's $from_app Frameworks libraries and its GDAL/PROJ data, commo loaded the bundle's legacy provider, its JVM drew 2525 symbols; nothing loaded from outside it"
