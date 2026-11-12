#!/usr/bin/env bash
#
# The G2 render gates on the 5.5 build: ci.yml's render-angle steps, run
# by the same scripts, with dev/g2/render/env.sh handing over to
# render-env.sh (JDK 21, the 5.5 jars, shadows from the 5.5 patches, the
# ANGLE-linked 5.5 dylibs). Outputs go to dev/spike/g55/build/render/.
# Not here: dev/g1/headless/test/layer.sh, the headless launcher's canary,
# which waits for the launcher's move off Java 8.
#
# usage: render.sh UPSTREAM_55   (after kernel/build-kernel-jars.sh and
#                                 G55_GLES=angle build-engine.sh)
# exit:  0 every gate green; non-zero the first that failed
set -euo pipefail

G55="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$G55/../../.." && pwd)"
RENDER="$ROOT/dev/g2/render"
LAYER="$ROOT/dev/g1/headless/test/fixtures/sf-landmarks.geojson"
BASEMAP="$ROOT/dev/g2/build/fixtures/sf-graticule.mbtiles"
OUT="$G55/build/render"

[[ $# -eq 1 ]] || { echo "usage: render.sh UPSTREAM_55" >&2; exit 2; }
G55_UPSTREAM="$(cd "$1" && pwd)"
export G55_UPSTREAM
export MACTAK_RENDER_ENV="$G55/render-env.sh"
rm -rf "$OUT/classes"   # render-env.sh recompiles on the first gate

step() { printf '\n[g55-render] %s\n' "$*"; }

# MACTAK_GL_DEBUG=1, as CI: ANGLE names any GL error (KHR_debug)
export MACTAK_GL_DEBUG="${MACTAK_GL_DEBUG:-1}"

step "1/9 engine GDAL georeferencing on GDAL 3 (the regenerated GDAL shadows)"
bash "$RENDER/run-gdal-projection.sh"
step "2/9 GLES shim Buffer contract"
bash "$RENDER/test/gles-shim.sh"
step "3/9 RenderSmoke argument canary"
bash "$RENDER/test/args.sh"
step "4/9 globe smoke"
bash "$RENDER/run.sh" --frames 10 --out "$OUT/render-smoke.png"
step "5/9 vector layer"
bash "$RENDER/run.sh" --layer "$LAYER" --out "$OUT/render-layer.png"
step "6/9 raster basemap + vector layer"
bash "$ROOT/dev/g2/fixtures/make-basemap.sh"
bash "$RENDER/run.sh" --basemap "$BASEMAP" --layer "$LAYER" --out "$OUT/render-basemap.png"
step "7/9 basemap negative canary"
bash "$RENDER/test/basemap-gate.sh"
step "8/9 resize mid-run"
bash "$RENDER/run.sh" --resize 384x256 --out "$OUT/render-resize.png"
bash "$RENDER/run.sh" --layer "$LAYER" --resize 384x256 --out "$OUT/render-resize-layer.png"
step "9/9 window surface (CAMetalLayer, off-screen)"
bash "$RENDER/run.sh" --window 640x480 --resize 384x256 --frames 6 --out "$OUT/render-window.png"
bash "$RENDER/run.sh" --window 640x480 --resize 384x256 --layer "$LAYER" --out "$OUT/render-window-layer.png"

step "PASS: the G2 render gates are green on the 5.5 build"
