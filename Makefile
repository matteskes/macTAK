.PHONY: help hooks kernel-jars build build-angle angle gdal-java test-gdal-projection gen-gles-shim check-gen-gles-shim check-transplants check-ots-profiles test test-kernel test-jni test-roundtrip test-tls test-quic test-render test-render-resize build-window-host test-render-window smoke-window lint docs-site clean

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
	@echo "  kernel-jars    - build the takkernel jars + JNI headers from src/ (dev/g1/kernel/build-kernel-jars.sh → dev/g1/kernel-dist)"
	@echo "  build          - kernel jars + native + commo (build-kernel-jars.sh, build-native.sh, build-commo.sh)"
	@echo "  angle          - stage ANGLE (EGL/GLES on Metal) into dev/g2/angle-dist (dev/g2/fetch-angle.sh)"
	@echo "  build-angle    - kernel jars + native with ANGLE in the GLES slot (MACTAK_GLES=angle) + commo"
	@echo "  gdal-java      - G2.4b: build the GDAL SWIG Java bindings (org.gdal) against Homebrew libgdal into dev/g2/gdal-java-dist + smoke (dev/g2/fetch-gdal-java.sh)"
	@echo "  test-gdal-projection - G2.4 b.2: the engine's GdalLibrary.init + GdalDatasetProjection2 on GDAL 3 with the axis-order patch (needs build-angle + gdal-java)"
	@echo "  gen-gles-shim  - regenerate the android.opengl GLES shim (Java + JNI + stub) from the transplant jar x gl3.h"
	@echo "  check-gen-gles-shim - regenerate and fail if the committed shim files differ (CI drift gate)"
	@echo "  check-transplants - fail if a committed transplant jar is unlisted in, or differs from, its SHA256SUMS (CI gate)"
	@echo "  check-ots-profiles - fail if OpenTAKServer's upstream cert profiles differ from the copy test-tls pins (needs network; nightly CI)"
	@echo "  test           - run smoke tests (dev/g1/smoke/run.sh)"
	@echo "  test-kernel    - takkernel's own :port and :shared unit tests on Gradle 8.13 (dev/g1/kernel/test-kernel.sh; after kernel-jars)"
	@echo "  test-jni       - G1.9 JNI guard/behavior unit canary on a real desktop JVM: guards mode (class-init bailouts, clean JNI_ERR) + kernel mode (Java-backed IOProviderFactory on real files) (dev/g1/jni-tests/run.sh; skips without a JDK)"
	@echo "  test-roundtrip - run headless round-trip tests (dev/g1/headless/run.sh)"
	@echo "  test-tls       - TLS server-purpose canary: commo accepts server certs, refuses a same-CA client-only impostor (G1.14)"
	@echo "  test-quic      - QUIC canary: commo streams over QUIC (ngtcp2 ossl backend), refuses a client-only impostor, names a failed handshake's cause"
	@echo "  test-render    - G2 render smoke: engine GLGlobe into an EGL pbuffer on ANGLE, bare + GeoJSON layer + MBTiles basemap (dev/g2/render/run.sh)"
	@echo "  test-render-resize - M3.1 dynamic-size exercise: --resize mid-run, bare + GeoJSON layer (surface OnSizeChangedListeners must fire)"
	@echo "  build-window-host - compile the M3.1 window-harness host dylib (WindowHost.m -> build/window-host.dylib)"
	@echo "  test-render-window - M3.1 window-surface exercise: engine into a CAMetalLayer window surface, --resize via the host's drawableSize (off-screen; CI runs it too)"
	@echo "  smoke-window   - G2 M3.0 manual gate: NSWindow -> CAMetalLayer -> eglCreateWindowSurface on ANGLE; opens a window ~3 s, writes dev/g2/build/window-smoke.ppm (needs a GUI session)"
	@echo "  lint           - shellcheck + bash -n over dev/**/*.sh; markdownlint/actionlint if installed"
	@echo "  docs-site      - build the docs site (MkDocs, strict) into dev/docs-site/build/site"
	@echo "  clean          - remove build outputs"

hooks:
	git config core.hooksPath .githooks

kernel-jars:
	bash dev/g1/kernel/build-kernel-jars.sh

build: kernel-jars
	bash dev/g1/build-native.sh && bash dev/g1/build-commo.sh

angle:
	bash dev/g2/fetch-angle.sh && bash dev/g2/smoke/run.sh

build-angle: angle kernel-jars
	MACTAK_GLES=angle bash dev/g1/build-native.sh && bash dev/g1/build-commo.sh

gdal-java:
	bash dev/g2/fetch-gdal-java.sh && bash dev/g2/smoke/run-gdal-java.sh

test-gdal-projection:
	bash dev/g2/render/run-gdal-projection.sh

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

check-transplants:
	@bash dev/check-transplants.sh

check-ots-profiles:
	@python3 dev/check-ots-profiles.py

test:
	bash dev/g1/smoke/run.sh

test-kernel:
	bash dev/g1/kernel/test-kernel.sh

# G1.9: the JNI guard/behavior canary built by `make build`, run against
# the staged dylibs. Boots the desktop JVM twice — guards mode (empty
# classpath: class-init failures must bail neutrally, JNI_OnLoad must fail
# cleanly) and kernel mode (takkernel jars: the Java-backed IOProviderFactory
# proxy on real files). Skips when no JDK 21 is present.
test-jni:
	bash dev/g1/jni-tests/run.sh

test-roundtrip:
	bash dev/g1/headless/run.sh

test-tls:
	@bash dev/g1/headless/test/tls-purpose.sh

test-quic:
	@bash dev/g1/headless/test/quic.sh

test-render:
	bash dev/g2/render/test/gles-shim.sh
	bash dev/g2/render/test/input-bridge.sh
	bash dev/g2/render/run.sh --out dev/g2/build/render-smoke.png
	bash dev/g2/render/test/asset-icons.sh dev/g2/build/render-layer.png
	bash dev/g2/fixtures/make-basemap.sh
	bash dev/g2/render/run.sh --basemap dev/g2/build/fixtures/sf-graticule.mbtiles --layer dev/g1/headless/test/fixtures/sf-landmarks.geojson --out dev/g2/build/render-basemap.png
	bash dev/g2/render/test/basemap-gate.sh

test-render-resize:
	# M3.1: first real caller of NativeEgl.resize — pbuffer rebuild mid-run,
	# gated on the surface's OnSizeChangedListeners; GLMapView reads
	# width/height per frame, so the content-pixel check proves uptake.
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

# M3.2 shell compile (no run): swiftc/clang over dev/g2/shell — what CI can
# do without a GUI session.
build-shell:
	bash dev/g2/shell/run.sh --compile-only

# M3.2 dev-Mac GUI gate: the AppKit shell boots the JVM in-process (libjli →
# JNI_CreateJavaVM), opens an NSWindow over its own CAMetalLayer and upcalls
# WindowApp.start; the render thread lifts the RenderSmoke body, draws
# Globe+layers into the window and parks. The window auto-closes --linger ms
# after the first presented frame; the readback PNG is the artifact.
test-shell: build-shell
	bash dev/g2/shell/run.sh --out dev/g2/build/shell-frame.png
	bash dev/g2/shell/test/exit-code.sh
	bash dev/g2/shell/test/live.sh
	bash dev/g2/shell/test/gestures.sh

# M3.0 manual gate (dev Mac, GUI session): `angle` stages the ANGLE pair and
# runs the headless pbuffer canary first, then the window opens for ~3 s and
# auto-closes, leaving the pre-swap readback as the artifact.
smoke-window: angle
	@mkdir -p dev/g2/build
	MACTAK_SMOKE_PPM=dev/g2/build/window-smoke.ppm bash dev/g2/smoke/run-window.sh

# bash -n + shellcheck over the dev shell tree; markdownlint over the repo's
# own docs ('!src/': the read-only upstream pin isn't held to our rules, and
# CI's docs job lints only PR-changed *.md, so it never sees src either);
# actionlint over the workflows. Optional tools absent on PATH are skipped.
lint:
	@git ls-files -z 'dev/**/*.sh' 'dev/g1/headless/atak-headless' | xargs -0 -n1 bash -n
	@bash dev/check-trap-exec.sh
	@bash dev/check-pipefail-grep.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		git ls-files -z 'dev/**/*.sh' 'dev/g1/headless/atak-headless' | xargs -0 -n1 shellcheck -x; \
	else \
		echo "[lint] skip: shellcheck not installed"; \
	fi
	@if command -v markdownlint-cli2 >/dev/null 2>&1; then \
		markdownlint-cli2 '**/*.md' '!src/**/*.md'; \
	else \
		echo "[lint] skip: markdownlint-cli2 not installed"; \
	fi
	@if command -v actionlint >/dev/null 2>&1; then \
		actionlint; \
	else \
		echo "[lint] skip: actionlint not installed"; \
	fi

docs-site:
	@bash dev/docs-site/build.sh

clean:
	rm -rf dev/g1/native-dist dev/g1/build-commo dev/g1/build-ngtcp2 dev/g1/kernel-dist dev/g1/kernel/build dev/g1/headless/build dev/g2/angle-dist dev/g2/build dev/docs-site/build
