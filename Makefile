.PHONY: help hooks build build-angle angle gen-gles-shim check-gen-gles-shim test test-roundtrip test-render test-render-resize build-window-host test-render-window smoke-window lint clean

# The android.opengl.GLES20/30 runtime is GENERATED (dev/g2/gen-gles-shim.py):
# two Java classes, the JNI bodies and the stub-mode libGLESv2. Edit the
# generator, run `make gen-gles-shim`, commit all five; CI diffs them.
GLES_SHIM_GEN   := dev/g2/gen-gles-shim.py
GLES_SHIM_JAR   := dev/spike/g0/transplants/android-port-3.1.0.jar
GLES_SHIM_GL3H  := src/khronos/OpenGL/api/GLES3/gl3.h
GLES_SHIM_OUT   := dev/g2/render/src/android/opengl/GLES20.java dev/g2/render/src/android/opengl/GLES30.java \
                   dev/g2/jni-extra/mactak_gles.c dev/g2/jni-extra/mactak_gles_stub.c

help:
	@echo "Targets:"
	@echo "  hooks          - install git hooks (git config core.hooksPath .githooks)"
	@echo "  build          - build native + commo (dev/g1/build-native.sh, dev/g1/build-commo.sh)"
	@echo "  angle          - stage ANGLE (EGL/GLES on Metal) into dev/g2/angle-dist (dev/g2/fetch-angle.sh)"
	@echo "  build-angle    - build native with ANGLE in the GLES slot (MACTAK_GLES=angle) + commo"
	@echo "  gen-gles-shim  - regenerate the android.opengl GLES shim (Java + JNI + stub) from the transplant jar x gl3.h"
	@echo "  check-gen-gles-shim - regenerate and fail if the committed shim files differ (CI drift gate)"
	@echo "  test           - run smoke tests (dev/g1/smoke/run.sh)"
	@echo "  test-roundtrip - run headless round-trip tests (dev/g1/headless/run.sh)"
	@echo "  test-render    - G2 render smoke: engine GLGlobe into an EGL pbuffer on ANGLE, bare + GeoJSON layer + MBTiles basemap (dev/g2/render/run.sh)"
	@echo "  test-render-resize - M3.1 dynamic-size exercise: --resize mid-run, bare + GeoJSON layer (OnSizeChangedListener must fire)"
	@echo "  build-window-host - compile the M3.1 window-harness host dylib (WindowHost.m -> build/window-host.dylib)"
	@echo "  test-render-window - M3.1 window-surface exercise: engine into a CAMetalLayer window surface, --resize via the host's drawableSize (off-screen; CI runs it too)"
	@echo "  smoke-window   - G2 M3.0 manual gate: NSWindow -> CAMetalLayer -> eglCreateWindowSurface on ANGLE; opens a window ~3 s, writes dev/g2/build/window-smoke.ppm (needs a GUI session)"
	@echo "  lint           - shellcheck + bash -n over dev/**/*.sh; markdownlint/actionlint if installed"
	@echo "  clean          - remove build outputs"

hooks:
	git config core.hooksPath .githooks

build:
	bash dev/g1/build-native.sh && bash dev/g1/build-commo.sh

angle:
	bash dev/g2/fetch-angle.sh && bash dev/g2/smoke/run.sh

build-angle: angle
	MACTAK_GLES=angle bash dev/g1/build-native.sh && bash dev/g1/build-commo.sh

gen-gles-shim:
	python3 $(GLES_SHIM_GEN) $(GLES_SHIM_JAR) $(GLES_SHIM_GL3H) dev/g2/render/src/android/opengl \
		dev/g2/jni-extra/mactak_gles.c dev/g2/jni-extra/mactak_gles_stub.c

check-gen-gles-shim:
	@tmp=$$(mktemp -d) && \
	python3 $(GLES_SHIM_GEN) $(GLES_SHIM_JAR) $(GLES_SHIM_GL3H) $$tmp/opengl $$tmp/mactak_gles.c $$tmp/mactak_gles_stub.c >/dev/null && \
	ok=1; \
	for f in $(GLES_SHIM_OUT); do \
		diff -u "$$f" "$$tmp/$$(basename $$f)" >/dev/null 2>&1 || diff -u "$$f" "$$tmp/opengl/$$(basename $$f)" >/dev/null 2>&1 \
			|| { echo "[check-gen-gles-shim] DRIFT: $$f differs from generator output"; ok=0; }; \
	done; \
	rm -rf "$$tmp"; \
	[ $$ok = 1 ] && echo "[check-gen-gles-shim] OK: committed shim matches the generator" \
		|| { echo "[check-gen-gles-shim] run 'make gen-gles-shim' and commit the result"; exit 1; }

test:
	bash dev/g1/smoke/run.sh

test-roundtrip:
	bash dev/g1/headless/run.sh

test-render:
	bash dev/g2/render/run.sh --out dev/g2/build/render-smoke.png
	bash dev/g2/render/run.sh --layer dev/g1/headless/test/fixtures/sf-landmarks.geojson --out dev/g2/build/render-layer.png
	bash dev/g2/fixtures/make-basemap.sh
	bash dev/g2/render/run.sh --basemap dev/g2/build/fixtures/sf-graticule.mbtiles --layer dev/g1/headless/test/fixtures/sf-landmarks.geojson --out dev/g2/build/render-basemap.png

test-render-resize:
	# M3.1: first real caller of NativeEgl.resize — pbuffer rebuild mid-run,
	# gated on the size change reaching GLMapView (OnSizeChangedListener).
	bash dev/g2/render/run.sh --resize 384x256 --out dev/g2/build/render-resize.png
	bash dev/g2/render/run.sh --layer dev/g1/headless/test/fixtures/sf-landmarks.geojson \
		--resize 384x256 --out dev/g2/build/render-resize-layer.png

build-window-host:
	bash dev/g2/render/build-window-host.sh

# M3.1 window-surface exercise: the engine renders into a CAMetalLayer
# window surface (a bare layer host — see WindowHost.m for why there is no
# NSWindow); the mid-run resize goes through the host's drawableSize first
# (the host's truth), then ctx.resize() proves EGL tracks it. Off-screen,
# so it needs no GUI session and CI runs it too. The readback PNGs are the
# artifacts.
test-render-window: build-window-host
	bash dev/g2/render/run.sh --window 640x480 --resize 384x256 --frames 6 \
		--out dev/g2/build/render-window.png
	bash dev/g2/render/run.sh --window 640x480 --resize 384x256 \
		--layer dev/g1/headless/test/fixtures/sf-landmarks.geojson \
		--out dev/g2/build/render-window-layer.png

# M3.0 manual gate (dev Mac, GUI session): `angle` stages the ANGLE pair and
# runs the headless pbuffer canary first, then the window opens for ~3 s and
# auto-closes, leaving the pre-swap readback as the artifact.
smoke-window: angle
	@mkdir -p dev/g2/build
	MACTAK_SMOKE_PPM=dev/g2/build/window-smoke.ppm bash dev/g2/smoke/run-window.sh

lint:
	@git ls-files -z 'dev/**/*.sh' | xargs -0 -n1 bash -n
	@if command -v shellcheck >/dev/null 2>&1; then \
		git ls-files -z 'dev/**/*.sh' | xargs -0 -n1 shellcheck; \
	else \
		echo "[lint] skip: shellcheck not installed"; \
	fi
	@if command -v markdownlint-cli2 >/dev/null 2>&1; then \
		markdownlint-cli2 '**/*.md'; \
	else \
		echo "[lint] skip: markdownlint-cli2 not installed"; \
	fi
	@if command -v actionlint >/dev/null 2>&1; then \
		actionlint; \
	else \
		echo "[lint] skip: actionlint not installed"; \
	fi

clean:
	rm -rf dev/g1/native-dist dev/g1/build-commo dev/g1/headless/build dev/g2/angle-dist dev/g2/build
