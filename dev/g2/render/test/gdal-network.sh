#!/usr/bin/env bash
#
# G1 security canary, raster half (issue 155; the layer half is
# dev/g1/headless/test/gdal-network.sh): opening imagery or elevation must
# not make GDAL reach the network.
#
# Three hostile files, each pointing at a loopback listener that records
# every request (dev/g1/headless/test/http-witness.py):
#   hostile.vrt   a raster VRT whose source is /vsicurl/http://...
#   ovr/plain.tif a valid GeoTIFF without internal overviews, beside a
#                 plain.tif.ovr that is really such a VRT: GDAL opens a
#                 raster's .ovr with every driver, whatever the main open
#                 allowed, so a driver list in the open call can't stop it
#   hostile.wms   a GDAL_WMS service description (a driver that fetches
#                 through GDAL's own HTTP client, not /vsicurl)
#
# Control: stock GDAL opens each file and must make the listener see a
# request, which proves the files are hostile on this GDAL. Then the
# engine opens them the way the app does, as a basemap (GdalLayerInfo →
# GdalTileReader, zoomed out so overviews are read) or as elevation
# (GdalElevationChunk), and the listener must see none. The legs are the
# four that fetch without the fix; the other two pairings (the .ovr as
# elevation, the WMS file as a basemap) made no request either way.
#
# PASS = the control fetched and the engine did not. Without
# patches/gdal-offline-only.patch (GdalLibrary.java → keepOffline() in
# dev/g1/jni-extra/mactak_gdal.cpp) all four legs fetch (dev/g1/NOTES.md
# §G1.26 has the A/B).
#
# Needs what dev/g2/render/run.sh needs (ANGLE engine, make gdal-java) and
# the GDAL CLI (the control and the fixture).
# shellcheck disable=SC2317,SC2329  # invoked via trap (SC2317 on shellcheck < 0.10)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/render/test
ROOT="$(cd "$HERE/../../../.." && pwd)"
WITNESS="$ROOT/dev/g1/headless/test/http-witness.py"
WORK="$(mktemp -d)"
WITNESS_PID=""
cleanup() {
  if [[ -n "$WITNESS_PID" ]]; then
    kill "$WITNESS_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

log() { printf '[gdal-network-raster] %s\n' "$*"; }

HITS="$WORK/requests.log"
: > "$HITS"
python3 -I "$WITNESS" "$WORK/port" "$HITS" &
WITNESS_PID=$!
for _ in $(seq 1 50); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
[[ -s "$WORK/port" ]] || { log "FAIL: the listener did not start"; exit 1; }
BASE="http://127.0.0.1:$(tr -d '[:space:]' < "$WORK/port")"

# raster_vrt W H BANDS NAME — a VRT whose every band reads $BASE/NAME
raster_vrt() {
  local b bands=""
  for (( b = 1; b <= $3; b++ )); do
    bands+="<VRTRasterBand dataType=\"Byte\" band=\"$b\"><SimpleSource><SourceFilename>/vsicurl/$BASE/$4</SourceFilename><SourceBand>$b</SourceBand></SimpleSource></VRTRasterBand>"
  done
  printf '%s\n' "<VRTDataset rasterXSize=\"$1\" rasterYSize=\"$2\"><SRS>EPSG:4326</SRS><GeoTransform>-122.45, 0.001, 0, 37.80, 0, -0.001</GeoTransform>$bands</VRTDataset>"
}

# write_hostile DIR — the three files, fresh
write_hostile() {
  mkdir -p "$1/ovr"
  raster_vrt 10 10 1 vrt-source.tif > "$1/hostile.vrt"
  # 1/4 of the imagery fixture, no internal overviews, so GDAL looks for .ovr
  gdal_translate -q -outsize 25% 25% "$FIXTURE" "$1/ovr/plain.tif"
  raster_vrt 406 350 3 ovr-source.tif > "$1/ovr/plain.tif.ovr"
  cat > "$1/hostile.wms" <<WMS
<GDAL_WMS><Service name="WMS"><ServerUrl>$BASE/wms?</ServerUrl><Layers>x</Layers></Service>
<DataWindow><UpperLeftX>-122.6</UpperLeftX><UpperLeftY>37.9</UpperLeftY><LowerRightX>-122.3</LowerRightX><LowerRightY>37.7</LowerRightY><SizeX>512</SizeX><SizeY>512</SizeY></DataWindow></GDAL_WMS>
WMS
}

requests() { wc -l < "$HITS" | tr -d ' '; }
FILES=(hostile.vrt ovr/plain.tif hostile.wms)
rc=0

FIXTURE="$ROOT/dev/g2/build/fixtures/sf-imagery.tif"
[[ -f "$FIXTURE" ]] || bash "$ROOT/dev/g2/fixtures/make-imagery.sh" "$FIXTURE" > /dev/null

# --- control: stock GDAL fetches --------------------------------------------
write_hostile "$WORK/control"
for f in "${FILES[@]}"; do
  before="$(requests)"
  # a 2x2 copy reads the smallest overview, as a zoomed-out map does
  gdal_translate -q -outsize 2 2 "$WORK/control/$f" "$WORK/control/out.tif" > /dev/null 2>&1 || true
  if [[ "$(requests)" -gt "$before" ]]; then
    log "ok   control: gdal_translate $f reached the listener ($(( $(requests) - before )) request(s))"
  else
    log "FAIL control: gdal_translate $f made no request, so this run proves nothing"; rc=1
  fi
done

# --- the engine's raster paths must not ------------------------------------
write_hostile "$WORK/engine"
# zoomed out (200 m/px over the fixture's area) so the tile reader wants overviews
CAMERA=(--at "37.795,-122.445" --res 200 --frames 30)
LEGS=(hostile.vrt:basemap hostile.vrt:elevation ovr/plain.tif:basemap hostile.wms:elevation)
for leg in "${LEGS[@]}"; do
  f="${leg%%:*}" path="${leg#*:}"
  before="$(requests)" ec=0
  run_log="$WORK/$(basename "$f").$path.log"
  # exit 1 is expected: the frame gates fail (no pixels, or too few at this zoom)
  bash "$ROOT/dev/g2/render/run.sh" "--$path" "$WORK/engine/$f" "${CAMERA[@]}" > "$run_log" 2>&1 || ec=$?
  if (( ec > 128 )); then
    log "FAIL $f as $path: the smoke died (exit $ec)"; rc=1
    tail -15 "$run_log" | sed 's/^/    | /'
  elif [[ "$(requests)" -gt "$before" ]]; then
    log "FAIL $f as $path: opening it reached the network ($(( $(requests) - before )) request(s)), first:"; rc=1
    sed -n "$(( before + 1 )),$(( before + 3 ))s/^/    /p" "$HITS"
  else
    log "ok   $f as $path: no request (exit $ec)"
  fi
done

if [[ "$rc" == 0 ]]; then
  log "PASS: imagery and elevation open without reaching the network"
else
  log "FAIL"
fi
exit "$rc"
