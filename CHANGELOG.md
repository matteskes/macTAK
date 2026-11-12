# Changelog

All notable changes to macTAK. Versions follow the roadmap gates
([docs/roadmap.md](docs/roadmap.md)): each completed gate bumps the minor
version — 0.1.0 G0, 0.2.0 G1, 0.3.0 G2 — and dates are the merge dates.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- G2.4 b.1, GeoTIFF imagery (`dev/g2/NOTES.md` §G2.4 b.1): GeoTIFFs (and
  other GDAL rasters) render through the engine's GDAL path in the render
  smoke and the live window. The render path draws GDAL datasets with
  `DatasetRasterLayer2` beside the tileset layer (`BasemapLayers`), and
  registers a reader that turns their `file://` URIs into the paths
  `GdalTileReader` takes (`GdalImagery`). New engine patch
  `gdaltilereader-stock-gdal-bindings.patch` (41 in the series):
  `GdalTileReader` called TAK-GDAL-fork-only APIs the stock bindings lack.
  New fixture `fixtures/make-imagery.sh` (synthetic, UTM 10N, tiled, with
  overviews), `RenderSmoke --expect LAT,LON,RRGGBB`, and gate
  `render/test/geotiff.sh` (make test-render, CI): the right colour over
  known ground points; off-frame and misregistered imagery fail. The exit
  run's real data is chosen: NAIP 2024 (60 cm) and USGS 3DEP 1/3″, a 4 km
  window over Golden Gate Park to Twin Peaks, pinned by pixel checksums.
- G2 M3.4, gestures (`dev/g2/NOTES.md` §M3.4): the map takes Apple
  Maps–style input. The shell's AppKit handlers send each event across JNI
  (`WindowApp.input`) to the new `InputBridge`, which applies it on the
  render thread through the engine's `CameraController.Interactive`: drag
  and trackpad scroll pan; wheel, pinch and double-click zoom about the
  pointer; the rotate gesture and ⌥-drag turn; ⌥-drag up tilts. New gates:
  `render/test/input-bridge.sh` (CI, `make test-render`) checks where each
  gesture lands on screen; `shell/test/gestures.sh` (`make test-shell`)
  posts real input events through AppKit and checks each moved the camera
  by the exact amount. R4 (AppKit/JVM threading) is retired: the
  in-process host holds.
- G2 M3.3, the live window (`dev/g2/NOTES.md` §M3.3): after the first
  frame `WindowApp` keeps rendering until the shell stops it, applies live
  resizes (the shell sets the layer's drawableSize; the render thread
  recreates the EGL surface), renders at the display's backing scale
  (dpi = 72 × scale), pauses while occluded, honours `requestRefresh` /
  `setFrameRate` / continuous rendering, and logs frame times (present
  interval and render CPU time). The shell's JVM runs generational ZGC.
  `make test-shell` gains `shell/test/live.sh`: a scripted pan with a
  resize halfway, gated on presents, GL errors, the resize, content at
  the new size and decodable PNGs. Dev Mac: 60.2 fps, 0 dropped frames,
  render CPU p95 2.5 ms.
- A docs site: the README, CONTRIBUTING, CHANGELOG, the program documents
  in `docs/` and the engineering notes under `dev/` as one browsable site
  on GitHub Pages, with a sidebar, search and a table of contents on
  every page (`dev/docs-site/`, `make docs-site`, `docs-site.yml`). The
  pages are the repo's own files, built in MkDocs strict mode, so a
  broken link or anchor between them fails the PR; links to scripts and
  source point at GitHub. MkDocs and Material install from a hash-pinned
  requirements file.
- The rest of G2 is planned (`dev/g2/NOTES.md` "The rest of G2 — decided
  2026-11-12", roadmap G2): M3.3 → M3.4 (the R4 verdict) → G2.4 b.1
  imagery → G2.6 elevation (kept in G2) → the exit run; synthetic
  fixtures in CI plus a public-domain real-data clip for the exit run; the
  60 fps exit as zero dropped frames (a present over 25 ms) on the dev
  Mac, p95 reported (restated after M3.3, trap #61); Apple Maps–style
  gestures, tested in CI and on the dev Mac; G2.5 #7's teardown fix folds
  into M3.3.
- ATAK's app layer will be rewritten in Swift, package by package with the
  Java as the specification (`docs/atak-feature-coverage.md` §The
  app-layer decision; roadmap "Open before G3"). The engine and commo stay
  as ported; the Android stand-ins stay scoped to the render path. Swift
  calls commo's C++ API directly, falling back to the existing JNI
  boundary if that proves challenging. Swift reaches the engine through a
  narrow JVM facade, with direct C++ calls only where C++ owns the data;
  Swift map items become engine features. G2's exit run also reports GC
  pauses, peak memory and cold start, and M3.3 runs generational ZGC.
- The roadmap's G6 parity ladder gains rung 8, a native engine with no
  Java: the JVM leaves the shipped app after the application stands up
  (G3–G5), as the engine's Java renderers and layer code move to C++ one
  at a time in the order measurements point to.
- `make test-quic` gains a `peer` leg (`QuicPeerTest`): two commo
  instances with no server; B finds A from A's SA multicast on `lo0` and
  delivers a marker to A's QUIC inbound (`dev/g1/NOTES.md` G1.18). The
  leg fails with `patches/commo/0005-udpsocket-connected-sendto-macos`
  taken out. The interface-scanner bug the 5.5 spike reported against
  peer QUIC (`lo0` read as `127.51.68.120`) does not reproduce: peer
  QUIC works on `lo0` and `en0`, in NAME and PHYS_ADDR modes.
- Spike 2, 5.5 commo (`dev/spike/g55/`, NOTES §Commo): 5.5's
  commoncommo builds on macOS with its now-mandatory QUIC on ngtcp2's
  `ossl` backend, OpenSSL 3.5's own QUIC TLS API, over the same
  Homebrew `openssl@3` the rest of commo uses. quictls is OpenSSL 3.0,
  past end of life since 2026-09-07, and Homebrew's ngtcp2 links
  `openssl@4`. `commo.sh` checks six things, all green:
  - ngtcp2 1.26.0 builds against `openssl@3` (sha256 cross-checked
    with Homebrew's formula);
  - 5.5 commo builds through `dev/g1/build-commo.sh`, which gains
    opt-in `MACTAK_COMMO_*` overrides;
  - one OpenSSL runtime is linked;
  - streaming QUIC against an aioquic `takstream` stand-in: the
    handshake completes and markers arrive, and a clientAuth-only
    impostor is refused with `CONN_SSL_PEER_CERT_NOT_TRUSTED`, so
    security fix #1 holds on QUIC;
  - `tls-purpose.sh`;
  - the two-client CoT round-trip.

  Five commo patches:
  - the two G1 patches, ported;
  - `0003-quic-ossl-backend`;
  - `0004-platform-socket-cloexec-macos` (`SOCK_CLOEXEC` is Linux-only);
  - `0005-udpsocket-connected-sendto-macos`: BSD's `sendto` returns
    `EISCONN` on a connected UDP socket, so no QUIC packet left.

  Also found: commo's interface scanner misreads `lo0` on macOS (same
  code in 4.6), which blocks peer-to-peer QUIC discovery; and 5.5
  deprecates the `addStreamingInterface` overload `HeadlessCLI` uses
  (`atak-headless` gains opt-in `MACTAK_HEADLESS_CLASSES` and
  `MACTAK_JAVAC_LINT`). `spike-55.yml` gains a commo job. Trap 8 in
  `dev/spike/g55/NOTES.md` (commo hides the cause of a QUIC failure)
  stays open, with the patch that would close it described there.

- Spike 1, render step (`dev/spike/g55/`, NOTES §Render gates): the G2
  render gates pass on the 5.5 build linked against ANGLE/Metal. These
  are the same nine steps as `ci.yml`'s `render-angle` job, from GDAL
  georeferencing to the CAMetalLayer window surface, each with
  `glErrors=0` and `KHR_debug` on. `render.sh` runs the existing gate
  scripts unchanged: `dev/g2/render/env.sh` gains a `MACTAK_RENDER_ENV`
  hook (inert when unset) that hands it to `render-env.sh` (JDK 21, the
  5.5 jars, engine shadows regenerated from the 5.5 patches).
  `build-engine.sh` gains `G55_GLES=angle` and stages a signed
  `build/dist`. New patch `antialiased-lines-pattern-uint`: 5.5's
  anti-aliased line shader declared `in int a_pattern` but is fed
  unsigned shorts, so Metal refused every line draw
  (`GL_INVALID_OPERATION`); the series is now 38 patches.
  `GdalProjectionSmoke` accepts exactly two pixel conventions for the
  image's SE corner, 4.6's `[0, w]` (SE `(w, h)`) and 5.5's addressable
  `[0, w-1]` (SE `(w-1, h-1)`), and requires the centre at exactly half
  of it, so 4.6 still reads exactly (32, 32). `GLBatchGeometryRenderer4` needs no attribute
  guards. The steps also showed that 5.5 deprecates the
  `FeatureDataStore` APIs `LayerStore` uses, and that JDK 21's javac
  adds a `this-escape` lint.

- Spike 1, JNI step (`dev/spike/g55/`, NOTES §JNI glue): the 5.5 JNI
  glue builds, loads in a JVM and passes G1's JNI tests. The G1 load
  canary returns 42 through Java → glue → C++ → sqlite on JDK 21, and
  `dev/g1/jni-tests` pass in both modes. `kernel/build-kernel-jars.sh`
  builds the takkernel 8.30.5 jars from public sources only (a 5.5
  version of G0's Gradle patch, JOGL from jogamp.org, an `android-port`
  substitute rebuilt with one more stub) and regenerates the 116
  `javac -h` headers the 5.5 glue includes, which are committed in
  `jni-include/` and checked for drift in CI. Three new patches bring
  the series to 37:
  - `jsceneinfofactory-las-optional`: LAS behind `LAS_ENABLED`.
  - `common-managedlogger-guards`: 5.5's `JNI_OnLoad` crashed the JVM
    when `coremap.log.Log` could not load.
  - `jni-class-inits-new-in-55`: guards for the `HeightmapStrategy`,
    `HeightmapParams` and `FeatureDefinition` lookups.

  `spike-55.yml` now runs the jar build, the canary and the tests. Traps
  in `dev/spike/g55/NOTES.md`: 5 (`java_home -v N` falls back to the
  default JDK), 6 (the android-port substitute shadows kernel classes)
  and 7 (a missing slf4j crashed `JNI_OnLoad`, guarded by
  `common-managedlogger-guards.patch`). The 5.5 desktop jars are Java 11
  bytecode, so macTAK moves to JDK 21 in its own PR before the re-pin.

- Spike 1 of the 5.5 rebase (`dev/spike/g55/`, record in its `NOTES.md`):
  the 5.5 engine (takkernel 8.30.5) compiles and links on macOS arm64
  without 3D Tiles, 471 of 471 build steps on `macos-26`. 5.5 also
  compiles the GLTF and ASSIMP readers on every platform and adds an MS
  Access reader and libcurl, so the build takes tinygltf and
  tinygltfloader from upstream's own tree and assimp, mdbtools, glib and
  curl from Homebrew. macTAK's 37 engine patches ported to `TAK-Product-Center/atak-civ`
  5.5.1.10 as a 34-patch series that applies at `--fuzz=0` (17
  unchanged, 1 refreshed, 16 hand-ported; `cpp17-legacy-headers`,
  `megatexture-sharetile-comma-operator` and `terraintile-ecef-ge`
  dropped as fixed upstream). `refresh-patches.py` sorts a series
  against a new tree and accepts a fuzzed hunk only when its context
  survives; `build-engine.sh` builds the 5.5 engine without 3D Tiles
  (`formats/c3dt`) under `ninja -k 0` and lists every failing source;
  `.github/workflows/spike-55.yml` runs it on `macos-26` (not a
  required check). The port found that 5.5's own fix for the
  `GLMegaTexture` use-after-free (G2 trap 10) hangs once a tile is
  shared, so the 5.5 series keeps macTAK's version.

- `docs/atak-feature-coverage.md`: ATAK-CIV's feature set at the 4.6 pin
  mapped to what macTAK supports today (working, in the engine but unwired,
  to build, or platform-bound), with the app-layer numbers behind the open
  reuse-or-rewrite decision (1,781 files, 70% importing Android APIs, 33%
  Android UI).
- `docs/rebase-study-5.5.md`: the measured cost of moving the upstream
  baseline from `889eee2` (4.6.0.5) to the public
  `TAK-Product-Center/atak-civ` 5.5.1.10. Engine 0.59.1 → 8.30.5; new
  native dependencies cesium-native and draco (not wired for macOS
  upstream) and ngtcp2/quictls in commo; of the 37 engine patches, 17
  apply cleanly, 9 with fuzz and 11 fail (2 because upstream fixed the
  same bug); the commo TLS server-purpose patch (G1 security #1) still
  applies and is still needed. Recommends rebasing in stages before G3.
  (Spike 1 corrected the patch counts: the fuzz-3 dry-runs misplaced
  hunks, and `glbatchshaders-dead-store` is not upstream.)
  The roadmap (G3, G6, risk R8), the pathway-c risk register (R7) and the
  CONTRIBUTING reading order point to both docs.

- Clean Code skills for contributors and agents (`.claude/skills/clean-code*`):
  an entry-point skill that sets scope (code macTAK owns; never `src/` or
  generated output; inside engine patches, only the added lines) and
  precedence (CONTRIBUTING wins), plus nine topic skills adapted from the
  *Clean Code* summary gist: design, understandability, naming, functions,
  comments, source structure, objects/data, tests, smells. The skills
  reconcile the gist with house style: comments keep the why at patch
  sites, tests keep the `check()` canary style as one behavior per
  check, and the boy-scout rule never widens a focused PR. Examples come
  from this repo.
- M3.2 shell (`dev/g2/shell/`): the Swift/AppKit host — `jni_boot.c` finds
  `libjli` and boots the JVM in-process (`JNI_CreateJavaVM`), `main.swift`
  opens an `NSWindow` over its own `CAMetalLayer` and upcalls
  `mactak.render.WindowApp.start`; the JVM's render thread draws the
  M2/M3.1 stack into the shell's layer (ANGLE on Metal), publishes
  frame-done, parks for the shell's `--linger`, and tears down on its own
  thread at `stop()` before the shell exits with its exit code. The frame
  write uses a hand-rolled AWT-free PNG encoder — AWT must not initialize
  inside a process that owns an `NSApplication` (`dev/g2/NOTES.md` #43).
- `make build-shell` (compile-only, CI) and `make test-shell` (the
  dev-Mac GUI gate: window opens, 5 frames present, readback PNG,
  linger → stop → EXITED → exit 0); `shell/run.sh` shares
  `render/env.sh` with the render smoke so both build the same classes.
- CI: `shell-compile` job (macos-26, Zulu 8 headers) compiles the shell;
  the run stays a dev-Mac gate like M3.0's smoke-window split.
- Wave 5/6 reference tooling (`dev/g1/tools/wave5/`, `dev/g1/tools/wave6/`;
  not a CI gate): the audit and patch-generation/verification scripts
  behind the two JNI hygiene waves, parameterized off their `/tmp` scratch
  paths (`G1_REPO`, `G1_STAGING`) so a fresh clone plus the pinned `src/`
  tree (CONTRIBUTING.md) reproduces them — the wave-5 roster audit
  (`audit_roster.py`, `residuals.py`), patch regeneration + replay
  verification (each wave's `gen_patches.py`), the wave-6 class-init audit
  (`class_init_audit.py`) and guard-sweep editors (`guard_inits.py`,
  `fix_inline.py`), and `stage_baseline.py`, which rebuilds both wave-6
  staging trees from the repo alone (pristine + gdal-drift + committed
  patches). Validated by byte-rebuild: both trees and every regenerated
  patch come back byte-identical (`dev/g1/tools/README.md`).
- G2.4 b.0 — the `org.gdal` Java bindings (trap 17): `make gdal-java`
  (`dev/g2/fetch-gdal-java.sh`) generates the GDAL SWIG Java bindings from
  the sha256-pinned OSGeo release tarball matching `gdal-config --version`
  and links `libgdalalljni.dylib` against the same Homebrew `libgdal` the
  engine dylib links (install names asserted equal — one GDAL instance in
  the process); `gdal.jar` via `javac -source 8`, adhoc-signed,
  `PROVENANCE.txt`. `smoke/GdalJavaSmoke` proves load + version match,
  GTiff create/write/reopen/read, and records the GDAL 3 axis-order
  verdict for the engine's `SpatialReference` construction (trap #48,
  `dev/g2/NOTES.md` §G2.4b): it flips — `GdalLibrary` needs
  `OAMS_TRADITIONAL_GIS_ORDER` (b.2). Runs in CI's `render-angle` job;
  Brewfile + lock gain `swig`.
- G2.4 b.2 — `make test-gdal-projection` (`dev/g2/render/run-gdal-projection.sh`,
  `GdalProjectionSmoke`): the engine's own `GdalLibrary.init()` +
  `GdalDatasetProjection2.getInstance` on a GeoTIFF, GDAL 3, with the
  axis-order patch in effect; pixel ↔ ground round-trips exactly. CI
  `render-angle` runs it after `gdal-java`. `make check-engine-shadows`
  now handles one patch spanning several shadows.
- G1.9 JNI guard/behavior canary (`dev/g1/jni-tests/`; canary 3/4 of
  `make build`, standalone via `make test-jni`): the wave-5/6 JNI
  hygiene guards run against a real desktop JVM instead of static
  verification. Guards mode boots a JVM in-process from `libjli` with
  an empty classpath — every class-init failure must bail neutrally
  (TE_Err / 0 / 0.f, pristine JNIEnv) and `JNI_OnLoad` must fail with
  `JNI_ERR`, not crash (7 pins). Kernel mode runs the Java-backed
  `IOProviderFactory` proxy under the `java` launcher over the takkernel
  jars — real files through the fixed proxy (6 pins). Skips (exit 0)
  without a JDK 8; CI's native job installs Zulu 8 and uploads
  `takengine-jni-guards.xml` + `takengine-jni-kernel.xml`.

### Changed

- `make test-kernel` runs takkernel's `:shared` tests again, beside
  `:port` (`dev/g1/NOTES.md` G1.15; closes `dev/spike/g55/NOTES.md`
  trap 11): 26 + 220 tests, 0 failures. `dev/g1/kernel/kernel-tests.gradle`
  (was `port-tests.gradle`) leaves `:shared`'s desktop MIL-STD-2525 glue,
  which needs the TAK-artifactory renderer, out of the compile and its 67
  tests out of the run, and excludes `ToolbarItemTest` (`Bitmap` →
  `Stub!` on the compile-only android-port substitute).
- **The re-pin: macTAK's upstream baseline is ATAK-CIV 5.5.1.10**
  (`TAK-Product-Center/atak-civ` @ `9f6893d`, takkernel 8.30.5), replacing
  4.6.0.5 (`889eee2`); 3D Tiles stays out. `dev/spike/g55/NOTES.md` is the
  record (State: re-pin, traps 10–13).
  - Engine: `build-native.sh` builds 5.5 (tinygltf from upstream's LFS
    tarball, assimp/mdbtools/glib/curl, Ninja `-k 0` with
    `summarize-build.py`); `dev/g1/patches` is the 38-patch 5.5 series;
    `dev/g1/jni-include` the 116 `javac -h` headers (`gen-jni-headers.sh`
    goes). Two stale upstream tessellation tests are excluded by name
    (trap 10).
  - Kernel jars build from `src/` (`dev/g1/kernel/build-kernel-jars.sh`,
    `make kernel-jars`) into `dev/g1/kernel-dist`, ordered by
    `dev/g1/kernel/classpath.sh`; the 0.59.1 transplants and `slf4j-api`
    go. `make test-kernel` runs takkernel's `:port` tests; `:shared` does
    not compile from public sources at 5.5 and is open (trap 11).
  - Commo: the 5-patch 5.5 series, QUIC on ngtcp2's `ossl` backend
    (`dev/g1/fetch-ngtcp2.sh`), JNI headers from `javac -h`;
    `make test-quic` with aioquic `--require-hashes`.
  - Java: `LayerStore` on `PersistentDataSourceFeatureDataStore3`,
    `FeatureLayer3` over `FeatureDataStore4`, `HeadlessCLI` on the
    `StreamingTransport` overload; `-Xlint:all -Werror`, no relaxations.
    `atak-headless` recompiles when a jar changes (trap 12).
  - Render: `dev/g2/render/env.sh` regenerates the engine shadows from
    `src/`; `engine-shadows/` and `make check-engine-shadows` go.
  - JDK 21 only (`dev/jdk.sh`); CI checks out the 5.5 tree sparse, builds
    the kernel jars, and renames the JVM job "JVM tests (macOS arm64)";
    `spike-55.yml` goes. `.markdownlint-cli2.jsonc` honours `.gitignore`
    (trap 13).
- atak-headless's outgoing CoT carries `access='Undefined'` on both its
  events, presence and marker (`CotXml.java`). MIL-STD-6090 requires the
  attribute, and 5.5's `takproto/cotevent.proto` asks new clients to
  populate it on every outgoing message (`docs/rebase-study-5.5.md`,
  "Finding independent of the rebase"). `CotEventSelfTest` checks both
  events; the hermetic round-trip shows commo relays it.
- macTAK runs on JDK 21 (`dev/spike/g55/NOTES.md` §State, JDK 21; the
  #99 review's decision). Every JVM macTAK starts, and the `javac` for
  its own Java (`--release 21`), use JDK 21: the canaries,
  `atak-headless` and its tests, `jni-tests`, the render harness, the
  GDAL bindings and the Swift shell. JDK 8 stays a 4.6 build tool until
  the 5.5 re-pin, for upstream's Gradle 6.9.1 and `javah`. New
  `dev/jdk.sh` finds both by version (`MACTAK_JDK21_HOME`,
  `MACTAK_JDK8_HOME`); CI installs both where 4.6 tools run. javac 21's
  `this-escape` lint fixed in the `Matrix`, `Paint` and `Canvas`
  stand-ins. g55 trap 9: the shell booted an inherited JDK 8
  `JAVA_HOME`, now guarded in `shell/run.sh`.
- `CONTRIBUTING.md`'s rebase section allows a 5.5 run to reuse a G1/G2
  gate through an opt-in `MACTAK_*` override in the 4.6 script (unset, no
  change; documented in the script's header), rather than a copy under
  `dev/spike/g55/`, so both versions run one copy of each gate.
- The 5.5 rebase follows house style (docs only). `CONTRIBUTING.md` has a
  "Rebase work (4.6 → 5.5), until the re-pin" section that says where 5.5
  patches, harness changes and jars land, that a 4.6 patch fix lands in
  both series, that 5.5 shadows need a drift gate, and how branches, CI
  (`spike-55.yml`) and the g55 trap lineage work; its reading order and CI
  table add `dev/spike/g55/NOTES.md`, `spike-55.yml` and
  `ots-profile-drift.yml`. `dev/spike/g55/NOTES.md` opens with a dated
  State section. `docs/rebase-study-5.5.md`'s patch table now gives
  spike 1's measured port (17 unchanged, 1 refreshed, 7 hand-ported,
  9 reworked, 3 upstream) instead of the `--fuzz=3` dry-run (g55 traps
  1–2). The roadmap has spike 1's dated paragraph, `docs/ci-qa.md` an
  as-landed note for `spike-55.yml`, and the README lists both 2026-11-11
  docs.

### Fixed

- `dev/g2/render/env.sh` rebuilt the render classes only when an input was
  newer than them, so deleting a patch left its patched class in place; it
  now also rebuilds when the set of sources and patches changes (G2 trap
  #70).
- The Swift shell's PNG artifacts never decoded since M3.2: the AWT-free
  writer left the zlib stream unframed (no `IDAT` chunk). Fixed, and the
  live leg now decodes its PNGs (`dev/g2/NOTES.md` trap #59).
- `WindowApp.teardown` destroys EGL whenever it was initialized, also when
  a run fails before the render context exists (G2.5 #7, its teardown
  part).
- `ManagedFeatureDefinition`'s consumers no longer call through the NULL
  method IDs a failed class init leaves (`dev/g1/NOTES.md` G1.17). New
  `managedfeaturedefinition-consumer-guards.patch`: they return `TE_Err`
  or upstream's default encoding. `make test-jni` pins it and the two 5.5
  JNI guard patches: 4 guards-mode tests on a Java-backed definition, and
  a new noslf4j leg (the kernel jars without `slf4j-api`) for
  `common-managedlogger-guards`. Each pin fails with its patch taken out.
- Point icons draw on the map (`dev/g2/NOTES.md` §Asset icons). The render
  path's Android context now serves `asset:` URIs from the classpath,
  where takkernel's desktop jar packages them (`ClasspathAssets`); before,
  every icon load failed and the engine retried on a new thread each
  frame. With icons loading, the point renderer's desktop-GL state raised
  `GL_INVALID_ENUM` on ANGLE every frame: new engine patch
  `points-es-state-desktop-only.patch` (40 in the series). New canary
  `render/test/asset-icons.sh` (make test-render, CI) fails on any
  unresolved `asset:` URI.
- commo names a failed QUIC handshake's cause in its log, e.g. `quic IO
  error during handshake: recvfrom failed: Connection refused (errno 61)`
  instead of the bare first half (`dev/g1/NOTES.md` G1.16; closes
  `dev/spike/g55/NOTES.md` trap 8). New
  `patches/commo/0006-quic-socket-error-cause.patch`: `UdpSocket`'s
  `sendto`/`recvfrom` failures carry their errno, and the QUIC handshake's
  rethrow keeps it. `make test-quic` gains a `cause` leg (a closed loopback
  port) that fails without the patch.
- The Brewfile lists the spike's Homebrew packages (`ninja`, `mdbtools`,
  `glib`, `assimp`, from `spike-55.yml`), so they are in the lock and
  the OSV scan; `supply-chain.yml` now runs on any workflow change,
  since its drift step reads them all (`dev/spike/g55/NOTES.md` trap 4).
- `grep -q` at the end of a pipe under `pipefail` now has a guard (G1
  trap 2, G2 trap 8, `dev/spike/g55/NOTES.md` trap 3): grep quits on the
  first match, the writer takes SIGPIPE, and the match reads as a
  failure. `dev/check-pipefail-grep.sh` (`make lint`, CI's lint job)
  fails any such script under `dev/`; it found four, now fixed by
  capturing first: `dev/g2/fetch-angle.sh` (two `lipo -info` checks and
  the `otool -L` Metal check, part of G2.5 finding #7) and the commo
  canary in `dev/g1/build-commo.sh`. `dev/check-transplants.sh` and the
  pre-commit hook also cover `dev/spike/g55/transplants/`, ready for the
  rebase's 5.5 jars.
- The Swift shell exits with the render's exit code (`dev/g2/NOTES.md`
  §G2.5, trap #56, G2 correctness audit #8). It exited 0 on every run:
  AppKit's `terminate` ends the process itself, so the lines after
  `app.run()` that read `WindowApp`'s code never ran, and a failed
  render, a missing basemap and an EGL failure all read as success.
  The shell now exits from `applicationWillTerminate` with that code.
  `dev/g2/shell/test/exit-code.sh`, the new second leg of
  `make test-shell`, requires exit 2 for a basemap that does not exist.

- A missing or malformed option value is a usage error, exit 2
  (`dev/g2/NOTES.md` §G2.5, trap #55, G2 correctness audit #6). The
  Swift shell crashed in an array-index trap when a value option came
  last (`mactak-shell --out`), and `RenderSmoke` ended in a Java stack
  trace and exit 1 for the same input or for a non-number. Both now
  print `<option> needs a value` (or `bad <option> <value>`) and exit 2.
  `dev/g2/shell/test/args.sh` and `dev/g2/render/test/args.sh` pin it in
  CI.

- `dev/g2/shell/run.sh` removes its scratch `MACTAK_HOME` again
  (`dev/g2/NOTES.md` §G2.5, trap #54, G2 correctness audit #5). The
  script armed an `EXIT` trap and then `exec`ed the shell binary, which
  replaces bash, so the trap never ran and each run left a directory in
  `$TMPDIR`. It now runs the binary normally and exits with its status.
  `dev/check-trap-exec.sh` (CI lint job, `make lint`) fails any `dev/`
  script that execs past an `EXIT` trap.

- `Uri.getQueryParameter` decodes `+` to a space (`dev/g2/NOTES.md`
  §G2.5, G2 correctness audit #4). The macOS `android.net.Uri` stand-in
  returned `My+Layer` for `?layers=My+Layer`; Android returns
  `My Layer`. `%2B` still reads back as a literal `+`, and `getQuery()`
  is unchanged. Seven query checks join `dev/g2/render/test/uri.sh`.

- The GLES shim refuses an array-backed `Buffer` for vertex arrays
  (`dev/g2/NOTES.md` §G2.5, trap #53, G2 correctness audit #3).
  `glVertexAttribPointer` and `glVertexAttribIPointer` passed GL a
  pointer into a temporary copy of the backing array and then freed
  the copy, leaving GL a dangling pointer at draw time. They now throw
  `IllegalArgumentException`, as Android does; `gen-gles-shim.py` emits
  `bufferDirect` for those two entry points and `mactak_gles.c` is
  regenerated. `dev/g2/render/test/gles-shim.sh` (CI render job,
  `make test-render`) pins the contract.

- `Uri.fromFile` round-trips any path (`dev/g2/NOTES.md` §G2.5, trap
  #52, G2 correctness audit #2). The macOS `android.net.Uri` stand-in
  built `file://` URIs from the raw path, so a `#` or `?` in a folder
  name cut `getPath()` short and `%25` read back as `%`; the engine
  opens its databases at that path. `fromFile` now encodes the path as
  Android does, and `Uri.encode` keeps Android's unreserved set
  (`_-!.~'()*`). `dev/g2/render/test/uri.sh` (CI's JVM job) pins it.

- The render smoke's basemap leg can now fail (`dev/g2/NOTES.md` §G2.5,
  trap #51, G2 correctness audit #1). `RenderSmoke` and `WindowApp`
  passed on "content pixels > 0", which the vector layer drawn over the
  basemap satisfies by itself (23890 of 262144 px in CI), so a basemap
  that never rendered still read `PASS`. `ContentGate` now requires
  content to cover half the frame when a basemap is attached, for the
  poll loop and the verdict alike. `dev/g2/render/test/basemap-gate.sh`
  (CI, `make test-render`) builds a basemap that misses the camera frame
  and requires the smoke to fail. `fixtures/make-basemap.sh` takes
  optional bounds for it.

- commo's `closeSocket` diagnostic printed twice per close
  (`dev/g1/patches/commo/0001-diag-socketRead-errno.patch`, found in the
  G1 security audit's native-code read, `dev/g1/NOTES.md` §G1.14). The
  patch carried the `[commo-diag] closeSocket` block twice at the one
  `::close(fd)` macOS builds. The duplicate is gone. NOTES said the patch
  probed "both `::close(fd)` sites"; the other is Android-only netlink
  code, so it now says closeSocket.

- G1 correctness audit, pass 3 (`dev/g1/NOTES.md` §G1.13, four traps):
  the kernel-mode JNI pins cleaned up with `remove(dir)` on a non-empty
  directory, which fails, leaking a `/tmp/takjni-kernel-*` dir per
  `make test-jni` run. They now unlink and `rmdir`, and a leak fails
  the pin. `JniGuardsOnLoad.LeavesTheEnvClean` no longer relies on the
  previous test having called `JNI_OnLoad`; run alone or shuffled, it
  had passed vacuously. `jni_test_env.hpp` drops an always-true null
  check on a function address, which clang warned about in every test
  TU, and its comment now states the real linkage, not a weak import.
  `make-datapackage.sh` prints its usage instead
  of an unbound-variable error. The rest of `dev/g1` (patch series at
  `--fuzz=0`, the GDAL 3 VSI port, the C++17 header patch, `tools/`)
  was reviewed with no change needed.
- `dev/g1` docs-only cleanup: NOTES §G1.11 now quotes the CI results it
  had left pending (#75's hermetic round-trip `PASS` and `layer.sh` in
  `native-engine`). Its `System.exit` trap names the guard that exists,
  the round-trip's exit-code check, and the path left unpinned. §G1.11
  and §G1.12 headings name their branches, as §G1.10's does. This
  section's entries are back in newest-first order.
- GDAL 3 axis order on the C++ OGR path (`dev/g1/NOTES.md` §G1.12, the C++
  residual of G2 trap #48): an offline layer in a projected CRS (UTM
  shapefile, Web-Mercator GeoPackage) opened with lat/lon swapped. The
  engine's native transforms target a plain `importFromEPSG(4326)`, which
  GDAL 3 orders lat,lon. `dev/g1/patches/gdal3-axis-order-cpp-default.patch`
  sets `OSR_DEFAULT_AXIS_MAPPING_STRATEGY=TRADITIONAL_GIS_ORDER` first thing
  in `GdalLibrary::initImpl`. `test/layer.sh` gains UTM 10N and EPSG:3857
  legs and checks a known point's coordinates on every leg; before, it only
  counted features.
- G1 correctness audit, pass 2 (`dev/g1/NOTES.md` §G1.11, five traps):
  `CotEvent` refuses a received `<point>` without a finite, in-range
  lat/lon, and Java-only number forms (`45f`, `0x1p5`). The tracks DB had
  stored them as `"NaN"` text, which reads back as 0,0. `TrackStore`
  stores an unknown `hae` as SQL NULL. `CotXml.xmlEscape` keeps tab/LF/CR
  and replaces characters XML 1.0 cannot carry; one control character in
  a callsign had made every outgoing CoT unparseable. `HeadlessCLI`
  closes the tracks DB on failure exits too (`System.exit` had skipped
  the `finally`). `run.sh` fails fast when client A exits before
  iface-up. Pinned by 13 new `CotEventSelfTest` assertions
  (`test/cot.sh`).
- G1 correctness audit (`dev/g1/NOTES.md` §G1.10): `getDirContents` and
  the filtered `IO_listFiles` no longer return empty listings. They passed
  an unbound `STLVectorAdapter` to `listFiles`, the core-engine twin of the
  jni-proxy bug G1.9 fixed; fixed by the new
  `dev/g1/patches/stlvectoradapter-bind-contents.patch`. Engine patches now
  apply with `--fuzz=0`, and the megatexture patch, which had only ever
  applied with fuzz, is regenerated. The build scripts' EXIT trap no longer
  SIGTERMs the script itself when it's run from a terminal (exit 143 after
  a successful build). atak-headless XML-escapes uid/callsign in the CoT it
  sends, validates `--send-marker`/`--duration`, refuses a data package
  whose address proto disagrees with its certs, and refuses a
  same-basename PKCS#12 pair before one file overwrites the other.
  `CotEvent` reads `<point>`/`<contact>` as direct children,
  `LayerStore.bounds()` now unions Z, and `test/layer.sh` checks exact
  feature counts.
- GDAL 3 axis order (trap #48): `GdalLibrary.EPSG_4326` and every dataset
  SRS `GdalDatasetProjection2` transforms through are pinned to
  `OAMS_TRADITIONAL_GIS_ORDER` via a new `GdalLibrary.traditionalGisOrder`
  helper, so the engine's `TransformPoint(lon, lat)` calls (written for
  GDAL 2.x) georeference correctly on GDAL ≥ 3; previously
  `(Infinity, Infinity)`. Engine Java patch + shadows
  (`dev/g1/patches/gdal3-axis-order-traditional-gis.patch`). Also: the
  render classpath puts `gdal.jar` ahead of `android-port-3.1.0.jar`, whose
  GDAL 2.4-era `org.gdal` copy was the real source of trap 17's
  `UnsatisfiedLinkError` (trap #49); `GdalLibrary.init()` still stopped at
  the excluded VSI filesystem-handler native (trap #50) until the next entry.
- `GdalLibrary.init()` completes on GDAL 3 (trap #50): `jni/vsi_jfile.cpp`
  rejoins the JNI glue via `dev/g1/patches/vsi-jfile-gdal3-api.patch`, which
  ports its `VSIFilesystemHandler`/`VSIVirtualHandle` overrides to GDAL 3's
  interface (`Open` → `VSIVirtualHandleUniquePtr` + options, byte-count
  `Read`/`Write`, new `ClearErr`/`Error`, `shared_ptr` `InstallHandler`).
  The `/vsitakio/` Java-backed virtual filesystem is installed again;
  `GdalProjectionSmoke` asserts `init() == true` and opens a GeoTIFF through
  it (G2.4 b.1a).
- JNI layer bridge: a Java exception thrown inside a `GLLayer3` callback no
  longer poisons the render thread. `ManagedGLLayer2` now reports (once) and
  clears exceptions thrown by `getSubject()`, `draw()`, `release()`,
  `start()` and `stop()`, mirroring the draw-only fix
  `ManagedGLMapRenderable2` already got; the constructor also skips its
  marshal/adapt pair while an exception is pending, leaving the native
  subject null instead of populating it against a poisoned thread.
  (`dev/g1/patches/jnilayer2-exception-clears.patch`)
- JNI SPI dispatch: `ManagedGLLayerSpi2::create` no longer reports a Java
  exception thrown by the SPI as `TE_InvalidArg` with the exception still
  pending — the factory (`GLLayerFactory2`) reads any non-OK result as
  "not my subject" and advances to the next SPI, whose JNI calls then ran
  against the exception in flight. A thrown `create` is now described,
  cleared and reported as `TE_Err`; a clean null return keeps
  `TE_InvalidArg`. (`dev/g1/patches/jnilayerspi2-exception-clears.patch`)
- Terrain (per-frame bug): `GLGlobe` and `GLMapView2` guard
  `glEnable/glDisableVertexAttribArray(aEcefVertCoords)` — the planar
  terrain shader variants (`TerrainTilePlanar*`) declare no ECEF attribute,
  the location is -1 there, and both renderers select the planar variant
  for non-ellipsoid geometry, so every 2D/planar terrain frame raised
  `GL_INVALID_VALUE`. (`dev/g1/patches/attrib-location-guards.patch`)
- Terrain tile shader: `GLTerrainTile`'s local-frame selection tested
  `aEcefVertCoords > 0`, rejecting a legitimate attribute location 0 while
  the enable/pointer code in the same file (and the wave-2 guard patch)
  already accepts `>= 0`; ECEF terrain used the wrong local frame whenever
  the attribute landed on location 0.
  (`dev/g1/patches/terraintile-ecef-ge.patch`)
- Batch geometry (defensive hardening): `GLBatchGeometryRenderer3` guards
  every attribute-location query in the anti-aliased-lines and point
  draws. All eight queried attributes are used by the single cached
  program today, so -1 can only fire on a compile/link failure — the
  guards keep such a failure from poisoning the frame's GL error state.
  (same `attrib-location-guards.patch`)
- Terrain local frame (wave 5): `GLMapView2` picks the terrain tile's
  local frame from the active shader family's ECEF capability
  (`aEcefVertCoords >= 0`), as `GLGlobe` already did, instead of SRID
  equality between the projected elevation data and the draw SRID — a
  planar pass could concatenate the projected data's local frame whenever
  the elevation cache already held data in the draw SRID.
  (`dev/g1/patches/glmapview2-srid-capability.patch`)
- Batch geometry (wave 5): `GLBatchGeometryShaders` no longer stores
  `aRotation`'s uniform location into `aColor` — a dead store (the real
  `aColor` attribute lookup overwrote it a few lines later), kept from
  wave 4 as a report-only foot-gun.
  (`dev/g1/patches/glbatchshaders-dead-store.patch`)
- JNI bridge exception hygiene (wave 5): the remaining unguarded JNI
  dispatches on the live render-thread surface report (once) and clear a
  thrown Java exception instead of leaving it pending, where it turned
  every later JNI call on the thread into a silent failure:
  `jglobe.cpp`'s nine `CallbackForwarder` map-listener dispatches
  (`onMapMoved` fires per camera frame)
  (`jglobe-listener-guards.patch`); `jglmapview.cpp`'s two
  `CameraChangedForwarder` dispatches map a throw to `TE_Err` instead of
  a bare `TE_Ok` (`jglmapview-forwarder-guards.patch`); and
  `ManagedRenderContext`'s 16 sites — scalar getters return their neutral
  value, dispatch methods `TE_Err`, and the `getRenderSurface` helper
  clears so a throw no longer escapes the `NOTHROWS` constructor
  (`managedrendercontext-guards.patch`).
- JNI projection/math interop (wave 5): `ManagedProjection::forward` and
  `inverse` — the per-frame projection marshal path — map a throw to
  `TE_Err` before their null checks, and the shared `Interop_create`
  GeoPoint helper clears its own throw; core `Interop`'s per-frame
  `MapSceneModel` export no longer returns `TE_Ok` past a failed
  `NewObject` and its in-place `init()` dispatch is guarded. The
  `math/Interop` marshals gain null-argument guards (a null `jobject`
  there is a JVM crash, not a Java exception) plus `NewObject` guards,
  and the model resource-map marshal loop is guarded per call — those
  three are defensive only today.
  (`dev/g1/patches/projection-math-interop-guards.patch`)
- IOProviderFactory JNI (wave 5): `remove` and `mkdirs` use the file's
  own canonical `ExceptionCheck → Clear → TE_Err` guard their 11 sibling
  methods already had — a `SecurityException` previously fed garbage into
  the boolean, a coin-flip result with the exception still pending — as
  does `createTempFile`'s `getAbsolutePath` follow-up.
- IOProviderFactory file counts (wave 5): `getFileCount` called `isFile`
  twice; the second call was meant to be `isDirectory`, so the directory
  branch was unreachable and every directory returned `TE_IllegalState`.
  (`dev/g1/patches/ioproviderfactory-guards-and-filecount.patch`)
- JNI class-init failure masking (wave 6, systemic): every class/init
  function in the JNI tree guarded its lookups with an unconditional
  `return true` — a failed `FindClass`/`GetMethodID` stored null method
  IDs, reported success, and turned every later call on those IDs into
  undefined behavior. The sweep guards 46 live init functions across 40
  files (house `if(!x) return false;` shape; `SET_METHOD_DEFINITION` /
  `SET_FIELD_DEFINITION` macros carry the guard inside; inline
  `GetStaticObjectField`/`GetStaticFieldID` chains hoist a guarded
  `jfieldID`), and common.cpp's `JNI_OnLoad`/`ATAKMapEngineJNI_equals`
  lookups are guarded or exception-cleared. The Class/EngineLibrary
  block in `JNI_OnLoad` stays failure-tolerant by design — guarding it
  with early returns makes the JVM eagerly link `EngineLibrary` at load,
  whose verification needs bcprov the smoke classpath doesn't carry.
  (11 patches, `dev/g1/patches/*sweep*.patch` +
  `common-onload-classloader-guards.patch` +
  `textformat2-class-init-consumer-guards.patch`; notes in
  `dev/g1/NOTES.md` G1.8)
- Core Interop entry gates (wave 6, closes the wave-5 `NewObject` ×2
  residual): `GeoPoint_interop_entry`/`NativeProjection_interop_entry`
  now report their init result and the five callers gate —
  `Interop_copy` returns `TE_IllegalState`, `Interop_create` and both
  `Interop_wrap` overloads return `NULL` instead of calling
  `NewObject`/`CallBooleanMethod` against null method IDs.
- ManagedProjection scalar getters (wave 6 residual): `getMinLatitude`,
  `getMinLongitude`, `getMaxLatitude`, `getMaxLongitude`, `is3D` and
  `getSpatialReferenceID` bail with neutral values (`NAN`/`false`/`0`)
  when their method ID never resolved, instead of passing NULL into
  `Call*Method`.
- ManagedTextFormat2 desktop degradation (wave 6): every lookup in its
  init fails on desktop JVMs (the classes live in the Android app
  package), so the text-format consumers (`getStringWidth`,
  `getCharWidth`, `getCharHeight`, `getDescent`, `getStringHeight`,
  `getBaselineSpacing`, `getFontSize`, `loadGlyph`) and
  `ManagedTextFormatFactory::createTextFormat` now gate on the method
  IDs they use and return neutral values or `TE_Err` instead of calling
  through null.
  (`dev/g1/patches/textformat2-class-init-consumer-guards.patch`)
- `dev/g1` docs-only cleanup: NOTES §G1.8's audit paragraph now quotes
  `class_init_audit.py`'s canonical output (post-sweep fully guarded
  35, not 34; pre-sweep partial 4, not 3; unread clinit callers 23
  post-sweep, not 25 — the wave-6 entry gates closed 2); the wave-5
  defensive roster is committed into §G1.7 as a re-derived 27-file
  enumeration (100 sites on post-wave-6 main, 102 at the wave-5 close —
  wave-6's `ExceptionClear` hygiene drained `common.cpp` 6→4; both
  numbers now recorded in `dev/g1/tools/README.md`'s expected-output
  block); and the F-1 dead `setFocusPointOffset` slot is recorded
  (`MapRenderer3_init` binds it from a nonexistent `isAnimating(FF)V`
  and never consumes it — wave-7 deletes it). No code changes.
- JNI `IOProviderFactoryProxy::listFiles` (desktop JNI filesystem)
  dropped every directory entry: the `STLVectorAdapter` was
  default-constructed instead of bound to the caller's vector, so the
  Java `IOProviderFactory.list(File)` results (returned correctly) were
  collected into the adapter's private store and discarded —
  `getFileCount` on a directory reported `TE_Ok` with 0 and `length`
  on a directory reported 0. Both call sites now bind
  (`contents_w(contents)`).
  (`dev/g1/patches/ioproviderfactory-listfiles-adapter-bind.patch`;
  caught by the G1.9 kernel-mode pin `GetFileCountOfADirectory`, which
  failed 0-vs-2 on the first healthy-boot run)

### Security

- CI checkouts no longer leave the job token on disk
  (`dev/g1/NOTES.md` §G1.14, G1 security audit #12). 14 checkouts in
  `ci.yml`, `cot-roundtrip.yml` and `docs.yml` now set
  `persist-credentials: false`, as `supply-chain.yml` already did, so the
  token is not in `.git/config` while build scripts and Homebrew-installed
  tools run. The token is read-only and job-scoped; this is defence in
  depth. The two `changes` jobs keep it for their `git fetch`.

- The TLS server-purpose canary now covers OpenTAKServer's own
  certificate profiles (`dev/g1/NOTES.md` §G1.14, G1 security audit #1).
  `dev/g1/headless/test/tls-purpose.sh` signs a leaf with each profile
  pinned in `test/fixtures/ots-cert-profiles.cnf` (from OpenTAKServer's
  `ca_config.py`): the server certificate must connect and a user
  certificate must be refused. `dev/check-ots-profiles.py`
  (`make check-ots-profiles`) fails when upstream's profiles no longer
  match the pinned copy; `.github/workflows/ots-profile-drift.yml` runs
  it nightly.

- Recorded, not fixed: opening a layer file can make GDAL fetch remote
  URLs (`dev/g1/NOTES.md` §G1.14, G1 security audit #10). The engine
  opens layer files with every GDAL driver registered. An OGR VRT naming
  a `/vsicurl/` source, and a GML file whose `schemaLocation` names a WFS
  URL, each sent requests to a loopback listener. atak-headless opens
  only files the user names today; G6 must restrict drivers before it
  imports overlays from data packages or peers. The deep pass also
  records commo's stream framing, XML parse and lack of a listening
  socket as reviewed clean, and that native dependencies are only as
  current as Homebrew on the machine (#11). The #7 evidence block in
  NOTES moves out of the middle of #1's.

- atak-headless creates its `--db` tracks database owner-only (0600)
  (`dev/g1/NOTES.md` §G1.14, G1 security audit #7). The file holds every
  position received from other users, and the engine's sqlite open created
  it under the default umask, readable by every local account.
  `TrackStore` now creates a new file 0600 first; sqlite gives its journal
  files the same mode. `dev/g1/headless/run.sh` fails on any other mode.
  Pass 2 also narrows finding #4: commo's curl paths skip the chain check
  only when the caller passes no CA (or the transfer is peer-hosted), so
  G6 must always pass the truststore rather than patch commo.

- atak-headless escapes control characters in server-supplied output
  (`dev/g1/NOTES.md` §G1.14, G1 security audit #3). `headless:
  cot-received` printed a hostile server's ESC/BEL/C1 bytes straight to
  the terminal. The track summary printed parsed attributes, so a callsign
  carrying `&#10;` could forge a second `headless: track` line, one of
  the lines `run.sh` greps as evidence. `CotXml.printable` makes C0, DEL
  and C1 controls visible as `\xNN`. `HeadlessCLI` uses it for
  received CoT, contact uids and parse errors, and `CotEvent.toString`
  uses it per field. Pinned by six new `CotEventSelfTest` checks
  (`test/cot.sh`).
- commo TLS: the server certificate must now be fit for a TLS *server*
  (`dev/g1/NOTES.md` §G1.14, G1 security audit #1, High). Commo verified
  only that the server's certificate chained to the truststore CA, and
  skips hostname checks by design, so a same-CA `clientAuth`-only
  certificate (any enrolled user's) could impersonate the TAK server.
  `dev/g1/patches/commo/0002-sslcertchecker-require-server-purpose.patch`
  sets `X509_PURPOSE_SSL_SERVER` in `SSLCertChecker::checkCert`, which
  still accepts `serverAuth` and no-EKU server certificates.
  `dev/g1/headless/test/tls-purpose.sh` (CI: `cot-roundtrip.yml`;
  `make test-tls`) gives `fake-cot-server.py` a `--tls` mode and pins
  accept, accept, refuse. The impostor leg connects on unpatched commo
  and is refused with `CONN_SSL_PEER_CERT_NOT_TRUSTED` after.
- Transplant jar integrity is now enforced (`dev/g1/NOTES.md` §G1.14,
  G1 security audit): `dev/g1/transplants/SHA256SUMS` never listed the
  two slf4j jars, and the pre-commit hook's `shasum -c` only checks listed
  files, so an unlisted or swapped jar passed silently. CI never checked
  transplant hashes at all, though it loads these jars into a JVM next to
  native code. The slf4j hashes are added (both jars match Maven Central's
  published SHA-1). `dev/check-transplants.sh` fails on a mismatch *or* an
  unlisted jar; it backs the pre-commit hook, `make check-transplants` and
  a CI lint step that runs on every PR.

## [0.3.1] - 2026-11-07 — G2: window surfaces (M3.0–M3.1) + hardening

### Added

- `RenderSmoke --window W×H` + `make test-render-window` /
  `make test-render-resize` (M3.1): the engine renders into a real
  ANGLE window surface — a host dylib (`render/WindowHost.m`) owns a
  bare off-screen `CAMetalLayer` (no AppKit: AppKit wants the main
  thread and the `java` launcher's main is a spawned pthread, which a
  bare layer dodges), `render/WindowHost.java` drives it over JNI, and
  `--resize` changes the layer's `drawableSize` mid-run the way a real
  host does on a window resize. PASS requires a window surface on the
  layer, the mid-run resize gone through the host (`eglQuerySurface`
  truth at the new size), the `OnSizeChangedListener` fired, every
  `swap()` a successful present (counted; zero failures), and content
  pixels at the new size. ANGLE-Metal sizes a window surface once at
  creation and refuses a second surface on a live layer
  (`EGL_BAD_ALLOC`), so `adoptSurfaceSize` destroy-then-recreates on
  the same layer — the sizing contract is documented at the site
  (`mactak_egl.cpp`). The exercise needs no GUI session, so CI runs it
  itself, upgrading M3.0's compile-only/manual split (#49).

- `make smoke-window` (M3.0): the G2 window-surface gate — an NSWindow
  with a live `CAMetalLayer` becomes an ANGLE EGL window surface
  (`eglCreateWindowSurface`, Metal platform), draws a GL ES 3.0
  triangle, reads back centre/corner pixels into an exact-size P6 PPM
  artifact, and presents for 3 s (~30 fps). CI compiles it
  (`--compile-only`); the live run is manual on a GUI Mac. It fails
  instead of lying: unwritable/empty artifact (#39), nil Metal device
  exits 2 (#42), judging before EGL teardown so FAILs report live
  diagnostics (#38), 0 presented frames is a FAIL regardless of cause
  (#40 — decided strictest over log-only and hybrid options), unknown
  flags get a usage line (#37), and the present loop logs its measured
  duration (#41).

- `atak-headless --datapackage FILE` resolves an ATAK data package instead of
  hand-feeding flags: CoT host:port from `preference.pref`'s `cot_streams`,
  the callsign, and the PKCS#12 pair extracted to a temp dir — explicit
  flags still win, `MACTAK_CERT_PASS` overrides the package's password, and
  failures exit 2. Pure-JDK importer hardened against XXE, Zip-Slip and
  oversize entries (#31: 16 MiB for `preference.pref`, 64 MiB per PKCS#12,
  refused with the byte count); the address line takes a bracketed IPv6
  literal (stored unbracketed), range-checks the port to 1–65535 on the
  package and `--connect` paths alike, matches the proto token exactly
  (`ssl`/`tls`/`tcp` — `dtls` is refused, not mislabeled ssl), and refuses
  a client/truststore pair sharing one basename (#32); the canary
  (`test/datapackage.sh`) runs in the `jvm-tests` CI job, which now also
  compile-gates `HeadlessCLI.java` itself (#29 — CI previously never
  type-checked the launcher).

### Fixed

- The `--datapackage` cert temp dir is deleted on every exit, not just on
  the success path — a failed run no longer leaks extracted PKCS#12s in
  `$TMPDIR` (#27); the selftest cleans its `dpselftest-*` dirs too (#30).
- The canary's openssl recipe runs on bare macOS LibreSSL
  (`/usr/bin/openssl`), so the fixture builds without Homebrew OpenSSL (#28).
- Engine patch `megatexture-sharetile-comma-operator.patch`:
  `GLMegaTexture::shareTile` wrote `other,shareWith = this;` — the comma
  operator set `this->shareWith = this`, so every share after the first
  returned `TE_IllegalState`. `shareTile` has no callers at the pin
  (front/back swaps use `transferTile`), so G2.4 was never gated on it.
- Engine patch `quadtilenode4-resolvetexture-program-bind.patch` (G2.4a,
  groundwork for real imagery): `GLQuadTileNode4.resolveTexture` composited
  with `uColor` on whatever program was current — it now binds its own
  program first. Shipped as an engine shadow derived from the patch (the
  source tree stays at the pin), drift-gated in CI with the staged dylibs
  re-signed; the local drift check SKIPs loudly with its reason, the patch
  loop dies on failure, and codesign errors surface (PR #53).
- `render/WindowHost.m` compiles with ARC: under MRC the autoreleased
  `[CAMetalLayer layer]` was deallocated by `open()`'s `@autoreleasepool`,
  so the `jlong` the Java side received, every `g_layer` check and ANGLE's
  retain inside `eglCreateWindowSurface` all touched freed memory (the
  smoke passed on allocator luck). The Metal device is created once and
  handed to the layer instead of being fetched a second time (PR #55).
- The render harness stops passing without its evidence: a failed PPM
  renderback (`fopen` or short write) warns and gates
  (`MACTAK_SMOKE_PPM`); the ANGLE linkage check captures `otool -L`
  before grepping — under pipefail `grep -q` could exit 141 (EPIPE) and
  read as "stub linkage"; `fetch-angle.sh` runs `install_name_tool` bare
  and asserts `otool -D` reports `@rpath/<name>.dylib` (a skipped id
  rewrite left Electron's `./x` install names for dyld to trip over far
  from the staging); the smoke's `--out` parent is created before Java
  runs; `render/build-window-host.sh` honors `JAVA_HOME` (CI's
  setup-java) before `/usr/libexec/java_home` (PR #55).
- `headless/run.sh` polls A's log for `iface-up` (bounded at 90 s,
  failing with A's log) instead of a fixed `sleep 1` that raced the
  launcher's compile; `layer.sh` no longer silently asserts user files
  at exactly one feature (`FILE:N` overrides, a bare `FILE` says what it
  assumed, a non-numeric `N` falls back loudly); `make lint` covers
  `dev/g1/headless/atak-headless`, which the `dev/**/*.sh` glob never
  matched (PR #55).
- `fetch-angle.sh` keeps codesign stderr (swallowed failures exited
  undiagnosably) and both smoke runners guard the ANGLE dir before
  `cd`ing, where `set -e` ate the missing-ANGLE message; the render
  smoke's bcprov fetch retries — single-shot Maven Central curls flake
  CI; the classpath existence check splits on `:` only (a whitespace
  split false-failed spaced paths); window-host staleness is keyed on
  the build script and the JDK's `jni.h` too (PR #56).
- The G1 round-trip fails loudly when an `ogr2ogr` conversion dies (a
  silently dropped leg still printed PASS), and its evidence lands in
  one `mktemp -d` dir — `mktemp -t` leaked two orphans per run (PR #56).

### CI

- `cot-roundtrip.yml` gains `workflow_dispatch`, runs on edits to the
  workflow itself, and uploads failed-run evidence — the runner's
  TMPDIR dies with the job (PR #56).
- `supply-chain.yml` splits: the Brewfile job (`brew bundle`
  install/check, lock regeneration, and the new Brewfile == union of
  the workflows' `brew install` lines gate, which also triggers on
  `ci.yml` and `cot-roundtrip.yml` edits) stays on macOS, while
  osv-scanner runs on ubuntu — its container action is Linux-only and
  had never produced a results file on `macos-26` (PR #55).

## [0.3.0] - 2026-11-05 — G2: map renders (ANGLE on Metal)

### Added

- ANGLE (EGL 1.5 / ES 3.0 on Metal) occupies the engine's GLES slot: the
  engine renders from the JVM into an EGL pbuffer with zero GL errors
  (#17), gated by a pure-C canary (`smoke/egl-triangle.c`) that exercises
  Metal-platform → pbuffer → draw → readback independent of the engine.
- First map content: a GeoJSON `FeatureLayer` (polygons, lines, labels)
  renders through the engine on ANGLE (#18).
- Offline basemap: an MBTiles raster fixture (generated offline by the
  `gdal` CLI) renders under the vector layer (#18).
- Render smoke harness with PNG artifacts; `make build-angle` and
  `make test-render` gate it locally and in CI (#17, #18).
- `gen-gles-shim.py` emits a full-coverage GLES no-op stub
  (`mactak_gles_stub.c`), so stub-mode CI builds link again (#18);
  `make gen-gles-shim` + a CI drift gate keep the generated artifacts
  honest (#22).

### Changed

- The render smoke waits for content pixels — it polls the GL readback
  and keeps rendering until content appears (capped at 5× settle /
  min 15 s) instead of trusting a fixed wall-clock floor (#23).
- GLES shim cache evicts programs on `glDeleteProgram`, and debug paths
  get `FindClass` null-checks; `MACTAK_GL_DEBUG=2` dumps the Java stack
  next to the native backtrace (#22).
- The layer canary reports on every CI run (#17).

### Fixed

- `GLMegaTexture::release()/clear()` erase-while-iterating SIGSEGV under
  CI (#17).
- The ANGLE staging download retries release-CDN 504s: a mid-transfer
  drop (curl 56) is outside curl's default transient set, so
  `fetch-angle.sh` downloads with
  `--retry 5 --retry-delay 5 --retry-all-errors --retry-max-time 600`
  (#23).

## [0.2.0] - 2026-11-04 — G1: headless engine + CoT round-trip

### Added

- Deterministic native engine build plus a C++ test canary (G1.0), with
  the working tree consolidated under `dev/`.
- In-process engine load from a Zulu 8 arm64 JVM via JNI glue and a load
  smoke (#1).
- `atak-headless --connect HOST:PORT`: commoncommo stack headless; CoT
  round-trip verified against FreeTAKServer and OpenTAKServer
  (two clients, marker + presence relayed both ways) (#3).
- `atak-headless --layer FILE`: GeoJSON/GPKG/KML/SHP open through the
  native OGR provider into `PersistentDataSourceFeatureDataStore2` and
  read back — the offline-layer criterion, with a four-format canary in
  CI (#4).
- Track persistence: one JVM loads engine + comms together; received CoT
  persists through the engine's `DatabaseImpl` JNI into a sqlite tracks
  DB (`--db`), and the latest fix per uid prints on exit — witnessed on
  OpenTAKServer over TCP and SSL (certs from an ATAK data package) and
  hermetically in CI (#15).
- `fake-cot-server`: a CoT relay for local testing (buffers partial
  lines, relays bytes verbatim, relays client lines to other clients).
- Local dev gates: pre-commit hook chain (shellcheck, markdownlint,
  actionlint, jar SHA256 manifests) plus a Makefile (#5).
- Supply-chain automation: dependabot, Brewfile lock + osv-scanner job
  (#5).

### CI

- Tier 0/1 on GitHub Actions: docs lint, native-engine PR gate, JVM
  tests, shell/workflow lint (landed 2026-11-02; runners pinned to
  `macos-26`).
- CoT round-trip wired into CI — a run with empty artifacts fails
  (exit 4); `fake-cot-server` covers the hermetic leg (#5).
- Every PR reports — docs-only changes run no-op lint guards instead of
  leaving checks pending (#12, #14).

## [0.1.0] - 2026-11-02 — G0: engine builds on macOS arm64

### Added

- Founding feasibility report set (ATAK-CIV 4.6.0.5 evidence) and the
  program documents: architecture, Pathway C host strategy, gate-gated
  roadmap, CI/QA plan.
- Pathway A baseline: a WinTAK golden VM with a verified FreeTAKServer
  round-trip — the reference behavior for the port.
- `libtakengine.dylib` compiles and links on macOS arm64 (~460
  translation units), all five takkernel Java modules publish to
  mavenLocal on Zulu 8, and a `dlopen` smoke passes.
- CI Tier 0 seed: docs lint + shell/workflow lint.

### Changed

- Licensed under GPL-3; LAN IPs scrubbed from evidence; renamed macTAK.
