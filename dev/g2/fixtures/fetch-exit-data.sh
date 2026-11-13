#!/usr/bin/env bash
#
# Fetch the G2 exit run's real data (dev/g2/NOTES.md "The exit run's real
# data"): a 4 km x 4 km clip from Golden Gate Park to Twin Peaks of
#
#   imagery    USDA NAIP, 2024-05-29 flight, 60 cm, bands 1-3 (RGB), from
#              Microsoft Planetary Computer's public NAIP container
#   elevation  USGS 3DEP 1/3 arc-second (~10 m), "current", from The
#              National Map's public S3 bucket
#
# Both are public domain and Cloud-Optimized GeoTIFFs: GDAL reads only the
# window it needs over plain anonymous HTTPS (/vsicurl/), about 50 MB.
#
# Pinned by per-band pixel checksums (gdalinfo -checksum) of the windows as
# fetched, at the source's own resolution, not by file hashes: providers
# re-encode files (the NAIP file was rewritten on 2026-10-30) and a pixel
# checksum changes only when the pixels do. The fetch fails if they differ.
#
# Built from the pinned windows (not pinned themselves; GDAL's resampling
# may change between versions):
#
#   dev/g2/build/exit-data/sf-naip-2024.tif   RGB resampled to 1.2 m (average),
#       NAD83 / UTM 10N, 256x256 tiles, DEFLATE, overviews 2-16 (~40 MB)
#   dev/g2/build/exit-data/sf-3dep-13.tif     the 3DEP window as fetched, with
#       its vertical datum stamped: NAD83 + NAVD88 height (EPSG:4269+5703)
#
# The stamp: 3DEP's metadata says its heights are NAVD88 (sea level), but
# the GeoTIFF declares no vertical datum at all, so the engine would take
# them as ellipsoid heights, about 32 m high at San Francisco (G2 trap #74).
# Stamped, GdalElevationChunk's autoDetectMsl sees a gravity-related height
# and adds the geoid, as for DTED.
#
# Gitignored; re-running reuses the windows when their checksums still hold.
#
# Usage: dev/g2/fixtures/fetch-exit-data.sh [OUT_DIR]   (default dev/g2/build/exit-data)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2/fixtures
OUT="${1:-$HERE/../build/exit-data}"

NAIP_URL="https://naipeuwest.blob.core.windows.net/naip/v002/ca/2024/ca_060cm_2024/37122/m_3712213_sw_10_060_20240529.tif"
# pixels (2820, 4767) + 6667 x 6667 at 0.6 m: UTM 10N x 545502.0 .. 549502.2, y 4178499.6 .. 4182499.8
NAIP_SRCWIN=(2820 4767 6667 6667)
NAIP_CHECKSUMS="54466 11900 13171"
DEM_URL="https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/current/n38w123/USGS_13_n38w123.tif"
# pixels (5584, 2285) + 496 x 398 at 1/3": lon -122.48352 .. -122.43759, lat 37.75213 .. 37.78898
# (the imagery's square, plus a few cells)
DEM_SRCWIN=(5584 2285 496 398)
DEM_CHECKSUMS="46446"

for t in gdal_translate gdaladdo gdalinfo; do
  command -v "$t" >/dev/null 2>&1 || { echo "fetch-exit-data: missing $t (brew install gdal)" >&2; exit 1; }
done
mkdir -p "$OUT"

# Only the bytes GDAL asks for; no directory listing of the containers.
export GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR GDAL_HTTP_MULTIRANGE=YES GDAL_HTTP_MERGE_CONSECUTIVE_RANGES=YES

checksums() { gdalinfo -checksum "$1" | sed -nE 's/^ *Checksum=([0-9]+)$/\1/p' | tr '\n' ' ' | sed 's/ $//'; }

# fetch NAME URL "PINS" GDAL_TRANSLATE_ARGS...: the pinned window, as OUT/NAME
fetch() {
  local name="$1" url="$2" pins="$3"; shift 3
  local file="$OUT/$name"
  if [[ -f "$file" && "$(checksums "$file")" == "$pins" ]]; then
    echo "fetch-exit-data: $name: cached, checksums $pins"
    return
  fi
  echo "fetch-exit-data: $name: fetching from $url"
  rm -f "$file"
  gdal_translate -q -of GTiff "$@" -co TILED=YES -co COMPRESS=DEFLATE "/vsicurl/$url" "$file.part"
  local got
  got="$(checksums "$file.part")"
  if [[ "$got" != "$pins" ]]; then
    echo "fetch-exit-data: FAIL: $name checksums $got, pinned $pins: the source's pixels changed" >&2
    rm -f "$file.part"
    exit 1
  fi
  mv "$file.part" "$file"
  echo "fetch-exit-data: $name: checksums $got: ok"
}

fetch naip-window.tif "$NAIP_URL" "$NAIP_CHECKSUMS" -srcwin "${NAIP_SRCWIN[@]}" -b 1 -b 2 -b 3
fetch 3dep-window.tif "$DEM_URL" "$DEM_CHECKSUMS" -srcwin "${DEM_SRCWIN[@]}"

if [[ ! -f "$OUT/sf-naip-2024.tif" || "$OUT/sf-naip-2024.tif" -ot "$OUT/naip-window.tif" ]]; then
  gdal_translate -q -of GTiff -tr 1.2 1.2 -r average -co TILED=YES -co COMPRESS=DEFLATE \
    "$OUT/naip-window.tif" "$OUT/sf-naip-2024.tif.part"
  gdaladdo -q -r average "$OUT/sf-naip-2024.tif.part" 2 4 8 16
  mv "$OUT/sf-naip-2024.tif.part" "$OUT/sf-naip-2024.tif"
fi
if [[ ! -f "$OUT/sf-3dep-13.tif" || "$OUT/sf-3dep-13.tif" -ot "$OUT/3dep-window.tif" ]]; then
  gdal_translate -q -a_srs EPSG:4269+5703 -co TILED=YES -co COMPRESS=DEFLATE \
    "$OUT/3dep-window.tif" "$OUT/sf-3dep-13.tif"
fi
echo "fetch-exit-data: $OUT/sf-naip-2024.tif $OUT/sf-3dep-13.tif"
