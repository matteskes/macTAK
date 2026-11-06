# dev/g2 — G2: map renders in a native macOS window (ANGLE on Metal)

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
  - `GLQuadTileNode4.resolveTexture` composites child textures with
    `uColor` set on whatever program happens to be current (G2.3
    known-benign noise) — bind `core.shader.handle` before compositing.
    Android drivers hide it today; ANGLE surfaces it.
  - `GLBatchGeometryRenderer3/4` feed `in int` attributes through
    `glVertexAttribPointer` (trap 12's pattern, already redirected in the
    shim) — patch when the native line renderer is on the path.
  Real imagery also re-opens trap 17 (the `org.gdal` JNI for
  `GdalTileReader` once a GeoTIFF raster is on the path).
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
- KHR_debug `glUniform4f: Uniform size does not match uniform method`,
  once per composited tile, from `GLQuadTileNode4.resolveTexture`
  (child-texture FBO compositing). That path runs from a queued render-thread
  event, never calls `glUseProgram`, and sets `core.shader.uColor` on
  **whatever program happens to be current** — a latent upstream bug that
  Android drivers don't report. The composite is discarded as soon as the
  tile's own read lands, so the picture is unaffected; it also happens
  outside `view.render()`, which is why the frame-loop `glGetError` count
  stays 0. Fix (bind `core.shader.handle` before compositing) belongs in an
  engine patch once the tile-sharing paths are exercised with real imagery.

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
output. Candidate follow-up: a one-line re-sign in `build-native.sh`'s
staging step (deliberately left out of #49). Diagnosis shortcut: a
Killed: 9 with a passing `codesign -v` means re-sign the staged pair
before re-bisecting anything.
