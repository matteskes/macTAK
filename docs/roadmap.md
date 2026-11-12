# Roadmap: ATAK-CIV → Native macOS (Pathway C)

Gate-gated plan. Each gate has: **objective → exit criteria (demo artifact) → fallback if it fails**. A failing gate is a decision point, not a dead end; the two branch points (G1, G2) have pre-analyzed alternates. Estimates assume the team shape in `feasibility-report.md`.

## G0 — Engine builds on macOS arm64 (the 2-week spike)

> **Status: G0 CLOSED 2026-11-02** — ~460 TUs compile and link into `libtakengine.dylib` (9.6 MB, Mach-O arm64) via the spike wrapper + 3-file GDAL-drift patch set, **and** `publishToMavenLocal` lands all five kernel Java modules (annotation/port/shared/engine/all 0.59.1) in mavenLocal on Zulu 8 arm64 (public-artifact android-port transplant; `-PuseTakRepo` restores upstream). Headless `dlopen` smoke passes. See `../dev/spike/g0/NOTES.md`.

**Objective:** Compile `takkernel/engine` C++ on macOS 26/27 arm64 using the in-tree `elseif(APPLE)` branch.

1. Tooling: Xcode current; CMake ≥ 3.25; Conan 1.59 (as pinned) *or* map deps to Homebrew/vcpkg.
2. Deps: build or substitute the `MacOSSources.cmake` set — `spatialite, gdal(2.4.4-mod), geos, proj, las, charset, z`; decide GLES provider stub for now (link placeholder).
3. `cmake -B build -DCMAKE_OSX_ARCHITECTURES=arm64 -S takkernel/engine/src/main/cpp` with the macOS branch active; fix compile errors (expect: C++ standard drift from 2016-era code, missing `macos-64` distfiles like MrSID → stub or omit raster drivers).
4. takkernel Java: `gradlew publishToMavenLocal -PkernelBuildTarget=java` on a macOS JVM (Java 8 language level; newer JVM runtime acceptable).

**Exit:** `libtakengine` (.dylib/.jnilib) + takkernel JARs produced on arm64. **Fallback:** x86_64-under-Rosetta build as interim target (gate passes with a documented perf penalty); if neither compiles within 3 weeks of effort, Pathway C is re-scored High-Risk (this is the single largest unknown).

## G1 — Headless engine + CoT round-trip (2–3 mo)

> **Status: DONE (2026-11-04).** M1 (2026-11-02): engine loads in-process from a Zulu 8 JVM via the JNI glue. M2 (2026-11-03): `dev/g1/headless/atak-headless --connect HOST:PORT` runs the commoncommo stack headless; CoT round-trip verified against FreeTAKServer and OpenTAKServer (two clients, marker + presence relayed both ways). M3 (2026-11-03): `atak-headless --layer FILE` opens GeoJSON/GPKG/KML/SHP through the native OGR provider into `PersistentDataSourceFeatureDataStore2` and reads them back via `FeatureDataStore2` — the offline-layer criterion, headless; four-format canary in CI. M4 (2026-11-04): one JVM loads engine + comms together; received CoT is persisted through the engine's `DatabaseImpl` JNI into a sqlite tracks DB (`--db`) and the latest fix per uid is printed on exit — the exit demo below, witnessed on OpenTAKServer over TCP and SSL (`--cert/--ca` from an ATAK data package) and hermetically in CI. **G1.5 follow-ups (2026-11-05, #27–#32):** `atak-headless --datapackage FILE` resolves an ATAK data package — CoT host:port from `preference.pref`'s `cot_streams`, the callsign, and the PKCS#12 pair — behind a hardened pure-JDK importer (XXE/Zip-Slip/size caps, bracketed IPv6 literals, exact `ssl`/`tls`/`tcp` proto-token match, cert temp dir cleaned on every exit); CI's `jvm-tests` job now compile-gates the launcher. See `../dev/g1/NOTES.md` §G1.5.

**Objective:** JVM process on macOS: engine loads, offline map layer opens, CoT in/out via commoncommo.

- Host = JVM (takkernel `java` target; `engine/src/jre` pattern). Comms via commoncommo JNI (or its ObjC bindings from Swift — decide here; JNI keeps one process, ObjC suits a split-process design later). **Decided: JNI, one process** — G1 M2 built the commo JNI stack headless; M4 loads engine + comms in one JVM, which is what lets received CoT persist through the engine's `DatabaseImpl` JNI into the tracks DB.
- Test: connect to FreeTAKServer (or `takproto`-aware peer), send/recv CoT, persist to the engine's tracks DB; `flighttactics/TAKTracker` as MIT-licensed protocol cross-reference.

*Pre-validated 2026-11-02 (see `pathway-a.md` §FTS round-trip): the same FreeTAKServer container + Mac-side wiring this gate's nightly job will reuse already streams CoT both ways with the reference client as witness (WinTAK presence relayed to an independent listener; injected markers delivered back). Known traps for the integration job: the `vigsecdrone/freetakserver` image swaps port roles (8087 plaintext / 8089 SSL), FTS registers a client only after its first message (send a handshake), and zombie client sockets accumulate — restart the container between runs. The fallback branch also has a second proof beyond TAKTracker: a ~150-line stdlib Python CoT client (`../dev/reference/tools/`) performed the same witnessed round-trip.*

**Exit:** CLI demo: `./atak-headless --connect fts.example:8087` streams positions both ways and plots them in-memory. **Fallback (branch):** if commoncommo-on-macOS drags, implement CoT transport directly (Swift `Network.framework` + `takcot` XSD + `takproto` protobufs, TAKTracker as reference) and treat engine-comms as optional — costs engine features (cert store, contact management) but unblocks the critical path.

## G2 — Map renders in a native macOS window (2–3 mo) — *branch point*

> **Status: M1 DONE (2026-11-04) — branch decided: H2.** ANGLE (EGL 1.5 + GL ES 3.0, Metal backend) fills the engine's GLES-stub link slot (`MACTAK_GLES=angle bash dev/g1/build-native.sh`); all 80 GL symbols the engine imports resolve against it (R2 retired). `GLMapView.render()` driven from a Zulu 8 JVM through a new `EglRenderContext` draws into an EGL pbuffer with zero GL errors at ~3–5 ms/frame (512², no layers) — `make test-render`. Three contract defects were ours, now patched: the G0 stub silently no-op'd libxml2; `renderer/GL.h` emitted desktop `#version 330` on macOS; `GLTerrainTile` enabled attribute `-1` on shader variants lacking it. **M2 (2026-11-04): first map content** — a GeoJSON `FeatureLayer3` (polygons, anti-aliased lines, labelled points) renders through the engine's Java-side renderers on ANGLE via a generated `android.opengl.GLES20/30` → ANGLE JNI shim and Java2D-backed `android.graphics`; `make test-render` writes the frame as PNG and CI uploads it. **M2.3 (2026-11-05): offline raster basemap** — a synthetic MBTiles graticule (generated offline by the gdal CLI, zoom 10–14) renders under the vector layer through `PersistentRasterDataStore` → `MobileImageryRasterLayer2` → `GLQuadTileNode4` on ANGLE; the coordinate labels line up with the GeoJSON geometry. Next (M3): window surface — `CAMetalLayer` in an `NSView` → `eglCreateWindowSurface`; host **decided 2026-11-05**: the Swift/AppKit shell launching the JVM in-process via `libjli` (`JNI_CreateJavaVM`) — chosen over the JVM-first window-in-glue variant on the total-effort ledger through G3 (`../dev/g2/NOTES.md`; both variants share the same thread topology, so the R4 experiment is identical); R4 (AppKit vs JVM threading) is decided there. **M3.0 (2026-11-06, #36): window surface proven** — `eglCreateWindowSurface` accepts a live `CAMetalLayer` on the staged Electron ANGLE pair: `make smoke-window` draws, reads back (zero GL errors, gated PPM artifact) and presents a 1024×768 window surface for 3 s (~30 fps), failing on 0 presented frames per the recorded #40 decision — F1's trigger never fired. M3.1–M3.4 (window natives → shell → loop/resize → gestures) remain; R4's verdict lands at M3.4. **G2.4 (real imagery)** follows, pulling two documented engine patches (`GLQuadTileNode4.resolveTexture` compositing with `uColor` on whatever program is current, integer vertex attributes fed through `glVertexAttribPointer`; the third, `GLMegaTexture::shareTile`'s comma-operator bug, is patched — it has no callers at the pin, so it never gated G2.4) and re-opening the `org.gdal` JNI for `GdalTileReader`. See `../dev/g2/NOTES.md`.
**M3.1 (2026-11-06, #49): window natives + dynamic-size context, exercised through a real window surface** — `RenderSmoke --window` renders into a bare off-screen `CAMetalLayer` host (no AppKit) and `--resize` drives a mid-run `drawableSize` change: ANGLE-Metal sizes a window surface once at creation and refuses a second surface on a live layer (`EGL_BAD_ALLOC`), so `adoptSurfaceSize` destroy-then-recreates; the harness shape is itself evidence for the shell model — AppKit needs the main thread and the `java` launcher's main is a spawned `pthread`, which a bare layer dodges, so CI runs the exercise as a gate (`make test-render-window`, presents counted, 0 failed). M3.2–M3.4 (shell → loop/resize → gestures) remain; R4's verdict lands at M3.4. **G2.4 (real imagery)** follows, pulling two documented engine patches (`GLQuadTileNode4.resolveTexture` compositing with `uColor` on whatever program is current — **patched 2026-11-07 (G2.4a)**, shipped as an engine shadow derived from the patch and drift-gated in CI; integer vertex attributes fed through `glVertexAttribPointer`; the third, `GLMegaTexture::shareTile`'s comma-operator bug, is patched — it has no callers at the pin, so it never gated G2.4) and re-opening the `org.gdal` JNI for `GdalTileReader`. See `../dev/g2/NOTES.md`.

**M3.2 (2026-11-07, #61): the shell — the JVM boots in-process, AppKit hosts the window** — `dev/g2/shell` (`jni_boot.c` dlopens `libjli` → `JNI_CreateJavaVM`; `main.swift` opens the `NSWindow` over its own `CAMetalLayer` and upcalls `WindowApp.start`, signatures cross-checked with `javap -s`) renders the M2/M3.1 stack into the shell's layer from the JVM's render thread, publishes frame-done, parks for the shell's `--linger`, tears down on its own thread at `stop()`, and the shell exits with `WindowApp`'s exit code — the shell never calls `DestroyJavaVM`, which would block on non-daemon threads and invert control. Two findings recorded in NOTES §M3.2: AWT must not initialize in a process that owns an `NSApplication` (`writePng` is a hand-rolled AWT-free PNG encoder now), and `.terminateLater` wedges the quit handshake — AppKit runs `-terminate:` in a private nested run-loop mode where the reply timer never fires, so the shell winds the render thread down first (bounded pump), then `.terminateNow`. Gate: `make test-shell` on the dev Mac (window opens, 5 frames, 0 failed presents, readback PNG, linger → stop → EXITED → exit 0); CI compiles the shell (`shell-compile`, macos-26 + Zulu 8 headers) — the run stays a dev-Mac gate, same split as M3.0. M3.3–M3.4 (loop/resize → gestures) remain; R4's verdict lands at M3.4. **G2.4 (real imagery)** follows — **b.0 done (2026-11-08):** the `org.gdal` SWIG bindings the engine's raster path needs (trap 17) now build against Homebrew's libgdal (`make gdal-java`, CI-gated), and the smoke found the GDAL 3 axis-order defect in `GdalLibrary`'s `EPSG_4326` before any render depended on it (trap #48); b.2 done (2026-11-09): the fix is an engine patch + shadows (`GdalLibrary.traditionalGisOrder`), proven on the engine's own `GdalLibrary.init` → `GdalDatasetProjection2` path (`make test-gdal-projection`, CI-gated); b.1 GeoTIFF through `GdalTileReader` remains — its blocker cleared b.1a (2026-11-09): `vsi_jfile.cpp` ported to GDAL 3's VSI interface, `GdalLibrary.init()` returns true and `/vsitakio/` reads a GeoTIFF (trap #50 closed). See `../dev/g2/NOTES.md`.

**Objective:** The engine's map view composites into a native macOS window.

- **Preferred (H2, native):** Swift/AppKit host, engine driven via JNI in-process or C++ API wrapped via Swift/C interop; render surface = **ANGLE on Metal** (ES 3 + EGL 1.5) occupying the engine's existing `GLES-stub` slot (`TE_GLES_VERSION=3` already set in `MacOSSources.cmake`). Evidence (2026-11-02): the shipped WinTAK itself renders through ANGLE/EGL — Pathway A gotcha #1: forcing ANGLE's D3D12 backend kills it while D3D11 works — so ANGLE-on-Metal mirrors the reference client's own desktop architecture, and the engine+ANGLE pairing (R2) is production-proven.
- **Fallback (H1, JVM):** Swing + JOGL host modeled on `engine/src/jre` (`JOGLRenderSurface`) — the TAKX approach on macOS; JOGL on macOS exposes legacy GL 4.1, sufficient for the engine's ES 2/3 feature set via its existing desktop path. Faster to first pixels, but ships a JVM in the product and weakens "native" fidelity.

**The rest of G2 — decided 2026-11-12:** M3.3 (loop, resize, Retina) → M3.4 (Apple Maps–style gestures through `InputBridge`; the R4 verdict) → G2.4 b.1 (GeoTIFF imagery) → G2.6 (elevation: a GeoTIFF DEM and DTED; elevation stays in G2) → the exit run. CI gates use synthetic gdal-generated fixtures; the exit run adds a hash-pinned clip of public-domain USGS data. "60 fps" means p95 frame time ≤ 16.7 ms with no dropped presents over a scripted 10 s pan/zoom/rotate on the dev Mac, full stack. The same run reports the longest GC pause, peak memory and cold-start time; M3.3 moves the JVM to generational ZGC. Gestures are tested in CI (`InputBridge` on the pbuffer path) and on the dev Mac (in-process `NSEvent` injection). See `../dev/g2/NOTES.md` "The rest of G2 — decided 2026-11-12".

**Exit:** Layered map (imagery + vector + elevation) pans/zooms at 60 fps in a window. Decision recorded: H1 vs H2 (or hybrid: native shell + headless engine process with shared-memory texture transport — evaluate if in-process JNI/ANGLE fights AppKit threading).

## G3 — Core client skeleton (2–3 mo)

Tracks/contacts list, map overlays (CoT markers, routes), chat (GeoChat), layer manager, coordinate tools; certificate/trust store UI (port `AtakCertificateDatabase` concept to Keychain). **Exit:** two Mac clients on one FTS server see each other's markers and chat live.

**Open before G3 (2026-11-11):** ~~which upstream version the app layer targets~~ settled: 5.5.1.10, the baseline since the re-pin below ([rebase-study-5.5.md](rebase-study-5.5.md)); ~~and whether ATAK's app code is reused on the JVM behind more Android stand-ins or rewritten in Swift~~ **decided 2026-11-12: rewritten in Swift**, package by package with the Java as the specification; the engine and commo stay as ported; Swift calls commo's C++ API directly, falling back to the existing JNI boundary if that proves challenging; Swift reaches the engine through a narrow JVM facade, with direct C++ calls only where C++ owns the data, and measured renderer ports to C++ where the exit run shows JVM overhead ([atak-feature-coverage.md](atak-feature-coverage.md) §The app-layer decision).

**2026-11-11 (#98): spike 1 of the rebase — the 5.5 engine builds.**
takkernel 8.30.5 with macTAK's patch series ported to 5.5 (34 patches at
`--fuzz=0`; three dropped as fixed upstream) compiles and links on
`macos-26` without 3D Tiles, 471 of 471 build steps
(`../dev/spike/g55/NOTES.md`). Remaining before the re-pin: JNI glue on
5.5, the render gates on 5.5, spike 2 (commo and its QUIC backend), then
the re-pin itself, roughly two to three weeks with 3D Tiles still out.

**2026-11-11: the re-pin — 5.5.1.10 is the baseline.** After the JNI,
render and commo steps (#106–#108) and the JDK 21 move (#109), every
`make` target and `ci.yml` check builds and tests
`TAK-Product-Center/atak-civ` @ `9f6893d` through `dev/g1` and `dev/g2`,
3D Tiles still out. The whole 5.5 stack runs in one `atak-headless` JVM
for the first time (offline layers, the CoT round-trip, TLS), commo's QUIC
is a required check (`make test-quic`), the kernel jars build from
source, macTAK's Java is off the APIs 5.5 deprecates, and JDK 8 is gone.
Remains: `:shared`'s unit tests (g55 trap 11), commo's QUIC failure cause
(trap 8), and 3D Tiles when it is needed.

## G4 — Data & import parity rung 1 (2–4 mo)

KML/KMZ, GPX, shapefile, GeoJSON import/export (GDAL-backed via the engine's `formats`/`db` layers); offline elevation (DTED/DEM via gdal/las stack); MRU/route tools. **Exit:** a workflow a WinTAK user performs daily works identically.

## G5 — First deployable core client (2–4 mo)

Code-signing/notarization, Keychain-based cert provisioning, auto-update, crash reporting (replace `libunwindstack-ndk`/`jnicrash` with macOS equivalent), GPL-3.0 source publication pipeline. **Exit:** notarized .app given to 5 external testers; 2-week field trial against FTS + TAK Server.

**G0–G5 total: ~12–18 months.**

## G6 — Parity ladder (ongoing, 3–5 yr to full ATAK-CIV parity)

Rungs, each independently demoable (highest-value first):

1. Map + tracks + chat + file import (G3–G5 scope)
2. Video (UAS): Android's `media3`/EXOPlayer surface → AVFoundation + engine video layer
3. Callsign-aware tooling: range/bearing, measure, geofences
4. External GPS / Bluetooth (CoreBluetooth replacing Android BT stack)
5. TAK Server-specific features (missions, data packages, subscriptions)
6. Plugin story — **explicitly out of scope**: ATAK's Android plugin SDK (`pluginsdk.zip`) produces APK-bound artifacts that cannot run natively; provide a macOS-native extension API instead (documented divergence)
7. Full tool-by-tool port of the long tail (`maps`, `widgets`, `importfiles/sort`, `routes`, `layers` packages — the 492K-LOC app tax)

Each rung re-estimates against upstream. The baseline is `TAK-Product-Center/atak-civ` 5.5.1.10 @ `9f6893d` since the 2026-11-11 re-pin (4.6.0.5 @ `889eee2` before it). Upstream has resumed: the public source now lives at `TAK-Product-Center/atak-civ` (5.5.1.10, December 2025), and store builds are 5.6 or later. **2026-11-11:** [rebase-study-5.5.md](rebase-study-5.5.md) measures the move to 5.5 and recommends rebasing in stages before G3.

Reference evidence exists (2026-11-02): a full-display capture of the WinTAK golden session plus a repeatable in-guest capture harness (`pathway-a.md` §FTS round-trip; harness in `../dev/reference/tools/`) — G6 parity checklists compare against it. Captures stay local per `ci-qa.md` §3: GOTS-derived artifacts never enter the public repo.

## Risk → gate mapping

| Risk | First stressed at | Mitigation if red |
|---|---|---|
| R1 engine won't compile arm64 | G0 | Rosetta x86_64 interim; re-score program |
| R2 ANGLE≠GLES-stub contract mismatch | G2 | **Retired 2026-11-04** (G2 M1): engine links + renders on ANGLE/Metal; the mismatches found were engine-side (GLSL version string, attribute `-1`) and are patched |
| R3 gdal-2.4.4-mod won't build arm64 | G0 | Modern GDAL via Homebrew behind engine's `db`/`raster` SPIs |
| R5 takRepo artifact credentials required | G0/G1 | Substitute from source builds (as CI does) |
| R4 AppKit/JVM threading conflicts | G2 | Split-process design (headless engine + native UI over IPC). Decision experiment is G2 M3 — host committed 2026-11-05 (Swift shell + `libjli`, in-process); verdict lands in `../dev/g2/NOTES.md` and this cell |
| R6 GPL obligations | G5 | Publish at first external release; legal review at G0 kickoff |
| R7 scripted UX-parity capture is fragile (WinTAK UI wedge; ~4 px text at guest scale 5120×2600→1280×650) | G6 | Protocol-level CoT witnesses + config-driven setup (`Config.xml`); capture from clones, restart between scripted passes (`pathway-a.md` gotchas #4–5) |
| R8 upstream moved on: public 5.5 source with new native dependencies (cesium-native, ngtcp2/quictls) | before G3 | **Retired 2026-11-11**: rebased in stages and re-pinned to 5.5.1.10 (engine, commo with QUIC on ngtcp2/`openssl@3`, JDK 21); cesium-native waits until 3D Tiles is needed ([rebase-study-5.5.md](rebase-study-5.5.md), `../dev/spike/g55/NOTES.md`) |

## Where the work lives now

The G0 recipe below is the historical record (see also `dev/spike/g0/NOTES.md`, which documents the wrapper it was consolidated into). G0–G2 work is driven by the Makefile against the dev harnesses:

```sh
git submodule update --init --recursive     # stl-soft + khronos registries (all public)
make hooks                                  # install the pre-commit gate chain
make build                                  # engine + JNI glue + commo, stub GLES (CI's mode)
make build-angle                            # stage ANGLE, rebuild with it in the GLES slot
make test                                   # load smoke: engine + JNI in one JVM
make test-roundtrip                         # CoT round-trip (FTS / OpenTAKServer / fake-cot-server)
make test-render                            # G2 render smoke: bare + GeoJSON layer + MBTiles basemap
make smoke-window                           # G2 M3.0 window-surface smoke (manual: opens a window ~3 s)
make test-render-window                     # G2 M3.1 window-surface exercise (off-screen; CI runs it too)
make test-shell                             # G2 M3.2 shell gate (manual: opens a window, ~5 s)
```

G0 spike recipe (historical — the current build path is `make build`):

```sh
cd macTAK/src
git submodule update --init --recursive        # stl-soft + khronos registries (all public)
# deps via Homebrew for spike: proj geos gdal libspatialite laszip
export CMAKE_OSX_ARCHITECTURES=arm64
cmake -S takkernel/engine/src/main/cpp -B /tmp/takeng -DCMAKE_BUILD_TYPE=RelWithDebInfo
# expect: configures via MacOSSources.cmake; iterate on missing distfiles (MrSID etc.)
cd takkernel && ../../gradlew publishToMavenLocal -PkernelBuildTarget=java
```

CI & QA infrastructure (what runs, where, and why): see `ci-qa.md`. Tier 0/1 (`lint`, `native-engine`, `jvm-tests`) landed 2026-11-02 and gate every PR; `native-engine` is R1's scored signal. The 2026-11-05 ops traps (ANGLE release-CDN 504 retry, hosted-runner pool contention) are recorded in `dev/g2/NOTES.md`. Tier 2's `engine-integration` wiring is pre-validated on the dev Mac (FreeTAKServer container + CoT proxy bridge, `pathway-a.md` §FTS round-trip).
