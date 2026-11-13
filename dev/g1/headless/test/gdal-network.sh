#!/usr/bin/env bash
#
# G1 security canary (finding 10, issue 147): opening a layer file must not
# make GDAL reach the network.
#
# Two hostile files, each pointing at a loopback listener that records
# every request (http-witness.py):
#   hostile.vrt  an OGR VRT whose SrcDataSource is /vsicurl/http://...
#   hostile.gml  a GML file whose xsi:schemaLocation names a WFS
#                DescribeFeatureType URL (GDAL downloads it by default)
#
# Control: stock ogrinfo, with every driver, opens each file and must make
# the listener see a request, which proves the files are hostile on this
# GDAL. Then atak-headless --layer, the engine's own import path
# (OGR_Content2), opens each file and the listener must see none. The GML
# driver must not have written a .gfs beside the file either.
#
# PASS = the control fetched and the engine did not. Without
# patches/ogr-open-driver-allowlist.patch the engine fetches both.
# Needs: an engine build (dev/g1/build-native.sh), python3, and ogrinfo for
# the control (skipped with a note when it isn't on PATH).
# shellcheck disable=SC2317,SC2329  # invoked via trap (SC2317 on shellcheck < 0.10)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g1/headless/test
CLI="$HERE/../atak-headless"
WORK="$(mktemp -d)"
WITNESS_PID=""
cleanup() {
  [[ -n "$WITNESS_PID" ]] && kill "$WITNESS_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

HITS="$WORK/requests.log"
: > "$HITS"
python3 -I "$HERE/http-witness.py" "$WORK/port" "$HITS" &
WITNESS_PID=$!
for _ in $(seq 1 50); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
[[ -s "$WORK/port" ]] || { echo "[gdal-network] FAIL: the listener did not start"; exit 1; }
PORT="$(tr -d '[:space:]' < "$WORK/port")"
BASE="http://127.0.0.1:$PORT"

# write_hostile DIR — the two files, fresh (no .gfs from an earlier open)
write_hostile() {
  mkdir -p "$1"
  printf '%s\n' "<OGRVRTDataSource><OGRVRTLayer name=\"x\"><SrcDataSource>/vsicurl/$BASE/vrt-source.geojson</SrcDataSource></OGRVRTLayer></OGRVRTDataSource>" \
    > "$1/hostile.vrt"
  cat > "$1/hostile.gml" <<GML
<?xml version="1.0" encoding="utf-8"?>
<wfs:FeatureCollection xmlns:wfs="http://www.opengis.net/wfs" xmlns:gml="http://www.opengis.net/gml"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:x="http://example.com/x"
    xsi:schemaLocation="http://example.com/x $BASE/wfs?SERVICE=WFS&amp;VERSION=1.0.0&amp;REQUEST=DescribeFeatureType&amp;TYPENAME=x:t">
  <gml:featureMember><x:t><x:name>a</x:name></x:t></gml:featureMember>
</wfs:FeatureCollection>
GML
}

requests() { wc -l < "$HITS" | tr -d ' '; }
rc=0

# --- control: stock GDAL fetches -------------------------------------------
if command -v ogrinfo >/dev/null 2>&1; then
  write_hostile "$WORK/control"
  for f in hostile.vrt hostile.gml; do
    before="$(requests)"
    ogrinfo -ro -al -so "$WORK/control/$f" >/dev/null 2>&1 || true
    if [[ "$(requests)" -gt "$before" ]]; then
      echo "[gdal-network] ok   control: ogrinfo $f reached the listener ($(( $(requests) - before )) request(s))"
    else
      echo "[gdal-network] FAIL control: ogrinfo $f made no request, so this run proves nothing"; rc=1
    fi
  done
else
  echo "[gdal-network] (note) ogrinfo not on PATH; control skipped"
fi

# --- the engine's import path must not --------------------------------------
write_hostile "$WORK/engine"
for f in hostile.vrt hostile.gml; do
  before="$(requests)" ec=0
  log="$WORK/$f.log"
  "$CLI" --layer "$WORK/engine/$f" --layer-db "$WORK/db-$f" > "$log" 2>&1 || ec=$?
  if (( ec > 128 )); then
    echo "[gdal-network] FAIL $f: atak-headless died (exit $ec)"; rc=1
    sed 's/^/    /' "$log"
  elif [[ "$(requests)" -gt "$before" ]]; then
    echo "[gdal-network] FAIL $f: opening it reached the network:"; rc=1
    tail -n +"$(( before + 1 ))" "$HITS" | sed 's/^/    /'
  else
    echo "[gdal-network] ok   $f: refused without a request (exit $ec)"
  fi
done
if [[ -e "$WORK/engine/hostile.gfs" ]]; then
  echo "[gdal-network] FAIL hostile.gml: the GML driver wrote hostile.gfs beside it"; rc=1
fi

if [[ "$rc" == 0 ]]; then
  echo "[gdal-network] PASS: layer files open without reaching the network"
else
  echo "[gdal-network] FAIL"
fi
exit "$rc"
