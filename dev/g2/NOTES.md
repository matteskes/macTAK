# dev/g2 — G2: map renders in a native macOS window (ANGLE on Metal)

## State (M3.2 — 2026-11-07): the Swift/AppKit shell boots the JVM in-process and hosts the window; `make test-shell` is green

`shell/main.swift` is the host now: it dlopens `libjli`
(`JNI_CreateJavaVM`), builds the ANGLE-on-Metal `NSWindow`/`CAMetalLayer`,
and upcalls `WindowApp.start(layerPtr, …)` — the engine renders into the
shell's own layer on the JVM side while AppKit owns the main thread. The
gate ladder is green end-to-end on the dev Mac: `make lint`, `make
test-render` 3/3 (now compile-if-stale through the shared `render/env.sh`),
`make test-render-window` 2/2, and **`make test-shell` exit 0** — window
opens, 5 frames present, readback PNG written by an AWT-free PNG encoder,
frame-done → 4 s linger → stop → teardown → EXITED → clean exit. CI
compiles the shell (`shell-compile` job); the run stays a dev-Mac gate
(same split as M3.0). Section "M3.2" below.

## State (M3.1 — 2026-11-06): window natives + dynamic-size context, exercised through a real window surface, gated in CI

`RenderSmoke --window W×H` swaps the init pbuffer for a window surface:
`render/WindowHost.m` owns a bare off-screen `CAMetalLayer` (no AppKit
at all — the `java` launcher's main runs on a spawned `pthread`, and
AppKit wants the main thread), `render/WindowHost.java` drives it over
JNI, and `--resize` pushes a mid-run `drawableSize` change through the
host the way a real window resize does. ANGLE-Metal sizes a window
surface once at creation (and refuses a second surface on a live layer,
`EGL_BAD_ALLOC`), so `adoptSurfaceSize` destroy-then-recreates on the
same layer. Two runs gate (`make test-render-window`: bare, and the
GeoJSON + MBTiles stack) — the exercise needs no GUI session, so CI
runs it itself, upgrading M3.0's manual-only gate. Section "M3.1" below.

## State (M3.0 — 2026-11-06): the window surface is proven — `eglCreateWindowSurface` accepts a live `CAMetalLayer`

`make smoke-window` runs the new window smoke
(`dev/g2/smoke/egl-triangle-window.m`): an NSWindow with a layer-backed
`CAMetalLayer` is ordered front, EGL 1.5 (Metal platform) takes it as a
window surface (RGBA8 + D24S8), a GL ES 3.0 clear + triangle draws and
reads back (centre/corner pixel probes, exact-size P6 PPM artifact), and
a 3.0 s present loop runs at ~30 fps — zero GL errors, renderer
"ANGLE (Apple, ANGLE Metal Renderer: <the box's Apple GPU>)". The gate
fails loudly instead of passing silently on every way a window smoke can
lie: unwritable or empty artifact (#39), stale post-teardown diagnostics
(#38), 0 presented frames (#40), a nil Metal device (#42), unknown
flags (#37), and the log claims only the time it actually spent (#41).
Section "M3.0" below.

## State (G2.3 — 2026-11-05): an offline MBTiles basemap renders under the vector layer

`make test-render` now also builds a synthetic graticule basemap
(`fixtures/make-basemap.sh` → `build/fixtures/sf-graticule.mbtiles`, zoom
10–14, EPSG:3857, Homebrew `gdal` CLI) and renders it under the GeoJSON
fixture through the engine's raster pipeline:
`PersistentRasterDataStore` → `MobileImageryRasterLayer2` → `GLQuadTileNode4`
textures on ANGLE. Zero GL errors; every pixel has content; the graticule's
coordinate labels line up with the vector layer's geometry. Section "G2.3"
below.

## State (G2.2 — 2026-11-04): first map content — a GeoJSON FeatureLayer renders through the engine on ANGLE/Metal

`make test-render` now renders `dev/g1/headless/test/fixtures/sf-landmarks.geojson`
into the pbuffer: polygons (Golden Gate Park, Presidio, Alcatraz), the two
bridge LineStrings through the engine's anti-aliased line shader, and point
labels ("Ferry Building") through native `GLLabelManager` → Java2D glyphs.
Zero GL errors. The Java-side engine (`GLBatchGeometryRenderer` et al.) runs
against a **generated `android.opengl.GLES20/GLES30` → ANGLE JNI shim** and
**Java2D-backed `android.graphics`** (`Bitmap`, `Canvas`, `Paint`, `Typeface`,
`BitmapFactory`…). Section "G2.2" below.

## State (G2.1 — 2026-11-04): ANGLE occupies the GLES-stub slot; the engine's native renderer draws through it

The G2 branch point (H2 native/ANGLE vs H1 Swing/JOGL) is **decided for H2**
on evidence, not estimate: `libtakengine` + JNI glue, rebuilt with
`MACTAK_GLES=angle`, link against ANGLE's `libGLESv2` (EGL 1.5, GL ES 3.0,
Metal backend), and `GLMapView.render()` driven from a Zulu 8 JVM renders
frames into an EGL pbuffer with **zero GL errors** at ~3–5 ms/frame (512²,
incl. `glFinish`, no layers). R2 (ANGLE ≠ GLES-stub contract) is retired:
all 80 GL symbols the engine imports resolve against ANGLE's 829 exports;
the three contract issues found were on *our* side (below), not ANGLE's.

```sh
make angle          # stage ANGLE → dev/g2/angle-dist, run EGL triangle smoke
make build-angle    # engine + glue with ANGLE in the GLES slot (+ commo)
make test-render    # GLGlobe → EGL pbuffer → readback: bare, GeoJSON layer, MBTiles basemap, PASS/FAIL
make smoke-window   # window-surface smoke (M3.0): NSWindow → CAMetalLayer → EGL surface → PASS
# one-offs:
bash dev/g2/render/run.sh --layer FILE.geojson --at 37.7955,-122.3937 --res 1 --out /tmp/f.png
bash dev/g2/render/run.sh --basemap FILE.mbtiles --layer FILE.geojson --out /tmp/b.png
```

## What's here

| Path | Role |
|---|---|
| `fetch-angle.sh` | Stages `libEGL.dylib` + `libGLESv2.dylib` (arm64-thinned, `@rpath` install names, ad-hoc re-signed) into `angle-dist/` with `PROVENANCE.txt`. Source: `$MACTAK_ANGLE_SRC`, else an installed Electron app's bundled ANGLE (VS Code by default). Downloads retry through transient release-CDN failures (504s). |
| `smoke/egl-triangle.c` + `smoke/run.sh` | Pure C: Metal-platform display → pbuffer → ES3 context → shader → draw → readback. The "does ANGLE work on this box" gate, independent of the engine. |
| `smoke/egl-triangle-window.m` + `smoke/run-window.sh` | ObjC++ (ARC): NSWindow → `CAMetalLayer` → `eglCreateWindowSurface` → triangle → readback → 3 s present loop. Proves the window-surface claim M3 leans on (M3.0); CI runs it compile-only, the dev Mac runs it live via `make smoke-window`. |
| `jni-extra/mactak_egl.cpp` | `mactak.render.NativeEgl` — EGL context owner inside `libtakenginejni` (dlopen-based so stub-mode builds still link). `MACTAK_GL_DEBUG=1` installs a `GL_KHR_debug` callback; `=2` adds native backtraces for the first errors. |
| `render/src/mactak/render/` | `EglRenderContext` (the `RenderContext`/`RenderSurface` over `NativeEgl`, counterpart of upstream's `JOGLRenderContext`), `RenderSmoke` (the canary). |
| `render/src/com/atakmap/map/EngineLibrary.java` | macOS host bootstrap **shadowing** the engine jar's jre/JOGL one (see trap 4). |
| `render/src/android/{graphics,opengl,os}/` | Runtime implementations of `PointF/Point/Rect/RectF`, `Matrix`, `Environment` — the android-port transplant's bodies are `Stub!` (trap 5). |
| `render/run.sh` | Compiles the above ahead of the engine jar on the classpath and runs the canary. |
| `../g1/patches/glsl-es-version-on-angle.patch` | Engine emitted desktop `#version 330` on `__APPLE_OSX__`; ANGLE is real ES → `#version 300 es` (trap 2). |
| `../g1/patches/terraintile-guard-missing-attribs.patch` | `GLTerrainTile` enabled attrib `-1` for shader variants without normals/nodata/ecef → `GL_INVALID_VALUE` every frame (trap 3). |
| `../g1/patches/megatexture-release-erase-while-iterating.patch` | `GLMegaTexture::release()/clear()` erased map nodes through the iterator they were walking → SIGSEGV on `GLMapView.release()` (trap 10). |
| `../g1/patches/megatexture-sharetile-comma-operator.patch` | `GLMegaTexture::shareTile` wrote `other,shareWith = this;` (comma operator → `this->shareWith = this`) → every later share returned `TE_IllegalState`. `shareTile` has no callers at the pin; fixed so a future caller gets working sharing. |

`dev/g1/build-native.sh` grew `MACTAK_GLES=stub|angle` (default `stub`; CI
has no ANGLE). In `angle` mode the engine links `angle-dist/libGLESv2.dylib`
by path, gets `@loader_path` in its rpath, and `native-dist/` receives
`libEGL.dylib` + `libGLESv2.dylib` as siblings.

## Design decisions

- **ANGLE source for the spike = Electron's bundle.** Every Electron app
  ships upstream ANGLE (BSD-3) with the Metal backend; it is universal,
  hardened-runtime-signed, and dlopens its own `libGLESv2` from its directory.
  Provenance (app, Chrome/Electron version, sha256) is recorded per stage.
  The port builds ANGLE from source (gn/ninja, pinned commit) at G5 — a
  `make angle` consumer never notices. `MACTAK_ANGLE_SRC=dir` already takes
  a self-built pair.
- **EGL lives in the JNI glue, not the engine.** Upstream's engine C++ never
  touches EGL (0 references outside Android); context creation is the host's
  job. `mactak_egl.cpp` is that host piece, so `libtakengine` stays identical
  between stub and ANGLE modes except for which `libGLESv2` it binds.
- **Pbuffer first, window second.** The exit criterion for G2 is a window,
  but the risk was the engine↔ANGLE contract. A pbuffer isolates it; G2.2
  swaps the surface for a `CAMetalLayer`-backed window surface
  (`eglCreateWindowSurface` on a CALayer is supported by ANGLE's Metal
  backend) — the EGL/GL side above it does not change.
- **M3 host = Swift/AppKit shell + `libjli`, not a window in the JNI glue
  (2026-11-05).** The shell is written once at M3 and becomes G3's
  starting point; writing the window into the glue instead saves ~2–3 days
  now but costs the same window work again at G3, under pressure, and it
  dodges no risk — both variants share the AppKit-main + Java-render
  thread topology. The JVM-first variant is the documented fallback with
  trigger conditions: see "M3 design — window surface and host model"
  below.
- **Shadow classes over a forked jar.** The engine jar is a pinned,
  checksummed transplant; putting `com.atakmap.map.EngineLibrary` and the
  `android.*` runtime types ahead of it on the classpath keeps the jar
  byte-identical and makes the macOS-host delta auditable (one directory).
  The proper fix is an engine built with a `macos` host source set instead
  of `jre`; tracked as a follow-up.

## Traps found on the way (do not rediscover these)

1. **The G0 GLES stub was silently stubbing libxml2.** `stub.c` carried 11
   `xml*` no-ops (`xmlReaderForFile`, `xmlTextReaderRead`, …) harvested
   from the first failing link — so `KMLDriverDefinition2::getStyle` has
   been a no-op in every G0/G1 build. Replacing the stub with ANGLE made the
   link fail honestly. Fix: link `/opt/homebrew/opt/libxml2/lib/libxml2.dylib`
   by full path (same runtime libgdal already loads), stubs removed, formula
   added to preflight + CI. Lesson: a symbol-harvested stub hides *every*
   missing dependency, not just the one you meant.
2. **`#version 330` on macOS.** `renderer/GL.h` picks desktop GLSL under
   `__APPLE_OSX__` (set by `port/Platform.h` for any non-iOS Apple build),
   assuming a desktop-GL-backed shim. ANGLE is real ES 3.0 and rejects it
   (`invalid version directive`, `'in' … GLSL ES 3.00 and above only`).
   Patch gates the desktop string behind `TE_GLSL_DESKTOP` (kept for an H1
   host). Symptom: every native shader program fails to compile, frames
   render only the clear.
3. **`glEnableVertexAttribArray(-1)` every frame.** `GLTerrainTile_begin/
   _end` enable/disable `aNormals`, `aNoDataFlag`, `aEcefVertCoords`
   unconditionally; the color shader variant lacks them so
   `glGetAttribLocation` returns `-1` → `GL_INVALID_VALUE` ×6 per frame.
   Android GLES drivers are lax; ANGLE validates. Patch guards on `>= 0`.
   Found via `MACTAK_GL_DEBUG=2` (KHR_debug + backtrace) in minutes — keep
   that switch.
4. **`EngineLibrary.initialize()` is the jre/JOGL host and it runs from
   `Globe.<clinit>`.** It (a) references `BouncyCastleProvider`
   (NoClassDefFoundError — `bcprov-jdk15on:1.67` now fetched sha256-pinned
   by `render/run.sh`), (b) tries to unpack natives through the android-port
   `Context` (throws, caught), and (c) its last statement registers a JOGL
   hook whose anonymous class references `javax.media.opengl.GL`
   (NoClassDefFoundError, *not* caught). Shadowed with a macOS version that
   keeps the `ConfigOptions` platform defaults and nothing else.
5. **android-port transplant bodies throw `Stub!` at runtime** (known from
   G0 — compile-time only). The render path hits `PointF`, `RectF`,
   `Matrix.setIdentityM`, `Environment.getExternalStorageDirectory`
   (`FileSystemUtils.<clinit>`). Re-implemented from the public API
   contract under `render/src/android/`. `Bitmap`/`Canvas`/`Paint`/
   `Typeface` (48/9/4/5 import sites) are *not* yet needed — no layers, no
   text — and will be the G2.2/G3 item (CoreGraphics-backed).
6. **`GLSLUtil.loadShaderSource` resolves Android raw resources.** The jar
   carries them at `resources/raw/*`; the macOS `EngineLibrary` unpacks that
   prefix to a temp dir and sets
   `glslutil.additional-shader-source-paths`. Handing it the stub `Context`
   instead NPEs in `Resources`.
7. **`EGL_DEFAULT_DISPLAY` + `eglGetPlatformDisplayEXT`**: the pinned Khronos
   header's macro is `EGL_CAST(EGLNativeDisplayType, 0)` → clang
   `-Wnon-literal-null-conversion` for the `void*` parameter; cast
   explicitly. The pinned `eglext.h` also predates
   `EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE` (0x3489) — defined locally.
8. **`strings | grep -m1` under `pipefail`** → SIGPIPE false failure (G1
   trap 2 again, different pipeline). `awk … {print; exit}`-style instead.
   **Guard (2026-11-11):** `dev/check-pipefail-grep.sh`, as G1 trap 2.
9. **ANGLE's `libEGL` is a thin loader**: it `dlopen`s `libGLESv2` from its
   own directory, so the pair must be staged side by side. `install_name_tool`
   invalidates Electron's signature — ad-hoc re-sign or dyld refuses to load.
10. **`GLMegaTexture::release()` is a use-after-free in upstream.** Both it
    and `clear()` loop `for (it = tiles.begin(); …; it++) releaseTile(it->first)`
    and `releaseTile` does `tiles.erase(entry)` — `it++` then reads a freed
    `std::map` node. Harmless whenever the allocator leaves the node intact
    (every local run), SIGSEGV in `GLMegaTexture::release()+0xb8` on the
    first `macos-26` CI run (Apple Paravirtual GPU, different alloc/free
    pattern) — *after* the smoke had already printed PASS-worthy numbers.
    Patch snapshots the keys before releasing.

## Known-benign noise

- `EGM96 file is not configured` on exit — geoid lookups unused by the smoke.
- `GdalGraphicUtils.cpp:1205 -Wmismatched-new-delete` — upstream, pre-existing.
- `[NativeFeatureDataStore2] leaked` in the layer canary — pre-existing (G1.3).

## Follow-ups (G2.2+) — planning status after G2.3 (2026-11-05)

M1–M2.3 are landed: ANGLE in the GLES slot (PR #17, `90aa443`), a GeoJSON
layer and an offline MBTiles basemap rendering beneath it (PR #18,
`71fcbce`), CI green on both; review follow-ups (issue #19) are landed in
PR #21 — shim drift gate, cache eviction on `glDeleteProgram`, debug-path
`FindClass` checks. The next gate is **M3, the window surface**; the rest
is ordered roughly by when it bites.

- **Window surface (M3 — next).** `CAMetalLayer` in an `NSView` →
  `eglCreateWindowSurface`; AppKit main thread vs JVM render thread (R4)
  decided here. Host **decided 2026-11-05**: the Swift/AppKit shell
  launching the JVM in-process via `libjli` (`JNI_CreateJavaVM`) — the
  gate list, thread topology, and the JVM-first fallback with its trigger
  conditions are in "M3 design — window surface and host model (decided
  2026-11-05)" below. The EGL/GL stack above the surface does not change
  (see "Pbuffer first, window second" above).
- **Real imagery (G2.4) pulls two engine patches** — a latent upstream
  bug not yet exercised by the synthetic fixture, plus the native line
  renderer's integer attributes (a third, `shareTile`, is done — below):
  - ~~`GLMegaTexture::shareTile` comma operator~~ — **fixed 2026-11-06**
    (`../g1/patches/megatexture-sharetile-comma-operator.patch`):
    `other,shareWith = this;` set `this->shareWith = this`, never
    `other.shareWith`, so every share after the first returned
    `TE_IllegalState`. Correction to the earlier note here: `shareTile`
    has **no callers** at the pin (engine C++, JNI glue, ATAK Java) —
    `GLGlobeSurfaceRenderer`'s front/back swap uses `transferTile`, so
    real imagery never reaches it and G2.4 is not gated on it. Clang
    `-Wcomma` flags the pristine TU and is clean after the patch; the
    stub-GLES canary cannot exercise it (`bindTile` needs a complete FBO).
  - ~~`GLQuadTileNode4.resolveTexture` composites child textures with
    `uColor` set on whatever program happens to be current~~ — **fixed
    2026-11-07** (`../g1/patches/quadtilenode4-resolvetexture-program-bind.patch`,
    delivered as an engine shadow; see "G2.4a" below). Android drivers
    hid it; ANGLE reported it as `GL_INVALID_OPERATION` once per composite.
  - `GLBatchGeometryRenderer3/4` feed `in int` attributes through
    `glVertexAttribPointer` (trap 12's pattern, already redirected in the
    shim) — patch when the native line renderer is on the path.
  Real imagery also re-opens trap 17 (the `org.gdal` JNI for
  `GdalTileReader` once a GeoTIFF raster is on the path) — **b.0 done
  2026-11-08**: `make gdal-java` builds the bindings against Homebrew's
  libgdal and the smoke proves load + GTiff round-trip; it also answered
  the GDAL 3 axis-order question before any render depended on it (trap
  #48, "G2.4b" below).
- **Shim/tooling debt (issue #19):** landed in PR #21 — a `make
  gen-gles-shim` target plus a `make check-gen-gles-shim` CI drift gate so
  the four GENERATED artifacts can't drift from the generator; cache
  eviction on `glDeleteProgram` (GL reuses program ids; note programs
  created and deleted by native engine code bypass the shim — they only
  enter the cache if a Java GL call runs while one is current, which none
  does today); `FindClass` null-checks in the two debug paths
  (`attribMinusOne`, `mactak_egl.cpp` KHR_debug). Still open:
  `RenderSmoke.countNonClear`'s r,g,b < 8 black threshold vs. a future
  dark basemap (the graticule fixture cannot trip it) — switch to a
  sentinel-vs-cleared comparison or a luminance histogram when the first
  dark imagery lands. (`--settle`'s 3000 ms wall-clock margin did race the
  async layer query once hosted runners slowed — 2026-11-05: the layer smoke
  failed with content=0 on a ~520 ms/frame rerun and on a milliseconds-per-frame
  PR run alike; the smoke now polls the readback and keeps rendering until
  content appears, capped at 5× settle / min 15 s.)
- **CI ops — hosted macOS runners (2026-11-05):** pool contention
  queued jobs up to ~16 min. Queued is *waiting*, not stuck — GitHub
  neither fails nor cancels a job for queue time. The day's two
  cancellation events (one queued job; later both remaining queued
  jobs, killed in one instant) match a manual run-level cancel, and
  `gh run rerun <id> --failed` recovered each time — rerun jobs got
  runners immediately and passed. Leave queued jobs alone.
- ~~First pixels with content~~ — done, G2.2 below. ~~Still open: a
  **basemap**~~ — done, G2.3 below (MBTiles raster fixture generated
  offline by the gdal CLI).
- Render goldens in CI (`ci-qa.md` tier 2): the pbuffer path is exactly the
  offscreen harness that plan assumed, and hosted `macos-26` already runs
  it on ANGLE/Metal (Apple Paravirtual device, ~170 ms/frame vs ~3–5 ms on
  an M-series — budget frame counts accordingly). CI uploads the frames as
  artifacts today; a pixel-level golden diff is still open. A self-hosted
  runner is only needed for speed, not for GL.
- Engine jar for a `macos` host source set (retire the shadow classes).
- Build ANGLE from source at a pinned commit (retire the Electron source;
  roadmap has this at G5).

## G2.2 — first map content: a GeoJSON FeatureLayer through the engine on ANGLE

`dev/g2/render/run.sh --layer FILE` opens the file through the G1.3 feature
stack (`LayerStore` → `PersistentDataSourceFeatureDataStore2`), wraps it in
`FeatureLayer3` (via `Adapters.adapt`), adds it to the `Globe`, frames the
camera on the store's bounds (`GLMapView.lookAt`) and renders until the
asynchronous layer query has settled. PASS = zero GL errors **and**
non-clear pixels. The default fixture gives Golden Gate Park / Presidio /
Alcatraz polygons, the two bridges as anti-aliased lines, and a labelled
point ("Ferry Building") drawn by native `GLLabelManager` through Java2D
glyph rendering.

### What's new

| Path | Role |
|---|---|
| `gen-gles-shim.py` → `render/src/android/opengl/GLES20\|GLES30.java` + `jni-extra/mactak_gles.c` | **Generated** runtime for `android.opengl.GLES20/30`: 342 JNI bodies forwarding to the linked `libGLESv2`, derived from `javap` of the transplant jar (API surface) × `gl3.h` prototypes (C types). Android `Buffer` semantics (direct or array-backed, `position`-relative), `(array, offset)` pairs, String in/out. 11 unused shapes are `UnsupportedOperationException` stubs — loud, not silent. Regenerate with `make gen-gles-shim`; `make check-gen-gles-shim` (run by the `render-angle` CI job) fails on drift between generator and committed output. |
| `render/src/android/graphics/*` | Java2D-backed `Bitmap` (`BufferedImage TYPE_INT_ARGB`), `BitmapFactory`/`BitmapRegionDecoder` (ImageIO), `Canvas`, `Paint`, `Typeface`, `Color`, `Matrix` — exactly the 116 members the engine jar's bytecode references (extracted with `javap -c`). |
| `render/src/android/opengl/GLUtils.java` | `texImage2D/texSubImage2D(Bitmap)` → RGBA8 upload through the shim. |
| `render/src/android/util/{Pair,LruCache}.java` | Native `JNIPair_create` calls `Pair.create`; `FeatureStyleParser` uses `LruCache` (the G1.3 "Stub!" trap, now gone). |
| `render/src/com/atakmap/map/AtakMapView.java` | Shadows the jar's jre stand-in: `getDefaultTextFormat()` returns `GLRenderGlobals`' default instead of throwing (point labels call it). |
| `EglRenderContext extends GLMapSurface` | `GLMapView.getSurface()` casts the context to the abstract `GLMapSurface`; the async layer renderers call it. |
| `../g1/patches/jni-renderable-draw-clears-exception.patch` | `ManagedGLMapRenderable2::draw` now reports + clears a Java exception thrown by a layer's `draw()` (trap 13). |
| `LayerStore.dataStore()/bounds()` (G1.3) | For the layer + camera framing. |

### Design decisions

- **Generate the GLES binding, don't hand-write it.** The Android surface is
  353 methods; the generator maps each to its C prototype by name, collapsing
  `(T[] arr, int offset)` and `java.nio.Buffer` to one pointer and treating a
  Java `int` where C wants a pointer as a buffer offset. Three shim-level
  behaviours encode what Android drivers do and ANGLE/Metal does not: skip
  attribute index `-1` (inactive attribute; `MACTAK_GL_DEBUG` dumps the Java
  call site once), route integer-typed shader attributes through
  `glVertexAttribIPointer`, and hand Metal the **signed** twin type for
  signed `int` attributes fed with unsigned data (trap 12).
- **Java2D, not CoreGraphics, for `android.graphics`.** The JDK ships a
  complete headless 2D stack (fonts, antialiasing, ImageIO); upstream's own
  desktop android-port takes the same route. CoreGraphics is the window-era
  option if text quality or performance demands it.
- **`EngineLibrary.initialize()` is called first, explicitly.** See trap 11
  — nesting it inside native class-init deadlocks.

### Traps found on the way (continuing G2 numbering, traps 11–15)

1. **`ATAKMapEngineJNI_findClass` self-deadlock.** It holds a non-recursive
   mutex while `FindClass` runs Java `<clinit>`s. `GLLayerFactory.register`
   → `NativeGLLayerSpi2.wrap` → `Interop_class_init` → `findClass` →
   `GLMapView.<clinit>` → `EngineLibrary.initialize` → `GLText.<clinit>` →
   `setTextFormatFactory` (native) → `findClass` again → hang in
   `PThreadsMutexImpl::lock` (found with `sample`, not `jstack` — the Java
   side only shows RUNNABLE in a native method). Fix: the host calls
   `EngineLibrary.initialize()` before any interop.
2. **Metal is strict about integer vertex attributes.** `in int a_factor`
   fed via `glVertexAttribPointer(GL_UNSIGNED_BYTE)` → ANGLE:
   `CreateRenderPipelineState … Vertex attribute _ua_factor(7) of type int
   cannot be read using MTLAttributeFormatUChar4`, the whole line pipeline
   fails, GL_INVALID_OPERATION every frame. Needs `glVertexAttribIPointer`
   **and** a signed format for a signed `int`. The Java engine renderer
   does this in 3 places (fixed in the shim); the native
   `GLBatchGeometryRenderer3/4` have the same pattern (`a_pattern`,
   `a_factor`) — not on our path yet, patch when it is.
3. **A pending Java exception poisons the rest of the native frame.**
   `ManagedGLMapRenderable2::draw` called Java `draw()` without checking
   for an exception; one layer threw (trap 14), the exception stayed
   pending, every later JNI call in the frame returned `TE_Err`
   (`ExceptionCheck()` true) — including the text-format factory — so
   `GLText2_intern` returned null and `GLLabelManager::draw` dereferenced it
   (`SIGSEGV GLText2::getTextFormat()+0x0`). The crash site was three
   layers away from the cause. Patched: describe + clear after the call.
4. **`AtakMapView.getDefaultTextFormat()` throws in the jar's jre class**
   (`UnsupportedOperationException`); `GLBatchPoint$LabelState` calls it
   for every labelled point. Shadowed.
5. **`Layers.registerAll()` is the host's job.** Without it
   `GLLayerFactory.create4` returns null and a `FeatureLayer3` is silently
   never rendered — the frame stays black with no error anywhere. (ATAK's
   `MapView` does it in its constructor.)

### Known-benign noise

- `[Unsafe]: Unsafe.allocateDirect lifetime management not supported` —
  the JVM `Unsafe` falls back to plain `allocateDirect`; harmless here.

## G2.3 — an offline raster basemap under the vector layer

`dev/g2/render/run.sh --basemap FILE.mbtiles` registers the dataset through
`DatasetDescriptorFactory2` (`TilesetLayerInfoSpi`), adds the file to a
`PersistentRasterDataStore` under the scratch layer DB, wraps the store in a
`MobileImageryRasterLayer2` and adds it to the `Globe` *before* the feature
layer. The fixture is deterministic and offline: `fixtures/MakeBasemap.java`
paints a 0.01° checker with a graticule and coordinate labels as a PNG +
`.pgw` world file; `fixtures/make-basemap.sh` warps it to EPSG:3857, writes
MBTiles (PNG tiles) and builds overviews — 372 KB, zoom 10–14 over San
Francisco. No network, no third-party imagery licence.

### What's new

| Path | Role |
|---|---|
| `fixtures/MakeBasemap.java`, `fixtures/make-basemap.sh` | Synthetic basemap → `build/fixtures/sf-graticule.mbtiles` (`gdalwarp` → `gdal_translate -of MBTILES` → `gdaladdo`). |
| `RenderSmoke --basemap FILE` (repeatable) | Raster layer path above; prints the dataset's type/provider/resolution/coverage as the store sees it. |
| `render/src/android/net/Uri.java` | `IOProviderFactory.createDatabase` goes through `Uri.fromFile` (trap 16). |
| `render/src/android/os/SystemClock.java` | `elapsedRealtime()` is a native in the transplant (trap 18). |
| `render/src/gov/tak/platform/commons/opengl/GLES20\|GLES30.java` | Shadow the port jar's JOGL-delegating classes with subclasses of the generated `android.opengl` shim (trap 19). |
| `gen-gles-shim.py`: `uniformIsUnsigned` | `glUniform1ui` on a non-`uint` uniform is redirected to `glUniform1i` (trap 20). |
| `jni-extra/mactak_egl.cpp` | `MACTAK_GL_DEBUG=2` now dumps the **Java** stack next to the native backtrace — attributes a GL error to the engine call site in one run. |

### Traps found on the way (traps 16–23)

1. **`android.net.Uri` is `Stub!`** and `IOProviderFactory.createDatabase`
   → `Uri.fromFile` runs on the first raster-store open. Re-implemented
   (`parse/fromFile/getScheme/getPath/getHost/getQueryParameter/
   getFragment/decode/Builder`).
2. **`GdalTileReader.SPI` probes every URI** and the jar's `GdalTileReader`
   binds the `org.gdal` Java bindings, which the transplant doesn't ship →
   `UnsatisfiedLinkError` from inside the SPI chain for *any* dataset.
   `Layers.registerAll()` registers it; the host unregisters it right after
   (`TileReaderFactory.unregisterSpi(GdalTileReader.SPI)`). The engine's own
   native GDAL (`NativeGdal`) is unaffected. Revisit when a GDAL-backed
   raster (GeoTIFF) is on the path — that needs the `org.gdal` JNI, not a
   shim.
3. **`SystemClock.elapsedRealtime()` is a native method in the transplant**
   (`UnsatisfiedLinkError`, not `Stub!`). Shadowed with `System.nanoTime()`.
4. **`gov.tak.platform.commons.opengl.GLES20/30` in the port jar delegate to
   JOGL** (`javax.media.opengl.GL`) → `NoClassDefFoundError` the first time
   the raster renderer touches them (`GLQuadTileNode4` uses that package,
   the feature renderer uses `android.opengl`). Shadowed as
   `extends android.opengl.GLES20/30 implements GLES20Constants/…`.
5. **`glUniform1ui` on a sampler/int uniform** — `GLQuadTileNode4` sets
   `uTexture` with the unsigned variant; Android drivers accept it, ANGLE
   raises `GL_INVALID_OPERATION` and the texture unit stays unset (black
   tiles). The shim queries the active uniform type once per program and
   routes non-`uint` uniforms to `glUniform1i`.
6. **`gdalwarp` needs `-s_srs` for a PNG + world file.** The PNG driver
   ignores a sidecar `.prj`; without `-s_srs EPSG:4326` the warp has no
   source CRS and the MBTiles driver fails later with the misleading
   `Could not find an appropriate zoom level` (there is no `ZOOM_LEVEL`
   creation option to "fix" it with).
7. **The G0 GLES stub only covered what the *engine* linked** (80 symbols,
   harvested from a failing link). The generated JNI shim references 240
   `gl*` entry points, so every `MACTAK_GLES=stub` build — i.e. the two CI
   jobs that don't stage ANGLE — failed at `libtakenginejni` link while
   `render-angle` stayed green. `gen-gles-shim.py` now also emits
   `jni-extra/mactak_gles_stub.c`, a typed no-op for all 246 `gl3.h`
   prototypes; `build-native.sh` compiles that as the stub slot.
8. **A mid-transfer drop kills the ANGLE staging download.** `curl` exit
   56 (a release-CDN 504, 2026-11-05) is outside `curl`'s default
   transient-error set, so a plain `curl -fsSL` fails a green CI build
   on a retryable blip. `fetch-angle.sh` now downloads with
   `--retry 5 --retry-delay 5 --retry-all-errors --retry-max-time 600`;
   the zip's SHA256 pin is untouched (verified before the swap).

### Known-benign noise

- `[GLQuadTileNode4]: asynchronous read error` with **no stack trace** —
  `MBTilesTileReader.getTileImpl` returns `ReadResult.ERROR` (throwable
  `null`) when a requested tile is simply absent from the sparse pyramid
  (edges of the fixture). Not a decode or I/O failure; a real one logs
  `[MBTilesTileReader]: error` with a trace first.
- ~~KHR_debug `glUniform4f: Uniform size does not match uniform method`,
  once per composited tile, from `GLQuadTileNode4.resolveTexture`~~ —
  **fixed 2026-11-07 (G2.4a, below)**. For the record: that path runs from
  a queued render-thread event, never called `glUseProgram`, and set
  `core.shader.uColor` on **whatever program happened to be current** — a
  latent upstream bug Android drivers don't report. The composite is
  discarded as soon as the tile's own read lands, so the picture was
  unaffected; it also happened outside `view.render()`, which is why the
  frame-loop `glGetError` count stayed 0.

## M3 design — window surface and host model (decided 2026-11-05)

Design exploration before implementation; no code yet. The gate renders the
G2.3 map (GeoJSON + MBTiles graticule) into a resizable native macOS window
with live pan/zoom/rotate — G2's exit criterion — and settles R4 (AppKit
main thread vs JVM render thread) on evidence.

### The contract M3 must satisfy

The surface contract is deliberately small, which is why "pbuffer first,
window second" works:

- `RenderSurface` (`gov/tak/api/engine/map/RenderSurface.java`):
  `getDpi/getWidth/getHeight` + `OnSizeChangedListener` add/remove —
  nothing else. The engine never learns what kind of surface it is.
- `RenderContext`: `attach/detach` (make-current), `queueEvent` (marshal to
  the render thread), `requestRefresh`, `setFrameRate`,
  `setContinuousRenderEnabled` — currently stubs or pump-driven in
  `EglRenderContext`; M3 makes them real.
- `GLMapView.getSurface()` casts the context to `GLMapSurface`, so our
  context must keep extending that jar class (shadow-class pattern; jar
  stays byte-identical).

Everything above the surface (Globe → GLMapView → generated GLES shim →
JNI) is untouched.

### Host model — decided: the Swift/AppKit shell + `libjli` ("A")

| | A — Swift shell + `libjli` (chosen) | B — JVM-first, window in the glue |
|---|---|---|
| Process | Swift binary dlopens `libjli`, `JNI_CreateJavaVM` (classpath handed in by the run script), creates the window, JNI-upcalls `WindowApp.start` | keep the `java` launcher; an ObjC++ TU (`mactak_window.mm`) in the glue creates NSWindow/`CAMetalLayer` and runs `NSApp` on the process main thread |
| Cost now | ~2–3 days more (bootstrap ~1 d, SwiftPM/Makefile/CI ~½ d, upcall debug ~½–1 d) | ~2–3 days less to first pixels |
| Cost through G3 | Swift window code written once; carries forward as G3's starting point | ObjC++ window code (~1–1.5 d) is throwaway — deleted at G3 when the Swift shell is written there (~2–3 d, under G3 pressure alongside the real native-UI work) |
| Threading / R4 | AppKit main + Java render thread | identical topology — B dodges nothing |
| Shutdown | shell owns both lifecycles; teardown trivial | JVM owned by the `java` launcher, AppKit a guest inside it — the gnarly bit (cf. embedded-SWT macOS) |

B is a time-shift, not a risk reduction: total window-code effort is
~3–4.5 days split across two gates vs ~2–3 days once for A, and the
riskiest new learning (the `libjli` bootstrap) moves to the calmest
possible context instead of mid-G3. Verified on this box (2026-11-05):
Zulu 8 arm64 keeps `libjli.dylib` at the JDK 8 layout
(`zulu-8.jdk/Contents/Home/jre/lib/jli/libjli.dylib`, copy at
`Contents/MacOS/libjli.dylib`); the bootstrap probes both that and the 9+
layout (`lib/libjli.dylib`) via `/usr/libexec/java_home -v 1.8`; Swift
6.4.2/arm64 present.

### Architecture (committed)

- **One process.** AppKit main thread owns the window and events and never
  touches EGL. A Java render thread owns the EGL context end-to-end
  (contexts are single-thread-bound; same as today) and runs
  `pump() → view.render() → swap()`.
- **Marshal point:** AppKit events and UI-side calls go through the
  existing `queueEvent`/`pump`; the engine's async layer renderers already
  assume it.
- **Vsync:** throttled `eglSwapBuffers` first (ANGLE-on-Metal presents via
  `CAMetalLayer`, which paces at display cadence). `CVDisplayLink` only if
  pacing measurably drifts — it costs a JNI-attach-per-callback thread.
- **JNI boundary:** the `CAMetalLayer*` crosses as an opaque `jlong`; Java
  never dereferences it. Gestures are interpreted JVM-side
  (`InputBridge`) so the Swift shell stays thin;
  `CameraController.Interactive.panBy/zoomBy/rotateBy/tiltBy` are the
  engine's own gesture entry points.
- **Calibration:** `getWidth/getHeight` are pixels
  (`CAMetalLayer.drawableSize` = point size × backing scale); `getDpi()` =
  72 × backingScale (Android feeds ~160×density). One visual check on
  label sizing, not guesswork.
- **Natives:** `mactak_egl.cpp` grows `createWindowSurface(void* layer, w,
  h, dpi)`, `resize(w, h)`, `swap()`; `NativeEgl.java` the matching three.
  `EglRenderContext` goes dynamic: fires `OnSizeChangedListener` (GLMapView
  listens and fixes its own viewport), `requestRefresh` → atomic dirty
  flag, `setFrameRate` clamps the loop.

### De-risk sequence — cheapest proof first

| Step | What | Exit gate |
|---|---|---|
| M3.0 (~1 d) | `smoke/egl-triangle-window.m`: NSWindow → `CAMetalLayer` → `eglCreateWindowSurface` → visible triangle, on the staged Electron-bundled ANGLE pair | verifies the one upstream-true-but-unproven claim before any shell exists |
| M3.1 | window natives + dynamic-size `EglRenderContext` (exercised headlessly; pbuffer still in CI) | pbuffer canary stays green |
| M3.2 | shell + static frame (`WindowApp.java` lifts Globe/layers setup from `RenderSmoke`) | static frame on screen; readback PNG passes |
| M3.3 | loop + live resize + Retina (occlusion pauses the loop) | resize during pan without glitches; 60 fps logged |
| M3.4 | `InputBridge` gestures (drag→panBy, scroll/pinch→zoomBy with focus point, two-finger rotate→rotateBy); fps log; **R4 verdict recorded here and in the roadmap** | gesture-driven pan/zoom/rotate at 60 fps — G2's exit criterion |

CI: the pbuffer canary stays the automated gate; a compile-only job keeps
the Swift from rotting; the window gate is manual on the dev Mac with the
readback PNG as its artifact.

### Fallbacks, with triggers

**F1 — IOSurface client-buffer path (within A). Trigger: M3.0 red after
~a day.** If the staged ANGLE pair refuses `eglCreateWindowSurface` on a
`CAMetalLayer`, render into an IOSurface-backed texture and display it
through the layer via `EGL_ANGLE_metal_texture_client_buffer` — Chromium's
own macOS architecture (it does not use the window-surface path),
production-proven but more moving parts (IOSurface lifecycle, texture
bridge, explicit frame pacing).

**F2 — option B, JVM-first. Trigger: the `libjli` bootstrap or the shell
upcalls go red after ~a day of trying.** Keep the `java` launcher;
`mactak_window.mm` in `jni-extra/` creates the NSWindow/`CAMetalLayer`;
`NSApp` runs on the process main thread (which is Java's main — no AWT, so
no `-XstartOnFirstThread` entanglement); the render loop runs on a spawned
Java thread exactly as in A; ObjC++ event handlers upcall JNI into
`InputBridge` (attached-thread upcalls from AppKit are fine). The fiddly
part is teardown: the JVM is owned by the `java` launcher, so window close
must route NSApp termination into a clean engine/EGL shutdown and then
`System.exit` without fighting either runtime. Steps mirror M3.0–M3.4 with
M3.2 swapped for "window TU + static frame" (`run.sh` reused wholesale).
The window code is throwaway, deleted at G3. SWT-on-macOS is the
existence proof that B works — and its famously gnarly lifecycle code is
what A avoids by making the shell own both lifecycles. F2 gains ~2 days to
first pixels and nothing else.

### Out of scope (unchanged)

AWT stays out (`java.awt.headless=true` remains); the split-process design
stays shelved unless F1 *and* F2 both go red; G2.4 (real imagery, two
engine patches) is the next milestone after M3 and separate.

## M3.0 — the window-surface smoke (2026-11-06, #36)

The M3 design's first de-risk step, executed: the one
upstream-true-but-unproven claim — ANGLE's Metal backend accepts
`eglCreateWindowSurface` on a live `CAMetalLayer` — is proven on this
box. F1's trigger ("M3.0 red after ~a day") never fired; the IOSurface
client-buffer fallback stays shelved.

```sh
make smoke-window                    # fetch-angle → pbuffer triangle → window smoke → PASS
MACTAK_SMOKE_PPM=f.ppm bash dev/g2/smoke/run-window.sh  # artifact path (make sets dev/g2/build/window-smoke.ppm; unset = none)
bash dev/g2/smoke/run-window.sh --compile-only          # what CI runs (no GUI session there)
```

### What the gate does

`egl-triangle-window.m` (ObjC++, ARC): NSWindow with a layer-backed
`CAMetalLayer` (1024×768 drawable px, backingScale 2.0),
`makeKeyAndOrderFront` **before** the present loop, Metal-platform EGL
display, config RGBA8 + D24S8, `eglCreateWindowSurface` on the layer,
GL ES 3.0 clear + triangle, `glReadPixels` probes centre
(255,128,0,255) and corner (0,0,64,255), exact-size P6 PPM write
(16-byte header + W·H·3), then a 3.0 s present loop (~30 fps, 97 frames
on this box) that ends early on Esc or window close. `run-window.sh`
wraps it: flag parsing, artifact gate, PASS/FAIL on the binary's exit.

### The gates — six review findings, each a way the smoke could lie

Filed as #37–#42 in review of PR #36, fixed before merge:

| Finding | Gate |
|---|---|
| #39 — a missing/empty artifact still passed | the binary exits 1 when the PPM can't be written or lands empty (`ppmOk` tracked across the write); the script refuses a 0-byte artifact too, as defense-in-depth |
| #42 — a nil Metal device surfaced as a misleading "F1 trigger" | `MTLCreateSystemDefaultDevice()` probed at the top of `main`: exit 2 with a clear message, so a GPU-less machine reads as environment failure, not F1 |
| #38 — a FAIL reported stale egl/gl errors | all judging (pixel probes, artifact, frame count) happens **before** EGL teardown — `fail()`'s `eglGetError`/`glGetError` read a live context; PASS alone is printed after teardown. Nuance: for a values-wrong failure both eras coincidentally report `EGL_SUCCESS`/`GL_NO_ERROR`; the era split shows when teardown itself fails |
| #41 — the log claimed the full 3.0 s on early exit | the frame-count line reports the measured interval, not `SMOKE_SECONDS` |
| #37 — unknown flags silently became the ANGLE dist dir | a `--*)` usage case names the bad option and exits 1 before any build or window |
| #40 — a run whose window never became visible PASSed on 0 frames | `frames == 0` is a FAIL **regardless of cause** — the recorded decision (2026-11-06): keep-PASS-with-distinct-logging and the fail-only-if-never-visible hybrid were considered and passed over for the strictest gate; ending the run before the first frame presents is a failure, full stop. The header comment says so |

Provenance: #39/#38/#41/#37/#40 are each proven at runtime with a forced
negative (unwritable path; a sed-forced pixel FAIL exiting 1
pre-teardown; a `SMOKE_SECONDS = 0.4` variant logging "in 0.4 s";
`--compil-only`; a `BOOL quit = YES` variant exiting 1 with no PASS).
The #42 nil path is proven by inspection only — no GPU-less machine
here to run it on.

CI compiles the window TU (`--compile-only`, in the render job); the
live gate stays manual on the dev Mac — CI has no GUI session — with
the PPM as its artifact. Next: M3.1, window natives + dynamic-size
`EglRenderContext` (the pbuffer canary stays green throughout).

## M3.1 — window natives + dynamic-size context (2026-11-06, #49)

`RenderSmoke --window W×H` swaps the init pbuffer for a **window
surface**: a host dylib (`render/WindowHost.m`) owns a bare off-screen
`CAMetalLayer`, `render/WindowHost.java` drives it over JNI, and
`--resize` changes the layer's `drawableSize` mid-run the way a real
host does on a window resize — before `ctx.resize()` adopts it. PASS
requires a window surface on the layer, the mid-run resize gone through
the host (`eglQuerySurface` truth at the new size), the
`OnSizeChangedListener` fired, every `swap()` a successful present
(counted; zero failures allowed), sentinel fully replaced and content
pixels at the new size, and the readback PNG at 384×256. Two runs gate
(`make test-render-window`): bare, and the M2 GeoJSON + M2.3 basemap
stack (116 presents on this box). This upgrades the plan above ("the
window gate is manual on the dev Mac"): the harness needs no GUI
session, so **CI runs the exercise itself**.

### The ANGLE-Metal window-surface sizing contract

The gate exists because of these (dated comments in `mactak_egl.cpp`):

- **A window surface's size is taken once at creation.** After the host
  resizes the layer (`drawableSize` 640×480 → 384×256),
  `eglQuerySurface` keeps reporting 640×480 — unlike pbuffers, where
  the resize fast-path's query stays truthful. `adoptSurfaceSize`
  treats window surfaces as fixed-size: **destroy, then create** on the
  same layer, config and context.
- **The ordering is load-bearing:** a second `eglCreateWindowSurface`
  on a layer that still holds a live surface is refused with
  `EGL_BAD_ALLOC` — the first cut created-then-destroyed and hit
  exactly that. Destroy-then-create is mandatory, and if the recreate
  fails there is no window-surface fallback; the caller's exit gates
  report it.
- **No `dpi` parameter**, though the natives plan above said
  `createWindowSurface(layer, w, h, dpi)`: the harness pins
  `contentsScale = 1`, so point size = pixel size = `drawableSize` and
  the engine's size story is unchanged. Backing-scale calibration
  (labels at Retina density, per the calibration note above) belongs to
  M3.3's Retina step — one visual check there, not guesswork.

### The harness has no NSWindow — launcher-thread evidence for the shell model

The first cut hosted a real `NSWindow` and AppKit aborted it:
`NSWindow should only be instantiated on the main thread!`. Under the
plain `java` launcher, `JavaMain` runs on a **spawned pthread**, not
the process main thread — which also corrects F2's assumption above
("NSApp runs on the process main thread (which is Java's main)"): it
isn't, so option B would have needed a main-thread dispatch dance of
its own. EGL needs only the layer, so the harness hosts a bare
`CAMetalLayer` — bounds pinned equal to `drawableSize`, `contentsScale`
1 — with no AppKit at all, headless-safe, and direct evidence for A:
the Swift shell owns the real main thread from the first line, exactly
where AppKit wants it.

### Gates and provenance

`javac -Xlint:all -Werror`; `test-render-window` 2/2 (bare + GeoJSON);
`test-render-resize` 2/2 and `test-render` 3/3 — the pbuffer canaries
are untouched by the `adoptSurfaceSize` change; `make lint`; the dylib
build CI uses (`build-window-host.sh`). Until a stacked PR is
retargeted to `main`, it sits checkless by design — pull_request runs
are `branches: [main]`-only (the required-checks setup's design, per
ci.yml's header) — so its content is validated meanwhile by
`workflow_dispatch` runs on the branch tip, which run the ref's own
ci.yml with all gates forced on; the retarget still happens, but only
when the PR is about to merge.

**Local incident, for the next rebuild (2026-11-06).** After
`make build-angle` re-staged the dylibs, every process that dlopen'ed
them died with SIGKILL (exit 137): the JVM canary, and `python3`
`ctypes` on the *engine* dylib too — while `codesign -v --strict`
passed on both (linker-signed adhoc) and memory was 92% free. A copy
to /tmp, without the `com.apple.provenance` xattr, gave a clean dlopen
error instead of the kill — the tell. Fresh `codesign -f -s -` over
the staged pair fixed it at once; rebuilds since are stable. Suspected:
macOS 27.2 provenance enforcement against re-staged linker-signed
output. ~~Candidate follow-up: a one-line re-sign in `build-native.sh`'s
staging step (deliberately left out of #49).~~ Landed 2026-11-07 (G2.4a):
`build-native.sh` re-signs every staged `native-dist/*.dylib` adhoc, as
`fetch-angle.sh` already did for the ANGLE pair. Diagnosis shortcut: a
Killed: 9 with a passing `codesign -v` means re-sign the staged pair
before re-bisecting anything.

## G2.4a — `resolveTexture` program bind + engine-shadow mechanism (2026-11-07)

First G2.4 patch that changes a frame: `GLQuadTileNode4.resolveTexture`
(child-texture FBO compositing, run from a queued render-thread event when
a tile read errors) now binds `core.shader.handle` and enables its two
attribute arrays before compositing, and restores the caller's program and
array-enable state after. A/B on the basemap smoke with `MACTAK_GL_DEBUG=1`:
baseline 4 × `glUniform4f: Uniform size does not match uniform method`
(`GL_INVALID_OPERATION`, one per composited edge tile), patched 0; the
known-benign list above loses its only GL entry. `test-render` 3/3,
`test-render-window` 2/2, `test-render-resize` 2/2.

### How a Java engine patch ships here

The engine's Java comes from the transplant jar, so a `.patch` alone
changes nothing at runtime. The mechanism:

- `dev/g1/patches/<name>.patch` is the **single source of the change**
  (same place as the C++ patches; applies with `-p3` to upstream
  `src/takkernel/engine/src/main/java`).
- `dev/g2/render/engine-shadows/<pkg path>/X.java` is the patched upstream
  file, byte-identical to `src/` + patch, compiled ahead of the jar.
- `make check-engine-shadows` (CI, `render-angle` job, which has upstream
  `src/` checked out) re-derives each shadow from `src/` + patch in a temp
  dir and `cmp`s — the shadow cannot drift from the patch. Pairs live in
  the Makefile's `ENGINE_SHADOWS`.
- `render/run.sh` compiles `engine-shadows/` in a first pass with `-nowarn`
  (upstream code is not held to our `-Xlint:all -Werror` bar — the pristine
  file trips 45 deprecation/cast warnings), then our sources strict with
  the shadow classes ahead on the classpath.

`engine-shadows/` is distinct from `src/`'s shadows (`EngineLibrary`,
`AtakMapView`, `android.*`): those are **replacements** we own; these are
**upstream + patch** we do not edit by hand.

## M3.2 — the shell: JVM in-process, ANGLE window hosted by AppKit (2026-11-07)

`dev/g2/shell/` is the M3 host model made real: `jni_boot.c` + `bridge.h`
(clang, against the JDK's `jni.h`) find and dlopen `libjli.dylib` and run
`JNI_CreateJavaVM` with `-Djava.library.path`, headless AWT and the GDAL
data dir as options; `main.swift` (swiftc -O) builds the `NSWindow` over a
`MetalView` whose private `CAMetalLayer` crosses JNI as an opaque `jlong`,
then upcalls `mactak.render.WindowApp.start` (15 params) and idles in
AppKit's run loop, polling `WindowApp.pollStatus()` every 100 ms. The
`WindowApp` statics are the RenderSmoke body reshaped for embedding: the
render thread draws the M2/M3.1 stack into the window surface, publishes
`PHASE_FRAME_DONE`, **parks** (the window stays up for the shell's
`--linger`), and tears down on its own thread (the EGL context never
leaves it) once `stop()` wakes it, ending in `PHASE_EXITED` for the shell
to exit with its code. Entry points: `make build-shell` (compile-only —
CI), `make test-shell` (the GUI gate; `shell/run.sh` shares `render/env.sh`
so shell and smoke build the very same classes).

### Gate results (this box, 2026-11-07)

- `make lint` — bash -n + shellcheck (-x now, see #47) + markdownlint +
  actionlint, clean.
- `make test-render` — 3/3 PASS (bare, GeoJSON layer, MBTiles basemap +
  layer), first exercise of the run.sh/env.sh refactor.
- `make test-render-window` — 2/2 PASS (window surface + mid-run resize).
- `make test-shell` — exit 0: `CAMetalLayer @ 0x…` → EGL 1.5 metal window
  surface → 5 frames, 0 failed presents, sentinel 0, `PASS` → linger 4 s →
  `poll → 2` → `exiting with WindowApp's code 0`. Artifact:
  `dev/g2/build/shell-frame.png` (640×480 RGB PNG, hand-written encoder —
  see #44).

### Bootstrap notes (JNI layering ground truth)

- This JDK's `jni.h` (C mode) defines `JNIEnv` as
  `const struct JNINativeInterface_ *`, so `mactak_env()` returning
  `JNIEnv *` is ABI-correct. In Swift the function table is
  `env.pointee!.pointee` (the middle deref is optional), and **every table
  call takes `env` as its first argument** — the Swift equivalent of C's
  `(*env)->Fn(env, …)`.
- A first "fix" that returned `JNIEnv` by value was one deref too shallow;
  the build exposed the real layout and the original signatures came back.
- Swift's top-level scope cannot capture top-level `guard let` bindings —
  the pattern is plain `let` → nil-check → force unwrap, or move the state
  into a class (`Shell` owns `opt`/`midPoll`/`midExit`/`midStop`).
- Signature strings must be cross-checked against `javap -s -p`: doing so
  caught `SIG_START` written `…DDDJI)V` where the class says `…DDDIJ)V`
  (frames/settleMs widths swapped) and a missing `[` on the first
  `String[]` — both would have failed `GetStaticMethodID` at runtime as
  `NoSuchMethodError` with no hint where to look.

### Teardown decision (why the shell never joins the JVM)

`DestroyJavaVM` blocks until every non-daemon thread ends, which inverts
control: the AppKit main thread would wait on the render thread it is
supposed to be supervising. Instead the shell treats the JVM as a
subsystem: `stop()` (a `WindowApp.class.notifyAll()` on the monitor the
render thread parks on) asks the render thread to wind down **on its own
thread**; the shell polls `pollStatus()` for `PHASE_EXITED` and only then
terminates AppKit, exits with `WindowApp`'s exit code, and leaves the JVM
alive for `exit(3)` to reap. Bounded fallbacks: a teardown still running
after 10 s (user-quit path) or 30 s (linger path) is reported and the
process exits with the last known exit code.

### Traps found on the way (#43–#47)

| trap | what it is / what now guards it |
|------|---------------------------------|
| #43 | **AWT must not initialize inside the shell's process.** `writePng`'s `BufferedImage`/`ImageIO` pulled AWT up mid-run: `JRSAppKitAWT markAppIsDaemon` ("Process manager already initialized: can't fully enable headless mode") and an `AWT-AppKit` daemon appeared — AWT fights our own `NSApplication` for the AppKit main thread. `WindowApp.writePng` is now a hand-rolled PNG encoder (zlib IDAT, CRC32 chunks, RGB8, filter 0) with no AWT import; `RenderSmoke` keeps ImageIO — a standalone JVM hosts no `NSApplication` to fight over. Guard: comment at the encoder; anything drawing a frame in-process stays AWT-free until M3.4's loop replaces the framing. |
| #44 | **`.terminateLater` wedges the quit handshake.** Returning it from `applicationShouldTerminate` makes AppKit run a private nested run-loop mode inside `-terminate:`; timers scheduled in `.default`/`.common` never fire there, so the `NSApp.reply(toApplicationShouldTerminate:)` the design counted on can never happen (proven by `sample`: main parked in `_shouldTerminate`'s nested `mach_msg`, render thread long gone). The shell now never returns `.terminateLater`: linger-winddown happens in `tick()` first, and the user-quit path asks `stop()` and pumps `RunLoop.main.run(mode: .default)` with a 10 s bound before `.terminateNow`. |
| #45 | **`PHASE_FRAME_DONE` was documented but never published** — the render thread parked without setting it, so the shell's linger timer never started and the window stayed up forever. Now set inside the park's `synchronized` block before `wait()`. Guard: `make test-shell` fails by timeout without it; the shell logs `poll → 1` on the transition. |
| #46 | **stdout is fully buffered when redirected** — Swift `print` lines (frame-done, poll transitions) sat in an 8 KB buffer while the gate hung, hiding exactly the evidence needed. `setvbuf(stdout, nil, _IOLBF, 0)` at startup makes the gate log live. |
| #47 | **shellcheck can't follow `source "$HERE/env.sh"`** — SC1091 fails `make lint`, and a bare `source=` directive resolves against the invocation CWD. The scripts carry `# shellcheck source-path=SCRIPTDIR source=…` and `make lint` runs shellcheck `-x`, so the sourced `env.sh` is checked into the bargain. |

Also fixed en route: `stop()`'s `notifyAll()` written against a static
context (a compile error once the park was real) — it notifies on
`WindowApp.class`, the monitor the park waits on; and `start()`'s lambda
captured reassigned locals (`layers`/`basemaps` null-defaulting) — now
`final` locals.

### CI split

`shell-compile` job (macos-26, Zulu 8 headers via setup-java): `make
build-shell` only — clang/swiftc, no engine, no GUI session. The run gate
stays `make test-shell` on the dev Mac, unchanged from the M3.0 decision
(CI has no WindowServer session). Roadmap flips M3.2 → DONE at merge.

## G2.4b — real imagery, step b.0: the `org.gdal` bindings exist (2026-11-08)

G2.4's headline is the first non-synthetic raster through the engine, and
its one hard prerequisite is trap 17: `GdalTileReader`, `GdalLayerInfo`,
`GdalDatasetProjection2` and 19 other engine classes bind the GDAL SWIG
Java bindings (`org.gdal.*` → `gdal.jar` + `libgdalalljni`), which the
engine transplant jar does not ship (correction, b.2: `android-port-3.1.0.jar`
*does* carry a GDAL 2.4-era `org.gdal` — trap #49), Homebrew `gdal` does
not build, and upstream builds from its own gdal-2.4.4-mod tree
(`takthirdparty/mk/gdal.mk`). Step b.0 de-risks that alone, before any
rendering depends on it.

```sh
make gdal-java        # dev/g2/fetch-gdal-java.sh → dev/g2/gdal-java-dist/{gdal.jar,libgdalalljni.dylib,PROVENANCE.txt}; then smoke/run-gdal-java.sh
```

### What the script does, and why that way

- **The bindings must match the installed GDAL, not upstream's.** The
  engine dylib already links Homebrew `libgdal.39` (G0's R3 fallback), so
  wrappers generated from the gdal-2.4.4 interfaces would be the wrong
  ABI. `fetch-gdal-java.sh` reads `gdal-config --version` (3.13.3 today),
  downloads the OSGeo release tarball of **that** version (sha256-pinned
  per version; an unpinned version is a loud FATAL, by design — a Homebrew
  gdal bump already fails the `Brewfile.lock.json` freshness gate, so the
  pin lands in the same PR as the lock), extracts only `swig/include` +
  `ogr/ogr_srs_api.h` (`osr.i` `%include`s it by relative path), and runs
  the five `swig -java` invocations exactly as GDAL's own
  `swig/java/CMakeLists.txt` does (`-Wall -package org.gdal.<pkg>`;
  `gdalconst` is C, the rest C++; `gnm` included because Homebrew's build
  exports GNM).
- **One libgdal in the process.** The wrappers compile against
  `gdal-config --cflags` and link `gdal-config --libs`; the script asserts
  the engine dylib's `libgdal` install name equals Homebrew's before it
  builds, so `GdalTileReader` (via `org.gdal`) and the engine's native
  `GdalLibrary::init` share one driver registry. 2223 `Java_org_gdal_*`
  exports; `-fno-strict-aliasing` as GDAL requires for SWIG's upcasts.
- **No ant/maven/cmake.** GDAL's build uses ant only to jar and publish;
  here `javac -source 8` + `jar cfm` produce `gdal.jar` (98 classes) with
  the version in the manifest. Output is adhoc-signed with stderr kept
  (fetch-angle's codesign lesson), `PROVENANCE.txt` records gdal/swig/jdk
  versions, the tarball URL + sha256 and both artifact sha256s. The build
  is reproducible: two runs gave identical `libgdalalljni.dylib` hashes.

### The smoke (`smoke/GdalJavaSmoke.java`) — three proofs, quoted

```text
gdal-java-smoke: org.gdal loaded, GDAL 3.13.3 (213 drivers)
gdal-java-smoke: GTiff round-trip OK 64x64 gt[0]=-122.5 gt[3]=37.8 srs=EPSG:4326
ERROR 1: PROJ: webmerc: Invalid latitude
gdal-java-smoke: axis-order as-engine (ImportFromEPSG(4326), TransformPoint(lon,lat)): strategy=1 → (Infinity, Infinity) != expected (lat,lon authority order)
gdal-java-smoke: axis-order with OAMS_TRADITIONAL_GIS_ORDER: → (-13625506, 4537132) = expected
gdal-java-smoke: axis-order verdict: engine construction FLIPS axes on this GDAL — GdalLibrary needs OAMS_TRADITIONAL_GIS_ORDER (G2.4 b.2)
gdal-java-smoke: PASS
```

1. `gdal.VersionInfo("RELEASE_NAME")` must equal `gdal-config --version`
   — the JNI library loaded Homebrew's libgdal, not some other copy.
2. GTiff create → write → reopen → read through `org.gdal` with
   geotransform, EPSG:4326 WKT and pixel values intact.
3. The b.2 question, answered on evidence (trap #48 below). The smoke
   *records* the verdict and FAILs only if even the corrected form is
   wrong (that would mean PROJ data is missing).

### Traps found on the way (#48)

| trap | what it is / what now guards it |
|------|---------------------------------|
| #48 | **GDAL 3 honours EPSG axis order; the engine assumes GDAL 2's lon,lat.** `GdalLibrary.initImpl` builds `EPSG_4326 = new SpatialReference(); ImportFromEPSG(4326)` with no `SetAxisMappingStrategy`, and `GdalDatasetProjection2` feeds it `TransformPoint(lon, lat)`. On GDAL ≥ 3.0 (PROJ 6+) that SRS is lat,lon by authority order: the smoke's `-122.4, 37.7` is read as latitude −122.4 → PROJ "Invalid latitude" → `(Infinity, Infinity)`. With `OAMS_TRADITIONAL_GIS_ORDER` on both SRSes the same call gives the correct Web-Mercator metres. **Guard today:** the smoke prints the verdict every run, so a GDAL that changes behaviour is noticed. **Fix (b.2, next):** an engine Java patch + shadow (the #53 mechanism) setting `OAMS_TRADITIONAL_GIS_ORDER` on `EPSG_4326` and on every dataset SRS `GdalDatasetProjection2`/`GdalLayerInfo` construct — upstream's Android build never saw this because its GDAL is 2.4.4. Until b.2 lands, any GDAL-backed raster would georeference into the wrong hemisphere or not at all. **C++ residual (2026-11-10):** b.2 pinned the Java SRSes only; the engine's C++ OGR transforms flipped projected offline layers until `gdal3-axis-order-cpp-default.patch` (`dev/g1/NOTES.md` §G1.12, guarded by `layer.sh`'s coordinate check). |

### Gates and provenance

`make gdal-java` PASS (b.0's only gate; also runs in CI's `render-angle`
job after the engine build so the install-name cross-check is live);
`shellcheck` on both scripts; `javac -Xlint:all -Werror` on the smoke;
Brewfile + lock gain `swig` (4.5.1) with the `render-angle` brew line, so
the supply-chain union check stays equal. Nothing in the render path
changes yet: `RenderSmoke` still unregisters `GdalTileReader.SPI`; b.1
(GeoTIFF fixture through `GdalTileReader` → `GLQuadTileNode4`) is where
that flips, after b.2's axis fix.

## G2.4b — step b.2: the axis-order fix, as an engine patch (2026-11-09)

Trap #48's fix, shipped the #53 way: one patch,
`dev/g1/patches/gdal3-axis-order-traditional-gis.patch`, two shadows
(`engine-shadows/com/atakmap/map/gdal/GdalLibrary.java`,
`…/layer/raster/gdal/GdalDatasetProjection2.java`), drift-gated.

```sh
make test-gdal-projection   # render/run-gdal-projection.sh → GdalProjectionSmoke; needs build-angle + gdal-java
```

### The patch

- `GdalLibrary.traditionalGisOrder(SpatialReference)` — new static helper:
  `SetAxisMappingStrategy(OAMS_TRADITIONAL_GIS_ORDER)`, returns the SRS for
  chaining. The javadoc at the patch site carries the why.
- `GdalLibrary.initImpl`: `EPSG_4326` gets it right after `ImportFromEPSG`.
- `GdalDatasetProjection2(SpatialReference)`: the dataset SRS gets it before
  the two `CoordinateTransformation`s are built — that covers both
  subclasses (`GeoTransform` from `GetProjectionRef()`, `GroundControlPoints`
  from a WKT) and therefore every `GdalDatasetProjection2.getInstance`
  caller (`GdalLayerInfo`, `GLGdalMapLayer2`, `MosaicUtils`,
  `GdalElevationChunk`, `PfpsUtils`, `DRGTileReader`).

Not patched, deliberately: `GdalLibrary.getWkt` (export only — the strategy
is a transform-time property), `WFSFeatureDataStore3` (builds its own
transform from a layer SRS; off the G2 path, revisit at G4),
`Pix4dGeoreferencer`/`GeoPackageLayerInfoSpi` (construct an SRS but never
transform through it on this path).

### The gate — `GdalProjectionSmoke`, the engine's own path, quoted

(b.2's run; the first line is trap #50, closed by b.1a below — the current
gate output is quoted there.)

```text
gdal-projection-smoke: GdalLibrary.init() stopped at a missing native (expected until b.1): com.atakmap.map.gdal.VSIJFileFilesystemHandler.installFilesystemHandler(Ljava/lang/String;Lcom/atakmap/map/gdal/VSIJFileFilesystemHandler;)V
gdal-projection-smoke: GdalLibrary.EPSG_4326 axis mapping strategy=0 (OAMS_TRADITIONAL_GIS_ORDER=0)
gdal-projection-smoke: projection GeoTransform srid=4326
gdal-projection-smoke: image(0,0) → lat 37.800000 lon -122.500000
gdal-projection-smoke: ground(centre) → image(32.000000, 32.000000)
gdal-projection-smoke: PASS
```

It is compiled by `render/env.sh`'s pass, so the shadows are the classes
under test, and it runs the real `GdalLibrary.init()` with the engine
dylibs loaded — `gdal.AllRegister`, the config options, `EPSG_4326`,
`registerProjectionSpi` (JNI) — then `GdalDatasetProjection2.getInstance`
on a 64×64 EPSG:4326 GeoTIFF and round-trips pixel (0,0) ↔ NW corner and
centre ↔ (32,32) to 1e-9/1e-6. **A/B:** with the two shadows removed and
`render-classes` cleared, the same smoke reports `strategy=1` and FAILs on
the first gate (`EPSG_4326 is not in traditional GIS order`); b.0's
bindings-level probe already showed what the transform then does
(`(Infinity, Infinity)`).

### Traps found on the way (#49–#50)

| trap | what it is / what now guards it |
|------|---------------------------------|
| #49 | **`android-port-3.1.0.jar` ships a GDAL 2.4-era `org.gdal.*` (66 classes).** With it ahead on the classpath the shadow failed to compile (`osrConstants` has no `OAMS_*`), and at run time its `gdalJNI` — GDAL 2.4 SWIG signatures — would bind against our 3.13 `libgdalalljni`: that stale copy, not a missing one, is what trap 17's `UnsatisfiedLinkError` came from. **Guard:** `render/env.sh` puts `gdal.jar` *first* in `CP` (comment at the site names this trap) and fails loudly when `make gdal-java` hasn't staged it; `GdalJavaSmoke` (b.0) asserts the loaded GDAL's `VersionInfo` equals `gdal-config --version`. b.0's "the transplant jar does not ship org.gdal" is corrected above. |
| #50 | ~~**`GdalLibrary.init()` throws `UnsatisfiedLinkError` at `VSIJFileFilesystemHandler.installFilesystemHandler`.**~~ **Fixed 2026-11-09 (b.1a, below).** `vsi_jfile.cpp` was excluded from the JNI glue (`build-native.sh`: GDAL VSI API drift, same family as the LAS exclusion), and `init()` catches only `IOException`, so the engine's GDAL init could not complete on this build — `initSuccess` stayed false and `IOProviderFactory`'s VSI prefix was never installed. Everything before that line (`AllRegister`, `EPSG_4326`, `registerProjectionSpi`) did run, which is what b.2's gate relied on at the time. **Guard now:** `GdalProjectionSmoke` asserts `init() == true` and opens a GeoTIFF through `/vsitakio/`. |

### Also changed

- `make check-engine-shadows` handles a patch spanning several shadows:
  copy all shadowed upstream files first, apply each distinct patch once,
  then `cmp` each shadow (the old per-pair loop would have applied a
  two-file patch against a one-file tree). Negative run verified: a
  perturbed shadow reports DRIFT and exits 1.
- `render/run.sh` and `shell/run.sh` add `$GDAL_JAVA` to
  `java.library.path` so `gdalJNI`'s `System.loadLibrary("gdalalljni")`
  resolves; `env.sh` exports `GDAL_JAVA` for that.

### Gates and provenance

`make check-engine-shadows` OK (+ negative); `make test-gdal-projection`
PASS (+ A/B FAIL without shadows); `make test-render` 3/3 with 0 KHR_debug
messages, `test-render-window` 2/2, `test-render-resize` 2/2 — the
classpath reorder (gdal.jar first) changed nothing on the existing path;
`make build-shell` compiles; `shellcheck -x` on env/run scripts; CI
`render-angle` gains the `test-gdal-projection` step right after
`gdal-java`.

## G2.4b — step b.1a: `vsi_jfile.cpp` rejoins the glue; `GdalLibrary.init()` completes (2026-11-09)

Trap #50's fix. `GdalTileReader` (b.1's target) needs `GdalLibrary.init()`
to return true, and `init()` ends by installing the engine's Java-backed
GDAL virtual filesystem (`/vsitakio/` → `VSIFileFileSystemHandler` →
`java.nio.channels.FileChannel`, the hook `IOProviderFactory`-backed and
encrypted storage use later). Its native, `jni/vsi_jfile.cpp`, had been
excluded since G1.0 for "GDAL VSI API drift". The drift turned out to be
four signatures and two missing pure virtuals:

| GDAL 2.4 (`vsi_jfile.cpp` as written) | GDAL 3.13 (`cpl_vsi_virtual.h`) |
|---|---|
| `VSIVirtualHandle *Open(name, access, bool bSetError)` | `VSIVirtualHandleUniquePtr Open(name, access, bool bSetError, CSLConstList papszOptions)` |
| `size_t Read(void*, size_t nSize, size_t nMemb)` virtual | `size_t Read(void*, size_t nBytes)` pure virtual; the size×count form is a non-virtual base wrapper |
| `size_t Write(const void*, size_t, size_t)` virtual | `size_t Write(const void*, size_t nBytes)` pure virtual (same) |
| — | `void ClearErr()`, `int Error()` pure virtual (GDAL 3.9+) |
| `VSIFileManager::InstallHandler(prefix, VSIFilesystemHandler*)` | deprecated; `InstallHandler(prefix, std::shared_ptr<…>)` |

`dev/g1/patches/vsi-jfile-gdal3-api.patch` ports exactly that: `Open`
returns `VSIVirtualHandleUniquePtr(new VSIJFileHandle(…))`/`nullptr`;
`Read`/`Write` take byte counts and return bytes (the `n/nSize` element
division is gone — GDAL's wrapper does it); a `m_error` flag set when the
Java `read`/`write` threw backs `Error()`/`ClearErr()`; the handler is
installed via `std::make_shared`. Seek/Tell/Eof/Close/Stat are untouched.
`build-native.sh` drops the exclusion (the companion
`jvsijfilefilesystemhandler.cpp` named in the old regex does not exist at
the pin; its javah header is already in `dev/g1/jni-include/`).

### The gate — `GdalProjectionSmoke`, tightened, quoted

```text
gdal-projection-smoke: GdalLibrary.init() = true
gdal-projection-smoke: GdalLibrary.EPSG_4326 axis mapping strategy=0 (OAMS_TRADITIONAL_GIS_ORDER=0)
gdal-projection-smoke: projection GeoTransform srid=4326
gdal-projection-smoke: image(0,0) → lat 37.800000 lon -122.500000
gdal-projection-smoke: ground(centre) → image(32.000000, 32.000000)
gdal-projection-smoke: /vsitakio/ open OK 64x64 gt[0]=-122.5000 gt[3]=37.8000 driver=GTiff
gdal-projection-smoke: PASS
```

The b.2 tolerance (`catch (UnsatisfiedLinkError)` + a "stopped at a missing
native" line) is removed: `init()` must return `true`. New third proof: the
same GeoTIFF is opened as `/vsitakio/<path>` — GDAL's GTiff driver now runs
`VSIJFileFilesystemHandler::Open`/`Stat` and `VSIJFileHandle::Seek`/`Read`/
`Tell`/`Eof` against a `FileChannel` — and must report the same size and
geotransform and read its band. That exercises every ported override on the
read path.

### Gates and provenance

Full `MACTAK_GLES=angle bash dev/g1/build-native.sh` (patch applied, TU
compiled, 33 GTest + JVM load canaries PASS); `make test-gdal-projection`
PASS; `make test` PASS; `make test-render` 3/3 (0 KHR_debug),
`test-render-window` 2/2, `test-render-resize` 2/2; `make build-shell`;
`make lint`. Nothing else changes in the glue: the only new exports are
`Java_com_atakmap_map_gdal_VSIJFileFilesystemHandler_installFilesystemHandler`
and the two classes. Stacked on #68 (b.2) because the gate is b.2's smoke.

## G2.5 — correctness audit, pass 1 (2026-11-10, branch `g2/basemap-gate-coverage` and follow-ups)

First correctness read of `dev/g2`: the `android.*` stand-ins, the EGL
and GLES natives, the render harnesses (`RenderSmoke`, `WindowApp`), the
Swift shell and the scripts. Findings, highest priority first; each is
fixed on its own branch, in this order.

| # | Severity | Finding | Status |
|---|---|---|---|
| 1 | High | The basemap leg of the render smoke could not fail: it passed on "content pixels > 0", which the vector layer alone satisfies | **Fixed here**: `ContentGate`, guarded by `render/test/basemap-gate.sh` |
| 2 | Medium | `android.net.Uri.fromFile` does not encode the path: `#` and `?` truncate it, `%XX` is decoded. The engine opens its databases through it (13 call sites) | **Fixed** (branch `g2/uri-fromfile-encoding`): `fromFile` encodes like Android, guarded by `render/test/uri.sh` |
| 3 | Medium (latent) | The GLES shim's `glVertexAttribPointer` accepts an array-backed `Buffer`: GL keeps a pointer into a copy that `bufferRelease` frees. Android rejects non-direct buffers there | **Fixed** (branch `g2/gles-shim-direct-buffers`): `bufferDirect` in the generator, guarded by `render/test/gles-shim.sh` |
| 4 | Low | `Uri.getQueryParameter` leaves `+` as `+`; Android decodes it to a space | **Fixed** (branch `g2/uri-query-plus`), guarded by `render/test/uri.sh` |
| 5 | Low | `shell/run.sh` leaks its scratch `MACTAK_HOME` every run: the `EXIT` trap never fires after `exec` | **Fixed** (branch `g2/shell-run-scratch-cleanup`): no `exec`, guarded by `dev/check-trap-exec.sh` |
| 6 | Low | A value option given last crashes the Swift shell (array index out of range); `RenderSmoke` dies with a stack trace instead of usage | **Fixed** (branch `g2/cli-missing-value`), guarded by `shell/test/args.sh` and `render/test/args.sh` |
| 7 | Low | `WindowApp.teardown` skips EGL destroy when it fails before the context exists; `BitmapRegionDecoder` leaks its file stream; `Canvas.save`/`restore` does not cover the clip; ~~`fetch-angle.sh` pipes `otool` into `grep -q` under `pipefail` (the trap `env.sh` documents)~~ (fixed on branch `chore/rebase-guards`, with `lipo` twice more, guarded by `dev/check-pipefail-grep.sh`); the GLES shim does not bounds-check array offsets | Open |
| 8 | High | The Swift shell exited 0 whatever the render did: AppKit's `terminate` ends the process itself, so the code that read `WindowApp`'s exit code never ran and `make test-shell` could not fail | **Fixed** (branch `g2/shell-exit-code`): `applicationWillTerminate` exits with the code, guarded by `shell/test/exit-code.sh` (manual gate) |

Settled on the bench (2026-11-10): the reading left open whether the
Swift shell exits non-zero when `WindowApp` fails. It did not; that is
finding #8, trap #56. #7 is on hold by the owner's call.

Traps found on the way (continuing G2 numbering):

- **#51 — "content pixels > 0" proves the top layer, not the stack.**
  The basemap step runs `--basemap … --layer …`. The sf-landmarks
  vectors alone light 23890 of 262144 px; the graticule basemap under
  them fills all 262144 (CI, PR #87's render job). Either count passed,
  so a basemap that never drew read `PASS`. The poll loop had the same
  bar, so it could also stop waiting once the vectors landed, before
  the tiles did. **Guard:** `ContentGate.requiredPixels` sets one bar
  for the poll and the verdict: with a basemap attached, content must
  cover half the frame (`BASEMAP_MIN_COVER`); with only vector layers,
  one pixel. `render/test/basemap-gate.sh` is the negative canary, in
  CI and `make test-render`: the same graticule built over the Oakland
  hills, east of the camera frame, must make the smoke exit 1 with
  `FAIL: basemap attached but content covers …`.
- **#52 — `Uri.fromFile` built its string from the raw path.** The
  stand-in parsed `"file://" + file.getAbsolutePath()`, so URI syntax in
  a folder or file name was read as URI syntax: `Maps #2/tracks.sqlite`
  came back from `getPath()` cut off after `Maps` and its space (the
  rest became the fragment), `what?/a.kml` lost everything after `what`, and
  `100%25 done` read back as `100% done`. `IOProviderFactory` and
  `DefaultIOProvider` open databases at `info.uri.getPath()`, so the
  engine would have opened, or created, the wrong file. Android encodes
  the path first (`PathPart.fromDecoded`). **Guard:** `fromFile` now
  passes the path through `Uri.encode(path, "/")`, and `encode` follows
  Android's rule exactly: letters, digits and `_-!.~'()*` stay, the rest
  becomes the %XX of its UTF-8 bytes (the old `URLEncoder` route also
  escaped `!~'()`). `render/test/uri.sh` (pure JDK; CI's JVM job) pins
  seven round-trip paths, the encoded string, `encode`/`decode`, and the
  `parse` behaviour the engine already relied on.
- **#53 — a vertex-array pointer outlives the JNI call.** The generated
  shim ran every `Buffer` argument through `bufferAcquire` /
  `bufferRelease`: a direct buffer gives its address, an array-backed
  one a `Get<Type>ArrayElements` copy that is released after the GL
  call. That is right for calls that consume their data before
  returning (`glBufferData`, `glTexImage2D`), and wrong for
  `glVertexAttribPointer` / `glVertexAttribIPointer`: GL stores the
  pointer and reads through it at draw time, by which point the copy is
  freed. Android refuses a non-direct `Buffer` there
  (`IllegalArgumentException: Must use a native order direct Buffer`).
  The engine's renderers allocate direct buffers, so nothing hit this;
  the shim accepted quietly what Android rejects. **Guard:**
  `gen-gles-shim.py` routes `RETAINED_POINTER_FUNCS` through
  `bufferDirect`, which throws the same exception before any GL call.
  `render/test/gles-shim.sh` (`GlesShimSelfTest`, CI render job and
  `make test-render`) pins it on a 16x16 ANGLE pbuffer: both entry
  points refuse an array-backed buffer, accept a direct one and `null`,
  and `glBufferData` still takes an array-backed one.
- **#54 — `exec` discards the shell that owns the `EXIT` trap.**
  `shell/run.sh` made a scratch `MACTAK_HOME` with `mktemp -d`, armed
  `trap 'rm -rf "$SCRATCH"' EXIT`, then launched the shell binary with
  `exec`. `exec` replaces the bash process, so the trap never ran and
  every `make test-shell` left a directory in `$TMPDIR` (the engine's
  `atak/` data root for that run). `render/run.sh` has the same trap and
  no `exec`, so it cleaned up. **Guard:** `shell/run.sh` now runs the
  binary as its last command and exits with its status, so the code
  WindowApp reports still reaches the caller. `dev/check-trap-exec.sh`
  (CI lint job, `make lint`) fails any script under `dev/` that arms an
  `EXIT` trap and also `exec`s a command.
- **#55 — a value option given last indexed past the arguments.** The
  Swift shell read every option's value with `i += 1; … argv[i]` and
  checked the bound only for `--classpath`, so `mactak-shell --out` (or
  any other value option last) died in a Swift array-index trap: no
  message, and a signal exit instead of the usage code 2. `RenderSmoke`
  did the same with `args[++i]` and left `Integer.parseInt` unguarded,
  so `--frames` or `--size 512` ended in a Java stack trace and exit 1,
  which reads as a render failure. **Guard:** the shell takes every
  value through `optionValue()`, which exits 2 with `<option> needs a
  value`; `RenderSmoke` catches the two exceptions around its parse
  loop and prints `<option> needs a value` or `bad <option> <value>`,
  then usage, exit 2. `shell/test/args.sh` runs the compiled shell with
  each of its 15 value options last (CI's shell-compile job; parsing
  ends before the JVM or a window exists), and `render/test/args.sh`
  runs six bad invocations through `render/run.sh` (CI's render job).
- **#56 — `NSApp.terminate` never returns to `main`.** The shell ended
  with `app.run()` followed by "read `WindowApp.exitCode()`, print it,
  `exit` with it". But once `applicationShouldTerminate` answers
  `.terminateNow`, `-[NSApplication terminate:]` posts
  `applicationWillTerminate` and calls `exit(0)` itself, so `run()` does
  not return and those lines never ran. Every run exited 0: a missing
  basemap (`WindowApp` code 2), a failed render (1) and an EGL failure
  (3) all read as success, and `make test-shell` could not fail. The
  tell was already in a passing run: no `exiting with WindowApp's code`
  line after `poll → 2`. **Guard:** the shell implements
  `applicationWillTerminate` and exits there with `WindowApp`'s code, on
  every quit path. `shell/test/exit-code.sh`, now the second leg of
  `make test-shell`, runs a basemap that does not exist and requires
  exit 2. It opens a window, so it is a dev-Mac gate like the first
  leg; CI compiles the shell only.

Evidence for #1 (CI, render job, ANGLE Metal on a hosted runner).
Before: the canary alone on `be59312`, old gate (dispatch run
42869213426). The off-frame basemap passes the smoke, so the canary
fails:

```text
    render-smoke: basemap oakland-graticule.mbtiles type=momap provider=tileset res [9.55 .. 152.87] m/px cov lat [37.7186, 37.9962] lon [-122.3438, -121.9922]
    render-smoke: camera (37.79520, -122.45005) @ 25.01 m/px
    render-smoke: sentinel pixels left=0/262144 content pixels=23890 centre=(255,117,0,255)
    render-smoke: PASS
[basemap-gate] FAIL: expected exit 1 with 'FAIL: basemap attached but …', got exit 0
```

After: with `ContentGate`, on `d4fc664` (PR #88's render job, run
42869993166). The same frame now fails the smoke, and the real basemap
step still passes with `content pixels=262144`:

```text
    render-smoke: sentinel pixels left=0/262144 content pixels=23890 centre=(255,117,0,255)
    render-smoke: FAIL: basemap attached but content covers 23890 of 262144 px (9%); need 131072 (50%)
    render-smoke: FAIL
[basemap-gate] PASS: an off-frame basemap fails the smoke
```

Evidence for #2 (this box, JDK 21; `bash dev/g2/render/test/uri.sh`).
Before, the canary against the old `Uri` on `30ed6d0`: 10 of 46 checks
fail, among them:

```text
FAIL: fromFile round trip: /Users/m/Maps #2/tracks.sqlite (expected [/Users/m/Maps #2/tracks.sqlite], got [/Users/m/Maps ])
FAIL: fromFile has no query: /Users/m/what?/a.kml (expected [null], got [/a.kml])
FAIL: fromFile round trip: /Users/m/100%25 done/a.kml (expected [/Users/m/100%25 done/a.kml], got [/Users/m/100% done/a.kml])
FAIL: encode leaves Android's unreserved characters (expected [a%20b!~'()*-_.], got [a%20b%21%7E%27%28%29*-_.])
uri-canary: FAIL (10 check(s))
```

After, with the fix: 46 `PASS` lines and `uri-canary: PASS`.

Evidence for #3 (CI, render job, `gles-shim.sh` on ANGLE Metal).
Before: the canary alone on `7760aac`, old shim (dispatch run
42881840590):

```text
FAIL: glVertexAttribPointer rejects an array-backed Buffer (GL would keep a dangling pointer)
FAIL: glVertexAttribIPointer rejects an array-backed Buffer
PASS: glVertexAttribPointer accepts a direct Buffer
PASS: glVertexAttribPointer accepts a null Buffer
PASS: glBufferData still takes an array-backed Buffer (data is copied before the call returns)
PASS: no GL error raised
gles-shim-canary: FAIL (2 check(s))
```

After: with `bufferDirect`, on `c01d89f` (PR #90's render job, run
42882061813): all six `PASS`, `gles-shim-canary: PASS`, and the seven
engine render smokes after it still `PASS` — the engine passes only
direct buffers to these entry points.

Evidence for #4 (this box, JDK 21; `bash dev/g2/render/test/uri.sh`).
Before, seven new query checks against the old `Uri` on the canary
commit: one fails,

```text
FAIL: query value: '+' decodes to a space (expected [My Layer], got [My+Layer])
uri-canary: FAIL (1 check(s))
```

After, with the fix: 53 `PASS` lines and `uri-canary: PASS`. `%2B`
still reads back as a literal `+`, and `getQuery()` keeps `+` as it is:
only parameter values convert it, as on Android.

Evidence for #5 (this box). Before, the lint check alone on `00a039a`:

```text
[check-trap-exec] FAIL dev/g2/shell/run.sh: sets an EXIT trap and execs; the trap never fires
```

After: `[check-trap-exec] OK: no script execs past an EXIT trap`. The
two forms side by side in a scratch script (`mktemp -d`, `EXIT` trap,
then a command that exits 3): with `exec`, exit 3 and the directory is
left behind; without it, exit 3 and the directory is gone. The shell
itself needs a GUI session, so `make test-shell` on a dev Mac is the
end-to-end check.

Evidence for #6 (CI). Before: both canaries alone on `de21c83`
(dispatch run 42919313174). The shell traps for 14 of its 15 value
options; only `--classpath`, the one with a bounds check, passes:

```text
[shell-args] ok   --classpath
dev/g2/shell/test/args.sh: line 16:  1594 Trace/BPT trap: 5       "$BIN" "$opt" > /dev/null 2> "$ERR"
[shell-args] FAIL --lib: exit 133, expected 2 with '--lib needs a value'
[shell-args] FAIL --out: exit 133, expected 2 with '--out needs a value'
```

and all six `RenderSmoke` cases end in a stack trace:

```text
[render-args] FAIL --frames: exit 1, expected 2 with '--frames needs a value' and no stack trace
    Exception in thread "main" java.lang.ArrayIndexOutOfBoundsException: 9
[render-args] FAIL --frames many: exit 1, expected 2 with 'bad --frames' and no stack trace
    Exception in thread "main" java.lang.NumberFormatException: For input string: "many"
```

After: with the fixes, on `8be7765` (PR #93, run 42919519530):

```text
[shell-args] ok   --out
[shell-args] PASS: every value option reports a missing value
[render-args] ok   --frames many
[render-args] PASS: bad arguments end in usage, exit 2
```

Evidence for #8 (dev Mac, M5 Max, GUI session; `main` at `e51f14a`).
Before, a basemap that does not exist:

```text
$ bash dev/g2/shell/run.sh --basemap /nonexistent.mbtiles; echo "exit=$?"
window-app: no such basemap: /nonexistent.mbtiles
mactak-shell: poll → 2
mactak-shell: render failed — closing the window
exit=0
```

After, on branch `g2/shell-exit-code` (`9ddd87c`), same Mac,
`make test-shell; echo "exit=$?"`. The first leg renders and passes as
before and now reports its code, where it used to stop at `poll → 2`;
the second leg is the canary:

```text
mactak-shell: linger elapsed — asking the render thread to wind down
mactak-shell: poll → 2
mactak-shell: exiting with WindowApp's code 0
bash dev/g2/shell/test/exit-code.sh
    window-app: no such basemap: /nonexistent.mbtiles
    mactak-shell: render failed — closing the window
    mactak-shell: exiting with WindowApp's code 2
[shell-exit] PASS: a failed render exits 2
exit=0
```
