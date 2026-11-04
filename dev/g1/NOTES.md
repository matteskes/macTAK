# dev/g1 — G1: JVM host + native JNI glue (macOS arm64)

## State (G1 Milestone 1 — JVM in-process load): DONE locally, CI pending

`dev/g1/build-native.sh` now produces **two** dylibs:

- `libtakengine.dylib` — the G0 core engine (9.7 MB, no JNI exports)
- `libtakenginejni.dylib` — the JNI glue (`engine/src/main/jni`, 1.2 MB,
  1114 `Java_*` exports + `JNI_OnLoad`)

and proves the G1 premise with canary 3/3 (`dev/g1/smoke/run.sh`): a real
JVM (Zulu 8) does `System.load` on both, then drives
`DatabaseImpl.openOrCreate → CREATE/INSERT/SELECT` through the full stack
Java → JNI glue → C++ Database2 → sqlite → Java and reads back **42**.

```text
[smoke] java 1.8.0_512 (OpenJDK 64-Bit Server VM)
[smoke] libtakengine.dylib loaded (core, no JNI exports)
[smoke] libtakenginejni.dylib loaded (JNI_OnLoad ran)
[smoke] DatabaseImpl.openOrCreate ok (JNI -> C++ Database2 -> sqlite)
[smoke] SELECT 41+1 through the JNI stack = 42
[smoke] PASS: engine loads and runs in-process from the JVM
```

## How the JNI target is built (wrapper, inside build-native.sh's heredoc)

Upstream already ships a macOS JNI build config (`src/main/jni/cmake/
{Common,MacOSSources}.cmake` — the TAKX pattern: glue as a separate
`takenginejni` shared lib linking the core). The wrapper mirrors upstream's
APPLE assembly and then applies the same G0 substitutions:

- sources from upstream lists, minus **`c3dt/`** (3D tiles/GLTF — later
  rung) and minus **`vsi_jfile.cpp` + `jvsijfilefilesystemhandler.cpp`**
  (GDAL VSI API drift — overrides pre-drift `VSIFilesystemHandler`
  signatures; same drift family as the LAS exclusion; revisit at the
  ttp-dist rung)
- defs: upstream macOS (`RTTI_ENABLED`, `TE_GLES_VERSION=3`) minus
  `SQLITE_HAS_CODEC` (SQLCipher rung)
- includes: work-copy `cpp/` + `jni/`, Homebrew, khronos, stl-soft,
  tinygltf overlay, plus **`dev/g1/jni-include`** (pinned javah output)
  and **`dev/g1/jdk-include`** (pinned zulu-8 `jni.h`/`jni_md.h` — keeps
  the native build JDK-free)
- links: `takengine` + GLES stub + **`/opt/homebrew/opt/sqlite/lib/
  libsqlite3.dylib`** (full path — see the sqlite trap below) + gdal +
  minizip (+ libkml→minizip rename defs, same as core)

### Pinned javah headers

The jni TUs `#include` generated headers (`jdatabaseimpl.h`, …) that
upstream's gradle `javah` task emits. They are a **committed, pinned
artifact** here (`dev/g1/jni-include/`, 78 files) generated exactly like
upstream (`gradle/javah.gradle`: `javah -o <header> <classes...>` per
`javah.properties` line, so multi-class entries concatenate):

```bash
dev/g1/gen-jni-headers.sh        # needs zulu-8 + mavenLocal jars
```

Regenerate ONLY at an engine version bump (bump `TAKKERNEL_VER`, publish,
run, commit the diff). This keeps the native build hermetic — no JDK, no
gradle, no mavenLocal in CI's native job.

## Traps found on the way (do not rediscover these)

1. **Two sqlite3 runtimes in one process = SIGSEGV.** Linking bare
   `sqlite3` resolves to `/usr/lib/libsqlite3.dylib` (system), while
   `libspatialite` (which core calls via `Databases_openDatabase →
   spatialite_init_ex` at every db open) is built against Homebrew sqlite.
   The mixed pair crashed in `findElementWithHash` (spatialite registering
   SQL functions on a foreign sqlite handle). Fix: pin
   `/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib` by full path in BOTH
   targets so the whole process shares one runtime. Symptom signature:
   crash on first `DatabaseImpl.open*`, stack
   `spatialite_init_ex → sqlite3_create_function_v2 → findElementWithHash`.
2. **`set -o pipefail` + `grep -q` is flaky**: grep exits on first match,
   nm eats SIGPIPE (141), pipefail turns a passing check into a failure.
   Use `grep ... >/dev/null` in pipeline guards.
3. **`System.load` needs absolute paths**; `run.sh` resolves its dist dir.
4. **rsync flattens `src/main/` into `build/engine/`** (trailing-slash
   copy): the glue lives at `build/engine/jni`, not
   `build/engine/src/main/jni`.
5. **Staging must precede the smoke canary** — run.sh loads from
   `native-dist/`.
6. **`EngineLibrary` is benign at `JNI_OnLoad` time**: the glue's
   `JNI_OnLoad` FindClasses `com/atakmap/map/EngineLibrary` (resolved from
   the engine jar on the smoke classpath); its `<clinit>` catches its own
   native-load failure, so class init never blocks the load. Its lib list
   (`takengine`, `takenginejni` last) is the desktop load order.
7. **Android-only paths in the glue are properly guarded** (`spatialite_init`
   and `__android_log` behind `#ifdef __ANDROID__`) — desktop-safe as-is.

## Smoke runtime contract (dev/g1/smoke/)

`run.sh` needs: JDK 8 (`JAVA_HOME` or `/usr/libexec/java_home -v 1.8`)
and, per jar, mavenLocal first, else the committed transplant:
`takkernel-engine/-port/-annotation 0.59.1` at `dev/g1/transplants/`
(built from the same pinned upstream commit as src/) and
`android-port-3.1.0` at its G0 home `dev/spike/g0/transplants/`. The
android-port jar provides `android.*` stub signatures the engine jar's
signatures reference; the happy path never constructs a stub body (any
engine-side failure would surface as a confusing "Stub!" — stay on the
happy path when diagnosing).

CI: `native-engine` gained only a Zulu-8 setup step (the build needs no
JDK; the smoke does). `build-native.sh` still runs verbatim.

## Follow-ups

- `atak-headless` CLI skeleton (`--connect`) — next milestone; FTS
  round-trip traps (port-role swap 8087/8089, handshake-before-
  registration, restart FTS container between runs) are catalogued in
  `dev/spike/g0/pathway-a.md`.
- c3dt + VSI TUs rejoin at the ttp-dist rung; SQLCipher at the encryption
  rung; core install_name stays build-absolute (native-dist is built and
  consumed on the same machine — revisit if dylibs ever ship cross-machine).

## G1.2 — atak-headless: CoT round-trip (commoncommo build + streaming iface)

Build: `bash dev/g1/build-commo.sh` stages the comms stack into
`native-dist/` (`libcommoncommo.dylib`, `libcommoncommojni.dylib`,
`jcommoncommo.jar`) from the local commoncommo tree +
`patches/commo/*.patch` (-p1, relative to the copy root — keep separate
from the -p3 engine patches). Runtime: `dev/g1/headless/atak-headless`
(compiles HeadlessCLI.java on the fly, Zulu 8); live round-trip smoke:
`dev/g1/headless/run.sh` (two clients against any plaintext-CoT TAK
server; `TAK_HOST`/`TAK_PORT`, default 127.0.0.1:8087).

### Diagnostics (patches/commo/0001-diag-socketRead-errno.patch)

Five WARNING-level `[commo-diag]` probes in commo: socketRead
(errno + local port), both `::close(fd)` sites (local port), sendBroadcast
(type + ups), the io-tx queue check (q/blocked/doTx), and the io-tx write
(w/r). Regenerate from the generator repo `g1-commo-gen` (pristine
core/impl + insert.py; patch must be a scoped `git diff -- core/impl`).

### Traps found on the way (do not rediscover these)

Continuing G1.1's numbering (these are traps 8–12):

1. **commo fires `interfaceUp` BEFORE the context enters its sendable
   `upContexts` list** (streamingsocketmanagement.cpp: fireInterfaceChange,
   then insert). A broadcast sent inside the interfaceUp callback iterates
   zero contexts — broadcastCoT returns success while queueing nothing,
   and no byte ever reaches the wire. Diag signature: `sendBroadcast
   type=0 ups=0` and no `io-tx` lines. Fix in HeadlessCLI: never send
   from the callback; a sender thread announces presence on a 2 s
   heartbeat (mirroring ATAK's SA cadence) starting 500 ms after
   iface-up, and the marker rides the first send window.
2. **The generator must own its BASE path**: insert.py once pointed at a
   stale `/tmp/gt` copy while every retry reset the pristine repo —
   inserts piled up on already-patched files (the close-sites assert saw
   4 instead of 2). Keep generator + tree in one repo and
   `git checkout -- core/impl` before each run.
3. **brew protoc ≥27 no longer emits C++11** — pb objects are
   precompiled at -std=c++17 (build-commo.sh) so the 2016 core can stay
   C++11. Related: ld64 records only libs that resolved a symbol, so
   protobuf's absl deps are swept explicitly on the link line.
4. **install_name_tool invalidates the linker signature** — ad-hoc
   codesign after every install_name change (arm64 refuses unsigned
   dylibs).
5. **A TAK server does not reflect a client's own events back to it.**
   The original one-client `run.sh` passed only because FreeTAKServer
   sends a welcome GeoChat (`b-t-f`) and echoes the sender's marker;
   OpenTAKServer does neither (`received=0` → FAIL, while the bytes were
   on the wire and visible to other clients). A round-trip proof needs a
   second client: `run.sh` now runs A (listener) and B (presence +
   marker) and asserts each saw the other.

### Round-trip contract (verified)

`run.sh` passes when: both ifaces up, B's presence + marker tx'd (commo
diag shows full-size `io-tx write w=N r=N`), A logged
`contact-added <B>` and received B's marker (`uid="<B>-m1"`,
`a-f-G-U-C`), B received A's presence (`t-x-a-t-a-k`). Verified against
**OpenTAKServer** (`steintak`, tcp/8088, 2026-11-03): 12 s run → A
`received=7` (6 presence + marker), B `received=7`, each side
`contact-added` the other. Earlier one-client form verified against
FreeTAKServer (container, host network, tcp/8087): received=2 (welcome
chat + echoed marker). Restart the FTS container between sessions for a
clean contact list; OTS needs no reset.

## G1.3 — atak-headless --layer: offline vector layers (engine feature stack)

`atak-headless --layer FILE` is the roadmap's "offline map layer opens"
criterion, minus the GL: the engine's **native OGR feature provider**
parses the file, the **native `PersistentDataSourceFeatureDataStore2`**
persists it (feature-set databases under `--layer-db DIR`, exactly what
ATAK's overlay manager does on Android), and `FeatureDataStore2` cursors
read it back. Runs on the engine stack (`build-native.sh`), not the comms
stack — the launcher picks the entry point from the first flag
(`--layer` → `mactak.headless.LayerCLI`, else `HeadlessCLI`).

```text
dev/g1/headless/atak-headless --layer FILE [--layer FILE ...] [--layer-db DIR]
                              [--expect-features N] [--quiet]
```

Canary (`dev/g1/headless/test/layer.sh`, a `native-engine` CI step after
`build-native.sh`): the committed `test/fixtures/sf-landmarks.geojson`
(3 points, 2 lines, 3 polygons) plus, when `ogr2ogr` is on PATH (it is —
gdal is a build dep), the same features as **GPKG, KML and shapefile**.
All four PASS:

```text
layer sf-landmarks.geojson             8 feature(s) in 41 ms
set 1    OGR    GeoJSON      sf-landmarks.geojson             8 feature(s)  sf-landmarks.geojson
1 feature set(s), 8 feature(s) in store
  fid 4294967297   set 1   Ferry Building               Point              [37.79550 -122.39370 .. 37.79550 -122.39370]
  fid 4294967300   set 1   Golden Gate Bridge           LineString         [37.80600 -122.47880 .. 37.83240 -122.47500]
  fid 4294967302   set 1   Golden Gate Park             Polygon            [37.76400 -122.51070 .. 37.77420 -122.45310]
…
PASS: 8 feature(s) opened through FeatureDataStore2
```

### Design decisions

- **GDAL driver registration is a macTAK JNI shim.** On Android the
  engine's `GdalLibrary.init()` calls `gdal.AllRegister()` through the
  org.gdal SWIG bindings; Homebrew GDAL ships no Java bindings.
  `dev/g1/jni-extra/mactak_gdal.cpp` (compiled into
  `libtakenginejni.dylib` by `build-native.sh`, export checked in its
  canary gate) exposes the engine's own native
  `GdalLibrary::init(gdalDataDir)` as `mactak.headless.NativeGdal.init`.
  The launcher passes `-Dmactak.gdal.data=$(gdal-config --datadir)`
  (override: `GDAL_DATA`).
- **The provider set is the one ATAK registers**: `new
  OgrFeatureDataSource()` (native `OGR_FeatureDataSource2` + KML/GPX/SHP
  `OGRDriverDefinition2` SPIs); any other GDAL vector driver (GeoJSON,
  GPKG, …) falls through to `DefaultDriverDefinition2`. Nothing is
  registered by the C++ library itself — `FeatureDataSourceFactory` is
  empty until Java registers providers.
- **slf4j is on the engine-side classpath.** The `java`-target
  `com.atakmap.coremap.log.Log` logs through slf4j; `slf4j-api` +
  `slf4j-simple` 1.7.30 (upstream's pin, `gradle/versions.gradle`) are
  committed transplants (Maven Central, SHA-1 verified on fetch); default
  level `warn`, `MACTAK_LOG_LEVEL=debug` for engine chatter.
- **Engine-side Java keeps the `mactak.headless` package** (under
  `headless/src/`) because the JNI shim's symbol name is derived from it;
  the comms-side `HeadlessCLI` stays flat in the default package as
  G1.2 left it.

### Traps found on the way (do not rediscover these)

Continuing G1.2's numbering (these are traps 13–15):

1. **No GDAL drivers unless something calls `GDALAllRegister`.** Symptom:
   `ERROR 4: No driver registered` from OGR and
   `PersistentDataSourceFeatureDataStore2.add()` returning `false` with no
   exception. Nothing in `libtakengine` registers drivers on load; the
   shim above must run before the first provider touches GDAL.
2. **Never call `FeatureCursor.get()` / `Feature.getStyle()` on the JVM.**
   Materialising a `Feature` parses its style, and
   `FeatureStyleParser.<clinit>` builds an `android.util.LruCache` — a
   `"Stub!"` in the android-port transplant (the predicted trap from the
   G1.1 smoke contract, now met for real). Read through the cursor's
   `FeatureDefinition` view instead: `getRawGeometry()` +
   `getGeomCoding()` + `GeometryFactory.parseWkb/parseSpatiaLiteBlob`.
3. **The first engine code path that logs needs slf4j on the classpath**
   — `NativeFeatureDataStore2.finalize` threw
   `NoClassDefFoundError: org/slf4j/LoggerFactory` after a run that had
   otherwise succeeded. The G1.1 smoke never logged, so this stayed
   hidden until M3.

### Known-benign noise

- `WARN … Native FeatureDataStore2 leaked` on close: upstream's
  `PersistentDataSourceFeatureDataStore2.dispose()` destructs its own
  pointer and then calls `impl.finalize()`, which only checks the base
  view's (never-zeroed) pointer. Not a leak; the native object is gone.
- `SQLITE [SQL logic error] no such column: definition_12_063` on GPKG:
  GDAL 3.13 probes the optional WKT2 column of `gpkg_spatial_ref_sys`;
  files written without it log once and open fine.
