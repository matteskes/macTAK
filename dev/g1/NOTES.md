# dev/g1 — G1: JVM host + native JNI glue (macOS arm64)

## State (re-pin — 2026-11-11): the baseline is ATAK-CIV 5.5.1.10; JDK 21 only

`src/` is `TAK-Product-Center/atak-civ` @ `9f6893d` (takkernel 8.30.5),
sparse (CONTRIBUTING.md §Setup). `build-native.sh` builds it with the
38-patch 5.5 series (3D Tiles left out), the kernel jars come from
`kernel/build-kernel-jars.sh` instead of the 0.59.1 transplants, commo
is 5.5's with QUIC on ngtcp2 (`fetch-ngtcp2.sh`, `make test-quic`), and
`atak-headless` runs the whole 5.5 stack in one JVM on JDK 21. How it got
here, step by step, with its traps: `dev/spike/g55/NOTES.md`. Sections
below this one describe the 4.6 build they were written for; file paths
and patch names still hold unless g55's §What's here says they moved.
New G1 traps continue this file's numbering.

## State (G1): M1–M4 DONE — G1 exit criteria met: engine + comms in one JVM, CoT in/out persisted to the engine's tracks DB, offline layers open; witnessed on OpenTAKServer (TCP + SSL) and hermetically in CI

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
  rung). ~~Minus `vsi_jfile.cpp` + `jvsijfilefilesystemhandler.cpp` (GDAL
  VSI API drift)~~ — `vsi_jfile.cpp` rejoined 2026-11-09 via
  `patches/vsi-jfile-gdal3-api.patch` (G2.4 b.1a, `dev/g2/NOTES.md`); the
  companion TU never existed at the pin.
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
   Use `grep ... >/dev/null` in pipeline guards. **Guard (2026-11-11):**
   `dev/check-pipefail-grep.sh` (`make lint`, CI's lint job) fails a
   pipefail script that pipes into `grep -q`/`-m`
   ([g55 trap 3](../spike/g55/NOTES.md)).
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

## Follow-ups (after G1.1)

- `atak-headless` CLI skeleton (`--connect`) — landed as G1.2 (below);
  extended by G1.3 (`--layer`) and G1.4 (tracks DB + exit demo). FTS
  round-trip traps (port-role swap 8087/8089, handshake-before-
  registration, restart FTS container between runs) are catalogued in
  `dev/spike/g0/pathway-a.md`.
- c3dt rejoins at the ttp-dist rung (the VSI TU already has, G2.4 b.1a);
  SQLCipher at the encryption
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
(errno + local port), closeSocket (local port; `platform.cpp`'s other
`::close(fd)` is Android-only netlink code, never built here), sendBroadcast
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

## G1.4 — one JVM, both stacks: tracks DB + the exit demo

`atak-headless` is now a single entry point (`mactak.headless.HeadlessCLI`)
that loads **all four** dylibs into one process — `libtakengine` +
`libtakenginejni` (engine) and `libcommoncommo` + `libcommoncommojni`
(comms) — with `jcommoncommo.jar` and the takkernel jars on one classpath.
`--layer` dispatches to `LayerCLI.run` (G1.3); everything else is the CoT
endpoint (G1.2), which now persists every received `<event>` through the
engine's `DatabaseImpl` JNI (Java → glue → C++ Database2 → sqlite) into a
tracks DB and prints the newest fix per uid on exit — the roadmap's
"streams positions both ways and plots them in-memory":

```text
atak-headless --connect HOST:PORT [--db PATH] [--cert CLIENT.p12 --ca TRUSTSTORE.p12] ...
headless: track uid=g1-rt-m2uehlair-b     type=a-f-G-U-C callsign=G1-RT-M2UEHLAIR-B    lat=0.000000  lon=0.000000   time=… fixes=8
headless: track uid=g1-rt-m2uehlair-b-m1  type=a-f-G-U-C callsign=G1-RT-M2UEHLAIR-B-M1 lat=37.774900 lon=-122.419400 time=… fixes=1
headless: tracks uids=2 fixes=9 db=/tmp/a.sqlite
```

`--db PATH` persists to a file; without it the engine opens a private
temporary database (`DatabaseImpl.openOrCreate(null)` → `sqlite3_open_v2("")`),
so the exit demo always runs. `run.sh` gives each client its own DB and
asserts A's holds B's presence + marker (from the exit demo and, independently,
by reading the file back with the `sqlite3` CLI) and B's holds A's presence.

`--cert` + `--ca` (the two PKCS#12 files in an ATAK data package; passwords
via `MACTAK_CERT_PASS` / `MACTAK_CA_PASS`, default `atakatak`) switch commo's
streaming interface to SSL with a client certificate — OpenTAKServer's 8089.
`run.sh` passes them through as `TAK_CERT` / `TAK_CA`.

Verified 2026-11-04 against **OpenTAKServer** (`steintak`) on **both**
tcp/8088 and ssl/8089 (two distinct data-package certs also tried): A
`received=9 persisted=9`, B `received=8 persisted=8`, PASS. CI
(`cot-roundtrip.yml`) builds both stacks and runs the same `run.sh` against
`fake-cot-server.py`; `ci.yml`'s `native-engine` job now also builds commo
before the layer canary, since the launcher requires both.

### Design decisions

- **`HeadlessCLI` moved into `src/mactak/headless/`** (git rename) so one
  `javac` compiles one tree against one classpath and there is one `main`.
  `LayerCLI.main` became `LayerCLI.run(String[])`; native loading lives only
  in `HeadlessCLI` (`-Dmactak.native.dist`, engine before comms, core before
  glue per stack).
- **`CotEvent` / `TrackStore`** are the G1.2-era pure-Java pieces ported from
  the `archive/g1-m3-on-javatcp` branch: a DOM parser (XXE-hardened: no
  DTDs, no external entities) for `<event>`/`<point>`/`<contact callsign>`,
  and an append-only `tracks` table with a `(uid, id)` index; `latest()` is
  one `MAX(id) GROUP BY uid` join with per-uid counts. `TrackStore` methods
  are synchronized (commo's rx thread vs. main at exit) and `record` is a
  no-op after `close` so a late callback cannot hit a closed handle. Server
  pings (`t-x-c-t`) are not recorded.
- **The presence is a real self-SA** (`a-f-G-U-C` + `<takv>`, `<contact
  endpoint callsign>`, `<uid Droid>`, `<__group>`, `<status>`, `<track>`),
  not the G1.2 `t-x-a-t-a-k` ping, and `stale` is now in the future for both
  presence and marker (G1.2 had `stale == time`). See trap 17.
- **OpenSSL legacy provider shim** `dev/g1/jni-extra/mactak_ssl.cpp`
  (`NativeSsl.loadLegacyProvider`), compiled into `libcommoncommojni` by
  `build-commo.sh` (the jni Makefile globs `*.cpp`); export + single-libcrypto
  checks added to its canary. See traps 19–20.

### Traps found on the way (do not rediscover these)

Continuing G1.3's numbering (these are traps 16–21):

1. **OpenTAKServer registers an EUD only from a self-SA** — a parseable
   `<event>` carrying `uid`, `<contact callsign>` and preferably `<__group>`
   (`EudHandler.parse_device_info`). Until then the per-client RabbitMQ
   consumer is never started: the socket is up, bytes are accepted, nothing
   ever comes back. The G1.2 `t-x-a-t-a-k` ping with no group (and
   `stale == time`) stopped registering after the server was rebuilt; it had
   passed on 2026-11-03 by luck of server state.
2. **OTS declares a durable RabbitMQ queue per EUD uid, bound to its `cot`
   fan-out exchange, and never deletes it.** A fresh uid per `run.sh` run
   (`g1-rt-<epoch>-a/b`) leaked two bound, unconsumed queues per run; every
   CoT was copied into each until the broker alarmed and blocked all fan-out
   for every client. `run.sh` now uses stable per-host uids
   (`g1-rt-<hostname>-a/b`, `TAK_UID_PREFIX` to override). The `auto_delete`
   fix belongs in OTS; any new real device leaks the same way.
3. **OTS drops every CoT from a uid whose callsign is registered to a
   different uid** — silently (the `cot_parser` worker fails before
   `route_cot`; the sender sees nothing, receivers see nothing from it).
   Reusing `G1RT-A/-B` across different uids triggered it. `run.sh` derives
   callsigns from the uids (`G1-RT-<HOST>-A`). Bisected with a raw-socket
   sender while an `atak-headless` listener watched: identical bytes with a
   fresh callsign pass, with the colliding one fail.
4. **Data-package PKCS#12 is RC2-40** (`pbeWithSHA1And40BitRC2-CBC`, the
   OpenSSL ≤1.1 default OTS and TAK Server still emit); OpenSSL 3 decrypts it
   only with its legacy provider, so commo's `PKCS12_parse` fails with
   `Invalid format for client cert`. Java 8's `KeyStore` cannot re-wrap it
   either (its PKCS12 writer is RC2-40-only; the `keystore.pkcs12.*`
   properties are ignored). Fix: `NativeSsl.loadLegacyProvider()` before the
   first `addStreamingInterface` with a cert (loads `legacy` **and**
   `default` — explicitly loading one provider disables the implicit default).
5. **Two OpenSSL runtimes in one process** (the sqlite trap, again).
   `libcommoncommo` was linking **openssl@4** (`/opt/homebrew/lib/libcrypto.dylib`
   follows whichever `openssl@N` brew linked last) while the JNI glue linked
   the shim's openssl@3 — so the legacy provider loaded into a libcrypto commo
   never called. `build-commo.sh` puts `-L$WORK/shim/lib` first in
   `CORE_CXXFLAGS` (the Makefile's `-L$(TAKTHIRDPARTYDIR)/lib` comes after
   `CXXFLAGS` on the link line) and its canary asserts both dylibs resolve
   `openssl@3/lib/libcrypto`.
6. **commo frames on `</event>` and writes `<?xml …?>\n<event…/>` with no
   trailing newline**; the fake server framed on newlines and prefixed its
   own broadcasts with an XML prolog. Relayed events arrived glued to the
   next prolog (`Invalid CoT message received from stream`, pre-existing on
   main), and once that was fixed the leftover `\n` before the server's own
   prolog still broke libxml2 (a declaration must be byte 0).
   `fake-cot-server.py` now frames inbound on `</event>`, drops prologs, and
   sends its own events without one.

### Known-benign noise

- **Old CoT replayed on connect**: OTS's per-uid queue is durable and keeps
  accumulating while the client is away (until `OTS_RABBITMQ_TTL`), so the
  first seconds after connecting deliver whatever arrived since the last
  run. The tracks DB records them with their original `time`.
- `run.sh`'s `nc -z -G` reachability probe is a plain TCP connect, also fine
  for the SSL port.
- `build-commo.sh`'s EXIT trap kills its own process group; a `bash
  build-commo.sh > log` wrapper sees exit 143 even on success (the log ends
  with `comms stack OK`). Pre-existing.

## G1.5 — the `--datapackage` importer

`atak-headless --datapackage FILE.dp` resolves an ATAK data package instead
of hand-feeding flags: `host:port[:proto]` from `preference.pref`'s
`cot_streams` `address0`, the `location_units` callsign, and the PKCS#12
pair (firecrypt `ClientFile`/`CAFile` when present, else the trust-named
file and the other) extracted to a private temp dir. Precedence: explicit
flags > package > defaults; `MACTAK_CERT_PASS` overrides the package's
firecrypt `Password` (default `atakatak` unchanged). Failure → one line +
exit 2.

- `DataPackage.java` (+ `ConnectOptions.java`, the flag/package precedence
  merge described above) is pure JDK (java.util.zip + DOM) — no natives — so
  the canary (`test/datapackage.sh`, a step of the `jvm-tests` CI job)
  compiles them with Zulu 8 and runs javac+java assertions against a
  synthetic package (`test/fixtures/make-datapackage.sh`: openssl
  self-signed p12s + pref XML; the recipe is committed, no binary fixture),
  including every precedence rule. No JUnit, matching the repo idiom.
- The launcher src is compile-gated in the same job (`test/compile-gate.sh`,
  #29): atak-headless's own javac line (`-Xlint:all -Werror`, the same
  mavenLocal-first/transplants-fallback classpath), with the commo API
  classes javac'd from the checkout — CI previously never type-checked
  `HeadlessCLI.java` at all.
- Hardening matches the CoT side's posture: DOCTYPE disallowed and external
  entities off when parsing `preference.pref` (XXE); zip entry names with
  `..`, absolute paths or backslashes are refused before extraction
  (Zip-Slip), and extraction targets are re-verified canonically under the
  temp dir; every entry is size-capped while it is copied (#31) — 16 MiB for
  `preference.pref`, 64 MiB per PKCS#12 — so an oversize fails with a
  one-line `exceeds N bytes` message (exit 2) instead of filling the disk or
  the heap, and a refused cert leaves no partial file in the cert dir; the
  address line (#32) takes a bracketed IPv6 literal and stores it unbracketed
  (what commo's addStreamingInterface takes), range-checks the port to
  1–65535 on both the package and the `--connect` paths, matches the proto
  token exactly (`ssl`/`tls`/`tcp`; `dtls` is refused instead of mislabeled
  ssl), and refuses a client/truststore pair sharing one basename — the cert
  dir keeps one flat file per basename, so the two could not coexist; the
  resolved line never prints the password.
- **The key names are verified against the fixture only, not yet against a
  real OpenTAKServer package** (none existed on this machine). The parser is
  deliberately liberal (`addressN`/`callsign` wherever they appear, firecrypt
  by substring), but the first live-package run must confirm the
  `cot_streams`/`location_units`/`plugin_firecrypt` spellings before this
  replaces flag plumbing at a demo.

## Follow-ups (G1 done)

- OTS upstream: `auto_delete` per-EUD queues; silent drop on callsign
  collision. Worth filing.
- The `[commo-diag]` WARNING probes (patch 0001) are loud on every run; demote
  or gate behind `MACTAK_COMMO_DIAG` once the stack has been quiet for a while.

## G1.6 — wave 4: JNI exception hygiene + attrib-location guards (engine C++)

Four patches in `dev/g1/patches/`, cut from the wave-3 audit (F1–F4) after a
line-by-line smell test against the engine sources. Evidence: `make build`,
`make test-render`, `make test-render-window` all PASS with the full set
applied (`build-native.sh` applies `dev/g1/patches/*.patch` to the fresh
engine copy, -p3).

- `jnilayer2-exception-clears.patch` (F1) — `ManagedGLLayer2` clears (report
  once + `ExceptionClear`) a Java exception thrown by `getSubject()`,
  `draw()`, `release()`, `start()` or `stop()`; the ctor also skips its
  marshal/adapt pair while one is pending, leaving `csubject` null. Mirrors
  the draw-only fix the G2 wave already made to `ManagedGLMapRenderable2`.
  Hazard documented, not patched: `getSubject()` returns `Layer2&`
  (`GLLayer2.h`), so a null subject stays unguarded by design — callers of
  `ManagedGLLayer2::getSubject()` must test the `shared_ptr` before use.
- `jnilayerspi2-exception-clears.patch` (F2) — `ManagedGLLayerSpi2::create`
  maps a thrown Java `create()` to `TE_Err` (describe + clear) instead of
  `TE_InvalidArg` with the exception pending. Caller contract proven:
  `GLLayerFactory2.cpp:110` advances to the next SPI on any non-OK, so the
  pending exception used to poison the next SPI's JNI calls. A clean null
  return still keeps `TE_InvalidArg`.
- `attrib-location-guards.patch` (F3) — the two live per-frame bugs are in
  the terrain draws: the planar `TerrainTile*` shader variants declare no
  `aEcefVertCoords` (location -1) and both renderers select planar for
  non-ellipsoid geometry (`GLGlobe.cpp:2902`, `GLMapView2.cpp:3098`), so
  `drawTerrainMeshesImpl`'s unguarded enable/disable of the ECEF attribute
  raised `GL_INVALID_VALUE` on every 2D terrain frame. The
  `GLBatchGeometryRenderer3` AA-lines/point guards in the same patch are
  defensive only: a single cached program uses all 8 queried attributes, so
  -1 fires solely on a compile/link failure. CHANGELOG wording keeps the
  split honest (per-frame bug vs hardening).
- `terraintile-ecef-ge.patch` (F4) — one token: `GLTerrainTile.cpp:508`
  tested `aEcefVertCoords > 0` for the ECEF local frame, rejecting a
  legitimate location 0 while the same file's enable/pointer code (and the
  wave-2 `terraintile-guard` patch at :580) accepts `>= 0`.

Report-only observations (seen in the audit, deliberately not patched):

- `GLBatchGeometryShaders.cpp:179` stores into the wrong function-local —
  a dead store today (readers use the correct local), harmless but a
  foot-gun.
- `GLMapView2.cpp:3250` picks the terrain frame by SRID where `GLGlobe`
  picks by capability — divergent selection logic for the same shader
  family; fragile if a third path grows.
- The reference-returning `getSubject()` pattern (null → deref hazard) is
  endemic across the JNI bridge; wave 4 covers the `ManagedGLLayer2`
  surface only.

## G1.7 — wave 5: JNI bridge hygiene sweep (F5–F13) + two engine fixes

Seven patches in `dev/g1/patches/`, cut from the wave-5 smell test (F5–F13
plus the two wave-4 report-only engine observations, A and B) after a
line-by-line verification pass. Patch mechanics as wave 4: scripted edit of
a pristine tree staged at `/tmp/g1wave5/{a,b}/tmp/takeng-src/`, `diff -u`
with explicit `a/…`/`b/…` labels, applied by `build-native.sh` at -p3 in
glob order. The generator/verifier (`gen_patches.py`) and the roster audit
(`audit_roster.py`) are committed as reference tooling under
`dev/g1/tools/wave5/` — parameterized (`G1_REPO`, `G1_STAGING`) so a fresh
clone plus the pinned `src/` tree (CONTRIBUTING.md) reproduces them; see
that directory's README.

Engine fixes (the two wave-4 report-only items, now closed):

- `glbatchshaders-dead-store.patch` (A) — `GLBatchGeometryShaders.cpp:179`
  stored `aRotation`'s uniform location into `aColor`; the real `aColor`
  attrib lookup overwrote it lines later. Dead store removed, nothing
  else.
- `glmapview2-srid-capability.patch` (B) — `GLMapView2.cpp:3250` picked
  the terrain local frame by `tile.data_proj.srid == state.drawSrid`,
  while `GLGlobe.cpp:3048` picks by the active shader family
  (`shader.aEcefVertCoords >= 0` — the ECEF shaders consume the
  re-projected mesh). In planar mode with elevation data already in the
  draw SRID the planar pass concatenated the projected data's local
  frame. Aligned on capability; `shader` was already in scope and the
  wave-4 attrib guards use the same member three lines up.

JNI guards (F5–F13; the wave-4 house pattern throughout — describe once,
`ExceptionClear`, then a neutral return or a clean continue; the
`jioproviderfactory` sites use that file's own bare-`Clear` template):

- `jglobe-listener-guards.patch` (F5) — the nine `CallbackForwarder`
  dispatches; `onMapMoved` fires per camera frame (the wave-4 F2 poisoning
  pattern). `impl` is a strong global ref, so the missing guard was the
  only defect.
- `jglmapview-forwarder-guards.patch` (F6) — the two
  `CameraChangedForwarder` dispatches returned bare `TE_Ok` past an
  unguarded `CallVoidMethod`; a throw now maps to `TE_Err`. The rest of
  the file (weak-ref + cleared-check discipline) is untouched.
- `managedrendercontext-guards.patch` (F7) — all 16 sites: the scalar
  getters capture, guard and return their neutral value (a throw leaves
  garbage in the JNI call's return register), the dispatch methods map to
  `TE_Err`, the dtor's `destroyChildContext` clears (no return possible),
  `createChildContext` guards both the capability probe and the create
  call, and the `getRenderSurface` helper clears so a throw no longer
  escapes the `NOTHROWS` constructor with the surface left mid-init.
- `projection-math-interop-guards.patch` (F8/F9/F10, F11 riding) —
  `ManagedProjection::forward/inverse` (the per-frame projection marshal
  path) guard before each null check; the shared `Interop_create` GeoPoint
  helper clears its own throw so its null return is clean for every
  caller; core `Interop`'s per-frame `MapSceneModel` export no longer
  returns `TE_Ok` past a failed `NewObject`, and its in-place marshal's
  `init()` dispatch is guarded; the `math/Interop` marshals gain
  null-argument guards (F10 — a null `jobject`/`Rectangle2*` there is a
  JVM crash, not a catchable exception) plus `NewObject` guards; and the
  model resource-map marshal loop is guarded per call (F11, defensive —
  entry-check-gated today).
- `ioproviderfactory-guards-and-filecount.patch` (F13+F12) — `remove` and
  `mkdirs` join the file's canonical `ExceptionCheck → Clear → TE_Err`
  their 11 siblings already had (a `SecurityException` fed garbage into
  the jboolean — coin-flip result, exception pending), as does
  `createTempFile`'s `getAbsolutePath` follow-up (caught by the post-patch
  sweep, same pattern); and `getFileCount`'s second probe is
  `isDirectory`, not a duplicated `isFile` — the directory branch was
  unreachable, so every directory returned `TE_IllegalState` from the
  fall-through (F12, a real logic bug).

Roster validation (`audit_roster.py`, scripted re-sweep — validates, does
not discover): heuristic is JNI `Call*`/`New*Method` sites with no
`ExceptionCheck` in the following 8 lines. Pristine tree: 34 files / 151
sites (the planning pass pinned 18 files with a stricter result-used
filter; every planning-roster file appears here). Post-patch: 27 files /
102 sites, and the eight touched files drain to zero or to the residuals
below — jglobe 9→0, jglmapview 2→0, ManagedRenderContext 16→0, math
Interop 2→0, model Interop 4→0, jioproviderfactory 5→0,
ManagedProjection 9→6, core Interop 5→2. (102 is the wave-5-close
number; wave-6's F15 `ExceptionClear` hygiene in `common.cpp` drained
two more sites, so the same audit on post-wave-6 main prints 27 files /
100 sites — see the committed enumeration below.)

### The defensive roster — committed record (post-wave-6 main)

Re-derived 2026-11-08 with `dev/g1/tools/wave5/audit_roster.py` against
the wave-5
verify staging (pristine + gdal-drift + all 29 committed g1 patches —
`gen_patches.py` stages the verify tree on demand; the full recipe is
`tools/README.md`'s quickstart). 27 files, 100 unguarded sites, the
standing "defensive / not this wave" list:

```text
  interop/formats/quantizedmesh/ManagedQMESourceLayer.cpp: 15
  interop/renderer/ManagedTextFormat2.cpp: 10
  interop/elevation/ManagedElevationChunk.cpp: 9
  interop/elevation/ManagedElevationSource.cpp: 9
  interop/core/ManagedRenderSurface.cpp: 7
  interop/core/ManagedLayer.cpp: 6
  interop/core/ManagedProjection.cpp: 6
  interop/feature/ManagedFeatureDataSource2.cpp: 6
  common.cpp: 4
  interop/feature/Interop.cpp: 4
  interop/core/ManagedMapRenderer2.cpp: 3
  interop/core/Interop.cpp: 2
  interop/java/JNIPrimitive.cpp: 2
  interop/renderer/core/ManagedGLMapRenderable2.cpp: 2
  jgeocalculations.cpp: 2
  vsi_jfile.cpp: 2
  c3dt/jgltf.cpp: 1
  interop/JNINotifyCallback.cpp: 1
  interop/core/ManagedVisibilityListener.cpp: 1
  interop/elevation/Interop.cpp: 1
  interop/java/JNIPair.cpp: 1
  interop/java/JNIRunnable.cpp: 1
  interop/renderer/core/ManagedGLLayer2.cpp: 1
  interop/util/ManagedDataInput2.cpp: 1
  jgllinebatch.cpp: 1
  jnativegllayerspi2.cpp: 1
  jprojectionfactory.cpp: 1
```

Report-only residuals (deliberately not patched this wave):

- `ManagedProjection` scalar getters ×6 (`getSpatialReferenceID`, min/max
  latitude/longitude, `is3D`) — scene-setup cadence, not the per-frame
  marshal path; the F7 capture-and-guard shape applies verbatim when a
  later wave picks them up.
- core `Interop` `Interop_wrap` NativeProjection `NewObject` ×2
  (pristine `Interop.cpp:190`/`:200`) — adapter-construction path, not
  the per-frame export.
- The systemic `*_class_init` failure masking (returns `true`
  unconditionally) — unchanged since the smell test; a failed class init
  turns every later call on those method IDs into undefined behavior.
  Worth its own wave.
- `jnativegllayer3.cpp` remains clean; the `NewWeakGlobalRef` enum
  caching pattern is OK as found.

## G1.8 — wave 6: `*_class_init` failure-masking sweep (F14) + wave-5 residual closures (F15–F18)

Eleven patches in `dev/g1/patches/`, cut from a scripted audit of every
class/init function in the JNI tree (F14) plus the three wave-5
report-only residuals (F15–F18). Patch mechanics as waves 4/5: scripted
edit of the post-wave-5 tree staged at `/tmp/g1wave6/{a,b}/tmp/takeng-src/`,
`diff -u` with explicit `a/…`/`b/…` labels, applied by `build-native.sh`
at -p3 in glob order — patch names chosen so every wave-6 patch that
touches a file a committed patch also touches sorts strictly AFTER it
(e.g. `jglobe-sweep-guards` after `jglobe-listener-guards`,
`projection-sweep-hygiene` after `projection-math-interop-guards`). The
audit/generator/verifier (`class_init_audit.py`, `guard_inits.py`,
`fix_inline.py`, `gen_patches.py`) live in `/tmp/g1wave6/`.

Audit numbers (live desktop TUs; `c3dt/`, `vsi_jfile.cpp` and
`jvsijfilefilesystemhandler.cpp` are compiled out and were skipped) —
canonical, re-derivable with `dev/g1/tools/wave6/class_init_audit.py`
and recorded in `tools/README.md`: pre-sweep tree a — fully masked 42
(lookups present, zero guards, unconditional `return true`) · partial 4
(wave-5 enum-section guards only) · fully guarded 1
(`jgeocalculations.cpp`, the reference shape) · no-lookups 16; 25
`static bool clinit = …` call sites never read their result. Post-sweep
tree b — fully masked 2 · partial 11 · fully guarded 35 · no-lookups
18; unread-result callers 23. The bucket shifts between the trees
(no-lookups 16→18, partial 4→11) are classifier artifacts of the
sweep's own edit shapes, not real lookup changes — the audit counts
guard and lookup lines as they sit in the file, and the macro half
moved lookups inside `SET_METHOD_DEFINITION` while the hoisted-ID
rewrites deleted inline ones. (This paragraph's first draft misquoted
the audit — "46 init functions …, 3 partial …, fully guarded 34";
corrected to the tool's own output.)

- `jni-class-init-guards.patch` (F14, 27 files) — the sweep: every
  `FindClass`/`Get*ID` assignment in every masked init body now guards
  (`if(!x) return false;`, the `jgeocalculations` house shape); inline
  `New*Ref(env.GetStaticObjectField(E, env.GetStaticFieldID(E, …)))`
  chains hoist the field ID into a guarded `jfieldID` local and reuse it.
- The macro half of F14 (8 files) — `SET_METHOD_DEFINITION` /
  `SET_FIELD_DEFINITION` definitions in `ManagedLayer`,
  `ManagedRenderContext`, `ManagedVisibilityListener`, `ManagedGLLayer2`,
  `ManagedGLMapRenderable2`, `jglmapview`, `jglobe` and core `Interop`
  gained the guard lines inside the macro (the generator deliberately
  leaves preprocessor lines to hand edits).
- `common-onload-classloader-guards.patch` (F15) — `JNI_OnLoad` guards
  the `ClassLoader_class.id`/`loadClass` lookups (`return JNI_ERR`) and
  `ATAKMapEngineJNI_equals` guards its `java/lang/Object` lookups
  (`return false`).
- `projection-sweep-hygiene.patch` (F14 for the four files wave-5's
  `projection-math-interop-guards` also touches — core/math/model
  `Interop.cpp` + `ManagedProjection.cpp`; sorts after it by name).
- The entry/getter half of F16/F17 lives in the same file set: core
  `Interop` `GeoPoint_interop_entry`/`NativeProjection_interop_entry`
  become `bool` and all five call sites gate (`Interop_copy` ×2 →
  `TE_IllegalState`, `Interop_create`/`Interop_wrap` ×2 → `NULL`) — the
  wave-5 `NewObject` ×2 residual; the six `ManagedProjection` scalar
  getters bail on a null method ID — doubles `NAN`,
  `getSpatialReferenceID` 0, `is3D` false.
- `textformat2-class-init-consumer-guards.patch` (F18) — the sweep
  showed every lookup in `ManagedTextFormat2_init`/`Factory_init` fails
  on desktop JVMs (com.atakmap.android/`android.graphics` classes are
  absent), so the consumers gate on the method IDs they use:
  `getStringWidth`/`getCharWidth`/`getCharHeight`/`getDescent`/
  `getStringHeight`/`getBaselineSpacing` return 0, `getFontSize` 0,
  `loadGlyph` and `createTextFormat` return `TE_Err` — graceful
  degradation instead of a null-methodID crash if the desktop ever
  routes text through these classes.
- One patch per remaining wave-5-overlapping file, name-sorted safe:
  `jglobe-sweep-guards`, `jglmapview-sweep-guards`,
  `managedrendercontext-sweep-guards`,
  `ioproviderfactory-sweep-init-guards`, `jnilayer2-sweep-guards`,
  `jnilayerspi2-sweep-guards`, `jni-renderable-sweep-guards`.

### Traps found on the way (do not rediscover these)

- **Do not guard `FindClass("com/atakmap/map/EngineLibrary")` in
  `JNI_OnLoad` with an early return.** The first cut of F15 did exactly
  that and failed `make build`'s canary 3/3 deterministically (2/2 with
  the guards, 1/1 without, bisected to the ClassLoader hunk alone): the
  JVM eagerly *links* `EngineLibrary` at that `FindClass`, its
  verification resolves `new BouncyCastleProvider` (g2 NOTES item 4),
  and the g1 smoke classpath carries no bcprov — the guard turns a
  tolerated NULL into a fatal `NoClassDefFoundError` out of
  `System.load`. The Class/EngineLibrary sub-block is failure-tolerant
  by design (`ATAKMapEngineJNI_findClass` null-guards `library`/`runtime`
  downstream); the wave-6 form keeps the original control flow and adds
  `ExceptionClear` hygiene only. The `id`/`loadClass` guards stay — they
  cannot fire on a healthy JVM (the wrapper clears internally, no
  pending exception leaks).
- The generator's first cut kept the inline `GetStaticObjectField`
  statement alongside its hoisted `jfieldID` copy (duplicate lookup);
  `fix_inline.py` rewrites the statement to consume the hoisted ID.
  Verified by re-grepping the tree for the inline shape (0 hits).

### Report-only residuals (deliberately not patched this wave)

- Bare `NewWeakGlobalRef` enum-cache results (`ManagedElevationSource`,
  `ManagedFeatureDataSource2`) — the wave-4/5 house style leaves them
  unguarded (null only on OOM); kept consistent.
- 23 `clinit` results still unread at their call sites (25 pre-sweep;
  the sweep's own F16/F17 entry gates closed 2 — the `GeoPoint` and
  `NativeProjection` clinit locals in core `Interop` are read now).
  Gating the remaining consumers is the wave-7 item now that the init
  bodies themselves report failure honestly.
- F-1, recorded 2026-11-08, deliberately untouched: `MapRenderer3_init`
  binds the `setFocusPointOffset` slot from `GetMethodID(…, "isAnimating",
  "(FF)V")` (`jni-class-init-guards.patch` line 51; pristine
  `ManagedMapRenderer2.cpp:179`). No Java side has that method —
  `isAnimating` exists only as `()Z` (inherited from `MapRenderer2`);
  `(FF)V` is the signature of the inherited
  `setFocusPointOffset(float,float)` — so the lookup fails at runtime by
  construction. Dead twice over: the member is declared and bound but
  never consumed anywhere. The wave-6 guard wraps the failing lookup, so
  the init reports failure honestly — harmless while nothing drives the
  modern `MapRenderer3` path, a guaranteed hard-fail of `MapRenderer3_init`
  the moment G2/G4 wires it. Wave-7 fix: delete the slot (struct member +
  binding + guard), or bind `"setFocusPointOffset" "(FF)V"` instead if
  that path turns out to need it.
- The wave-5 residuals list shrinks by three: scalar getters ×6 (done),
  `Interop_wrap` `NewObject` ×2 (done), systemic class-init masking
  (done); `jnativegllayer3` stays clean.

Evidence: `make build` PASS (stub + JVM smoke 3/3 + commo smoke),
`make build-angle` PASS, `make test-render` PASS (bare + GeoJSON +
MBTiles basemap), `make test-render-window` PASS (bare + layer,
`glErrors=0`). The patch verifier replays gdal-drift + the 18 committed
patches + the 11 wave-6 patches onto a pristine engine copy in glob
order and asserts the JNI tree equals the edited tree byte-for-byte.

## G1.9 — the JNI guards on a real desktop JVM (`make test-jni`, canary 3/4)

Waves 4–6 verified the JNI hygiene work statically (audits, patch
replay, byte-compare). G1.9 points GTest at a live desktop JVM so the
guards are exercised, not just read: `dev/g1/jni-tests/` compiles four
test TUs into TWO products (both staged to `native-dist/` by
`build-native.sh`, whose canary list grew 2→4):

- **Guards mode** — the standalone binary boots a JVM in-process from
  `libjli` (`jni_test_env.hpp`, probe order from `jni_boot.c`) with an
  EMPTY classpath (`run.sh` enforces `env -u`). 7 pins: the wave-5/6
  class-init guards bail neutrally on the missing classes
  (createTextFormat→TE_Err, its 8 consumers→0/0.f, loadGlyph→TE_Err,
  Matrix/Rect interop marshal→TE_IllegalState) and `JNI_OnLoad` fails
  with `JNI_ERR` leaving a pristine JNIEnv instead of dying on a
  pending exception.
- **Kernel mode** — the same TUs as a shared library
  (`libtakengine-jni-tests.dylib`) loaded by `JniTestsMain` UNDER THE
  JAVA LAUNCHER, with the takkernel jars (mavenLocal-else-committed,
  the smoke's rule). JNI_OnLoad runs in the healthy launcher context,
  then 6 pins drive the Java-backed IOProviderFactory proxy over real
  files: getFileCount directory=2 / file=1 / missing=TE_InvalidArg,
  createTempFile on a bad dir→TE_Err, delete of a missing path→TE_Err,
  DatabaseFactory_create on a bad URI→TE_Err — the last two asserting a
  pristine JNIEnv after the failure (the wave-5 ExceptionClear guard).

Desktop-reachable vs deferred/audit-only: the guards suite covers every
class-init failure reachable with an empty classpath (interop/render
text + marshal + onload families); guards whose lookups only fail on
Android (GL surface/listener classes the desktop jars always provide)
stay audit-covered from waves 5/6 and are not desktop-reachable; the
IOProviderFactory family is the one branch a desktop JVM can exercise
with real Java behavior, which is what kernel mode pins. `run.sh`
exits 0 without a JDK 8 (the native build itself needs none); CI's
native job installs Zulu 8 first and uploads
`takengine-jni-guards.xml` + `takengine-jni-kernel.xml`.

Traps found on the way (do not rediscover these):

- **Kernel mode must run under the launcher, not a raw in-process
  boot.** On Zulu 8 aarch64, when the VM itself invokes `JNI_OnLoad`
  (`System.load`), the first `ATAKMapEngineJNI_findClass` call dies
  inside hotspot's `jni_FindClass` — `java_lang_Class::as_Klass(NULL)`
  at `common.cpp` 157 (hs_err + `atos` on the staged dylib). The SAME
  boot is fine when our own code calls `JNI_OnLoad` via dlsym (guards
  mode does exactly that), and the same library is clean under the
  `java` launcher — the smoke's boot. Hence the shared-library suite:
  `JniTestsMain` (Java) System.loads core + glue (JNI_OnLoad runs
  there) + the tests dylib, then hands gtest argv to
  `Java_JniTestsMain_takengineJniTestsMain` (module_main.cpp), which
  stashes the JNIEnv for the fixture (`takengine_jni_tests_env` —
  linked into both products; ld64 refuses undefined weak imports in
  executables). `-Djava.library.path` via `JNI_CreateJavaVM` also
  proved unreliable (searched but not honored) — moot under the
  launcher, which sets it normally.
- **`FindClass("com/atakmap/map/EngineLibrary")` fails by design on
  this classpath** — its verification resolves
  `new BouncyCastleProvider` and the smoke's jar set carries no bcprov;
  the NULL is tolerated (`ClassLoader_class.library` stays NULL, the
  findClass classloader fallback skips it), which is exactly what the
  guards-mode onload pin asserts. See §G1.8's trap: no early-return
  guard, no extra jars.
- **`IOProviderFactoryProxy::listFiles` dropped every child** —
  `STLVectorAdapter contents_w;` default-constructs the adapter onto
  its own private store; the java `list(File)` call returned correctly
  (instrumented: absPath right, array len=2) but the caller's vector
  stayed empty, so `getFileCount(dir)` reported `TE_Ok`/0 and
  `length(dir)` 0. Fixed by
  `patches/ioproviderfactory-listfiles-adapter-bind.patch` — both call
  sites (getFileCount's dir branch AND length's, same latent bug) now
  bind `contents_w(contents)`. The pin caught it as designed: kernel
  3/6 on the first healthy-boot run, 6/6 after.
- The JNI export must be `extern "C"` — without it `System.load`
  succeeds but the first native call throws UnsatisfiedLinkError.

Evidence: `make build` PASS — canaries 4/4 (dlopen; engine 33/33;
jni-tests guards 7/7 + kernel 6/6; JVM in-process smoke) + commo
smoke; `make lint` PASS (0 issues).

## G1.10 — correctness audit (2026-11-09, branch `audit/g1-correctness`)

A bugs-and-correctness pass over everything under `dev/g1/` plus the
engine code its patches touch. Fixed on the branch:

- `stlvectoradapter-bind-contents.patch` (new) — the same unbound
  `STLVectorAdapter` bug G1.9's `ioproviderfactory-listfiles-adapter-bind.patch`
  fixed in the jni proxy, at its two core-engine sites:
  `atakmap::util::getDirContents` (IO.cpp) and the filtered `IO_listFiles`
  (IO2.cpp). Each default-constructed `contents_w`, handed it to
  `listFiles`, then looped over a separate, never-filled `std::vector
  contents`, so every directory came back empty. The fix binds the
  adapter: `contents_w(contents)`. The jni hunks were dropped from this
  patch in favour of G1.9's; the series applies at `--fuzz=0` with or
  without it.
- `megatexture-sharetile-comma-operator.patch` regenerated — its hunk
  header claimed 6 lines for a 7-line hunk, so it only ever applied with
  fuzz 1. `build-native.sh`/`build-commo.sh` now patch with `--fuzz=0`,
  so context drift fails the build instead of landing "close enough".
- `build-native.sh`/`build-commo.sh` EXIT trap — `kill -- -$$` signalled
  the script's whole process group. Run from a terminal, the script leads
  its group, so it SIGTERMed itself: exit 143 after a successful build,
  and the rest of the trap was skipped. Under `make` it was a no-op. It
  now kills only the script's own background jobs (`jobs -p`).
- `HeadlessCLI` — uid/callsign are XML-escaped in the presence/marker
  CoT (a callsign like `O'BRIEN` made every send unparseable); the
  `--send-marker` pair must be finite and in range, and is normalized to
  plain decimal before it reaches the XML; `--duration` must be >= 1.
- `ConnectOptions` — when the address comes from the package, its proto
  must agree with the cert pair. An `:ssl` address with no certs would
  connect in plaintext; a plaintext address with shipped certs would open
  TLS. Both are refused (exit 2) instead of failing at connect.
- `DataPackage` — a same-basename pair split by a `trust` directory
  (`certs/ca.p12` + `certs/trust/ca.p12`) classified as one of each and
  extracted both to one file, the truststore overwriting the client.
  It's now refused like any same-basename pair. The `ClientFile` hint,
  read but never used before, now outranks the "trust" substring. An
  `addressN` index past int range no longer escapes `open()` as an
  unchecked `NumberFormatException`.
- `CotEvent` — `<point>` and `<detail><contact>` are read as direct
  children. The document-wide `getElementsByTagName` could pick a nested
  `<contact>` (inside `<link>`, chat) or a `<point>` inside `<detail>`.
- `LayerStore.bounds()` — the union now covers Z as well as X/Y.
- `test/layer.sh` — it promised "exactly N" features but
  `--expect-features` is a floor. It now also matches LayerCLI's PASS
  count exactly, so a duplicated import fails.

`DataPackageSelfTest` gains seven assertions for the above. Run against
the pre-audit `DataPackage`/`ConnectOptions`, they fail (A/B checked).

## G1.11 — correctness audit, pass 2 (2026-11-09, branch `g1/audit-pass-2`, PR #75)

Covers the `dev/g1/` files §G1.10 didn't reach: `TrackStore`, `LayerCLI`,
`CotXml` (split out by the CoT canary), `run.sh`, the `atak-headless`
launcher, `fake-cot-server.py`, `smoke/`, `jni-tests/run.sh`, `jni-extra/`,
`gen-jni-headers.sh` and the test scripts. Every fix is in
`dev/g1/headless/`; no engine patch changed.

Traps found on the way (do not rediscover these):

- **sqlite keeps `"NaN"` as text in a REAL column, and a numeric read of
  it is 0.0.** The engine's `DatabaseImpl` binds Strings only, so
  `TrackStore.record` bound `Double.toString(NaN)`. A CoT `<point>` with
  no `lat`/`lon` parsed as NaN and read back from the tracks DB as 0,0;
  an absent `hae` read back as 0.0 m. Witness, Python's sqlite3 on the
  same column types: `('NaN', 'text', … , 0.0)`. **Guard:**
  `CotEvent.parse` refuses a `<point>` without a finite, in-range
  lat/lon (`<point> has no lat`, `… is out of range`); `TrackStore` binds
  an unknown `hae` through `NULLIF(?, '')` (SQL NULL) and reads NULL back
  as NaN. Pinned by `CotEventSelfTest` (9 `<point>` assertions).
- **`Double.parseDouble` is not a CoT number parser.** It also takes
  `45f`, `12d`, `0x1p5`, padded `" 1 "` and `Infinity`, which no other
  CoT parser reads. §G1.10 normalized these on the send side
  (`CotXml.coordinate`); the receive side still took them. **Guard:**
  `CotEvent` matches a plain decimal grammar before parsing
  (`<point> lat=45f is not a number`); only hae/ce/le may also be the
  literal `NaN` (unknown).
- **Escaping `& < > ' "` doesn't make a string safe for XML 1.0.** Any
  other C0 control character can't appear in a document at all, even
  as a character reference. One BEL in a callsign made every presence
  and marker unparseable: `An invalid XML character (Unicode: 0x7) was
  found in the value of attribute "callsign"`. Tab/LF/CR are legal but
  a parser normalizes them to spaces inside an attribute. **Guard:**
  `CotXml.xmlEscape` writes tab/LF/CR as `&#9;`/`&#10;`/`&#13;` and
  replaces other C0 controls, U+FFFE/U+FFFF and unpaired surrogates with
  U+FFFD; `CotEventSelfTest` round-trips a control-character callsign
  through `CotXml.presence` → `CotEvent.parse`.
- **`System.exit` inside a `try` skips its `finally`.** `HeadlessCLI`
  exited from the `try` and from both `catch` blocks, so the `finally`
  that closes the tracks DB never ran on a failure path; it was dead
  code. **Guard:** the exit code is computed in the `try`/`catch` and
  `System.exit` runs once, after the `finally`. Pinned on the success
  path: the hermetic round-trip asserts both clients exit 0 through
  that single exit (`run.sh` fails on `rc_a`/`rc_b` ≠ 0). Not pinned:
  the DB close on a failure exit. That path needs a commo or engine
  failure mid-run, which no CI job injects; the fix's structure is the
  only guard there.
- **`run.sh` couldn't tell a dead client A from a slow one.** It
  polled A's log for `iface-up` for the full 90 s even when A had
  already exited (connect refused, bad cert, native load). **Guard:**
  each poll also checks `kill -0 "$pid_a"`, and a dead A that never
  logged `iface-up` fails at once with A's exit code.

Reviewed, no change needed: `LayerCLI`/`LayerStore` argument handling;
the smoke and jni-tests runners; the `jni-extra` shims (null-checked
UTF chars, each OpenSSL provider loaded once); `gen-jni-headers.sh`.
`fake-cot-server.py` has one test-fixture-only quirk: a non-blocking
`sendall` that hits a full peer buffer drops that client.

Evidence (this box, JDK 21, then CI on #75's head `adddefd`):

```text
$ bash dev/g1/headless/test/cot.sh
PASS: missing lat refused: <point> has no lat
PASS: Java-only number forms (45f, 0x1p5) refused: <point> lat=45f is not a number
cot-selftest: ALL PASS

# A/B: the same CotEventSelfTest against main's CotEvent/CotXml
FAIL: missing lat refused: null
FAIL: xmlEscape replaces characters XML 1.0 cannot carry
[Fatal Error] :2:4: An invalid XML character (Unicode: 0x7) was found in the value of attribute "callsign" and element is "contact".
```

12 of the 13 new assertions fail against main. The 13th, inclusive
range bounds, passes on both, so the new checks don't over-reject.
Compile gate: the launcher's file set under `-source 8 -Xlint:all
-Werror` (plus `-Xlint:-options` on JDK 21) compiled 22 classes against
commo's API from the pin and the transplant jars. `datapackage.sh`:
`datapackage-selftest: ALL PASS`. shellcheck and markdownlint: 0 issues.

CI (`cot-roundtrip.yml` and `ci.yml` on `adddefd`). The hermetic
round-trip runs `TrackStore` and the `HeadlessCLI` exit path end to
end, and `layer.sh` passed in `native-engine` (ci.yml run 42724482488):

```text
headless: summary received=15 persisted=15 ifaceUpSeen=true presenceSent=8 markerSent=1
headless: track uid=fake-cot-001 type=a-f-G-U-C callsign=- lat=37.774900 lon=-122.419400 time=2026-11-10T00:05:11.481Z fixes=8
[g1-roundtrip] sqlite3 …/roundtrip-a.sqlite: 15 fix(es), 1 for B's marker
[g1-roundtrip] PASS — both ifaces up, B's presence+marker relayed to A, A's presence relayed to B, both persisted in the tracks DBs
```

## G1.12 — GDAL 3 axis order on the C++ OGR path (2026-11-10, branch `g1/ogr-axis-order`, PR #76; residual of G2 trap #48)

Found in audit pass 3. G2.4b b.2 pinned `OAMS_TRADITIONAL_GIS_ORDER` on
the Java SRSes (`GdalLibrary.EPSG_4326`, `GdalDatasetProjection2`); the
engine's C++ builds its own. `OGR_Content2::getLayerTransform`, the
offline-layer path behind `atak-headless --layer` and G2's
`--layer` render, transforms any layer whose SRS isn't EPSG:4326 to a
plain `importFromEPSG(4326)`. On GDAL ≥ 3 that target is lat,lon by
authority order, and the engine reads x as longitude. The same shape is in
`OGRFeatureDataStore`, `OSRProjectionSpi`, `GdalDatasetProjection`,
`jgdallibrary.cpp` and `josrutils.cpp`.

```sh
bash dev/g1/headless/test/layer.sh   # CI: native-engine + render-angle
```

### The patch

`dev/g1/patches/gdal3-axis-order-cpp-default.patch` sets
`OSR_DEFAULT_AXIS_MAPPING_STRATEGY=TRADITIONAL_GIS_ORDER` as the first
statement of the engine's native `GdalLibrary::initImpl`, before
`GDALAllRegister`. GDAL ≥ 3.5 reads it whenever an `OGRSpatialReference`
is constructed, so every C++ SRS from then on is lon,lat, exactly what
GDAL 2.4 gave the engine. One line covers all the sites above, plus any
not yet reached. Per-site `SetAxisMappingStrategy` calls would have to
find every SRS the engine builds. CI's Homebrew GDAL is 3.13.3.

Every OGR layer path reaches `initImpl` first: `LayerStore`'s
constructor calls `NativeGdal.init` before it registers the provider, and
G2's `RenderSmoke`/`WindowApp` open layers through `LayerStore`.

Traps found on the way (do not rediscover these):

- **The engine's C++ OGR transforms swapped lat/lon on GDAL 3** for any
  layer in a projected CRS. Witness, a GDAL 3.8 program mirroring
  `getLayerTransform` on files `layer.sh` now builds:
  `u.shp layer auth=32610 engine-transform x=37.7955 y=-122.3937`. That's
  Ferry Building's latitude in the longitude slot. EPSG:4326 layers skip
  the transform, which is why every committed fixture passed. **Guard:**
  the patch above; `layer.sh` opens a UTM 10N shapefile and an EPSG:3857
  GeoPackage built from the fixture and checks Ferry Building's position.
- **A feature-count canary can't see swapped axes.** `layer.sh` passed
  with every coordinate flipped, because the counts still matched.
  **Guard:** every fixture-derived leg now checks Ferry Building's
  envelope (37.7955, −122.3937, within 1e-4°) as `LayerCLI` prints it.

Evidence (CI, `ci.yml`, `native-engine` job). Before: a dispatch run on
the guard-only commit `fb844ba` (run 42724928764). The EPSG:4326 legs
pass and both projected legs fail with the axes swapped. Note the
count-only `PASS` line under the flipped envelope: the old canary
passed this layer.

```text
[layer-test] ok   sf-points.shp (3 feature(s))
[layer-test] FAIL sf-points-utm10n.shp: Ferry Building at lat/lon -122.39370 37.79550, expected 37.7955 -122.3937
      fid 4294967297   set 1   Ferry Building               Point              [-122.39370 37.79550 .. -122.39370 37.79550]
    PASS: 3 feature(s) opened through FeatureDataStore2
[layer-test] FAIL sf-landmarks-3857.gpkg: Ferry Building at lat/lon -122.39370 37.79550, expected 37.7955 -122.3937
[layer-test] FAIL
```

After: PR #76's run with the patch (head `3738696`, run 42726706344):

```text
[layer-test] ok   sf-points-utm10n.shp (3 feature(s))
      fid 4294967297   set 1   Ferry Building               Point              [37.79550 -122.39370 .. 37.79550 -122.39370]
[layer-test] ok   sf-landmarks-3857.gpkg (8 feature(s))
      fid 4294967297   set 1   Ferry Building               Point              [37.79550 -122.39370 .. 37.79550 -122.39370]
[layer-test] PASS: offline layer(s) opened through FeatureDataStore2
```

`render-angle` shows the same pair: it fails on `fb844ba` and passes on
`3738696`. That run also keeps the Java path green: its "Engine GDAL
georeferencing on GDAL 3" step (`make test-gdal-projection`) passes with
the process-wide option set. The GPKG legs' `no such column:
definition_12_063` line shows up before and after, and on main's
EPSG:4326 leg too. It's G1.3's known-benign noise, unrelated to this
change.

## G1.13 — correctness audit, pass 3: the rest of `dev/g1` (2026-11-10, branch `g1/jni-tests-hygiene`)

Pass 3 covered what §G1.10/§G1.11 didn't reach: the engine patches'
behaviour (applied to the pinned source), `jni-tests/`, the fixtures and
`tools/`, now with the `clean-code` skills' audit procedure (smells
first, then topic rules). Its one engine bug became §G1.12 (PR #76).
Reviewed, no change needed:

- **The whole patch series** applies at `--fuzz=0` against
  ATAK-CIV `889eee2`, the new `gdal3-axis-order-cpp-default.patch`
  included.
- **`vsi-jfile-gdal3-api.patch`** ports exactly GDAL 3's VSI
  interface: byte-count `Read`/`Write`, `ClearErr`/`Error` backed by
  `m_error`, `VSIVirtualHandleUniquePtr`, `shared_ptr` install. Three
  quirks came from upstream unchanged: a 32-bit `jsize` read length,
  `Tell()`'s `-1` feeding `SEEK_CUR`, and `Eof()` true at
  position == size rather than after a short read. None is reachable on
  the G2 GeoTIFF path. Changing them would mean editing upstream lines
  this patch doesn't own.
- **`cpp17-legacy-headers.patch`** is mechanical: it drops the
  dynamic exception specifications C++17 removed. No behaviour change.
- **`tools/wave5`, `tools/wave6`** are one-off generators. Their
  output is the committed patches, which the `--fuzz=0` apply gates;
  all eight compile (`python3 -I -m py_compile`).
- **`jni_test_env.hpp`** boots the JVM correctly, sizes its option
  array exactly (classpath + 8), and turns a failed filesystem install
  into a failure for every later test in the process.

Traps found on the way (do not rediscover these):

- **`remove()` on a non-empty directory fails, and the failure was
  ignored.** The kernel-mode filesystem pins cleaned up with
  `remove(dir)`, which returns `ENOTEMPTY` for a directory holding the
  touched files. Every `make test-jni` leaked a `/tmp/takjni-kernel-*`
  directory. Witness, the same calls in a C program: `before:
  remove(dir) = -1 (Directory not empty); dir still exists: yes`.
  **Guard:** `remove_flat_dir` unlinks the entries, then `rmdir`s with
  an `EXPECT_EQ(…, 0)`, so a leak now fails the pin.
- **A gtest pin that depends on test order passes vacuously when run
  alone.** `JniGuardsOnLoad.LeavesTheEnvClean` checked for a pending
  exception only because the test before it had called `JNI_OnLoad`.
  Under `--gtest_filter=…LeavesTheEnvClean` or `--gtest_shuffle` it
  checked an untouched env and passed. **Guard:** the pin calls
  `JNI_OnLoad` itself. A repeat call only reassigns OnLoad's globals,
  which is safe in a test process. The guards count stays 7.
- **`jni_test_env.hpp` described a weak import that doesn't exist.**
  Its comment said `takengine_jni_tests_env` was weak-imported and NULL
  in the guards binary. But `module_main.cpp` links into both products
  (ld64 refuses undefined weak imports in executables, §G1.9), so the
  null check on the function's address was always true. clang said so
  once per including TU (`warning: address of function
  'takengine_jni_tests_env' will always evaluate to 'true'`; 6 in a CI
  build). Behaviour was right, because the function returns NULL until
  kernel mode stashes an env. **Guard:** the dead check is gone and the
  comment states the real linkage. `-Wpointer-bool-conversion` on
  `onload_guards_test.cpp` goes from 1 warning to 0.
- **`make-datapackage.sh` with no arguments died on `set -u`'s bare
  "unbound variable"** instead of saying how to call it. **Guard:** an
  argument-count check prints `usage: make-datapackage.sh OUT.dp
  [CALLSIGN]` and exits 2.

Evidence: CI `native-engine` on `e74e487` (ci.yml run 42737701801),
canary 3/4. The rewritten pins pass, `LeavesTheEnvClean` with its own
`JNI_OnLoad`, and the kernel filesystem pins with the `rmdir` check
(no leak):

```text
[g1] canary 3/4: JNI guard/behavior unit tests (real desktop JVM)
[ RUN      ] JniGuardsOnLoad.LeavesTheEnvClean
[       OK ] JniGuardsOnLoad.LeavesTheEnvClean (0 ms)
[  PASSED  ] 7 tests.
[ RUN      ] JniKernelFilesystem.GetFileCountOfADirectory
[       OK ] JniKernelFilesystem.GetFileCountOfADirectory (3 ms)
[ RUN      ] JniKernelFilesystem.GetFileCountOfAFile
[       OK ] JniKernelFilesystem.GetFileCountOfAFile (0 ms)
[  PASSED  ] 6 tests.
[g1] jni-tests OK — guards + kernel pins green
```

The same build printed the `-Wpointer-bool-conversion` warning above
for each test TU; the `jni_test_env.hpp` fix came after that run.

## G1.14 — security audit (2026-11-10, branch `ci/transplant-integrity` and follow-ups)

A security pass over `dev/g1`, following the untrusted input in: ATAK
data packages (zip + PKCS#12 + XML), CoT from a TAK server or peers,
and offline layer files (GDAL/OGR). The secrets are the PKCS#12 pair
and its password. Six findings; each lands as its own focused PR.

| # | Severity | Finding | Status |
|---|---|---|---|
| 1 | High | commo accepts any server cert that chains to the truststore CA: no TLS-server purpose check, and no hostname check (deliberate upstream, per ATAK) | **Fixed** (branch `g1/commo-tls-server-purpose`): `patches/commo/0002-sslcertchecker-require-server-purpose.patch`, guarded by `test/tls-purpose.sh` |
| 2 | Medium | Transplant jars not fully integrity-checked: slf4j jars unlisted, CI never verified hashes | **Fixed here** |
| 3 | Low | Inbound CoT printed raw to the terminal: escape-sequence injection, and forged `headless:` lines | **Fixed** (branch `g1/sanitize-inbound-log`): `CotXml.printable`, guarded by `CotEventSelfTest` |
| 4 | Low (dormant) | commo's curl paths (file transfer, mission packages, URL requests) skip the hostname check always, and the chain check when the caller passes no CA or the transfer is peer-hosted | Recorded below (narrowed in pass 2: a caller rule, not a patch); unused by atak-headless today |
| 5 | Note | `NativeSsl` loads OpenSSL's legacy provider process-wide, not only for the RC2-40 PKCS#12 read | Recorded |
| 6 | Note | Reviewed, no issue: data-package importer (Zip-Slip, size caps, XXE, no password in logs, 0700 cert dir), `CotEvent` (XXE + §G1.11 validation), `TrackStore` (bound parameters), fake server (loopback only); deep pass: commo's stream framing (fixed 64 KiB buffer, protobuf length capped at it, overflow discards rather than overruns), its XML parse (`XML_PARSE_NONET`, no entity substitution or external DTD), and no listening socket (the mission-package web server starts only after `setupMissionPackageIO`, which atak-headless never calls); native-code read: the 34 engine patches, 2 commo patches and `jni-extra` add only null/exception guards, GL attribute guards and three upstream memory-bug fixes, and touch no buffer except `vsi_jfile` Read/Write, which keeps upstream's 32-bit length (a read over 2 GB comes back short, never past the buffer); CI workflow pass: every workflow is `contents: read`, triggers on `pull_request` (never `pull_request_target`), uses no repository secrets, pins every action and the upstream checkout by commit, and passes PR-controlled values to scripts through `env`, never inline | — |
| 7 | Low | `--db` tracks DB created under the default umask (0644 on macOS): other local accounts can read every received position | **Fixed** (pass 2, branch `g1/security-audit-pass-2`): `TrackStore` creates it 0600, guarded by `run.sh` |
| 8 | Note | `TrackStore` appends one row per received CoT with no cap or retention: a chatty or hostile server grows the file for as long as the client runs | Recorded; atak-headless runs bounded by `--duration`, G6 needs retention |
| 9 | Note | The launcher prefers `~/.m2` kernel jars over the hash-checked transplants, so `check-transplants` vouches only for the fallback | Recorded; only the same user can write `~/.m2`, so no boundary is crossed |
| 10 | Low today, Medium for G6 | Opening a layer file can make GDAL fetch remote URLs: the engine opens it with every driver registered, and some drivers follow references in the file | Recorded (deep pass, owner's call: no code change now); G6 must restrict drivers before importing overlays it did not choose |
| 11 | Note | Native dependencies (GDAL, OpenSSL, libxml2, protobuf, curl) are Homebrew's, linked at run time from `/opt/homebrew`: CI always builds on the latest, a developer machine is as current as its last `brew upgrade` | Recorded |
| 12 | Low | CI: 14 of the 16 checkouts in `ci.yml`, `cot-roundtrip.yml` and `docs.yml` left the job token in `.git/config` while build scripts and Homebrew-installed tools ran | **Fixed** (CI workflow pass, branch `ci/checkout-persist-credentials`): `persist-credentials: false` on each; the two `changes` jobs keep the token for their `git fetch` |

Trust model: a data package chooses the server you connect to, so a
`.dp` is trusted configuration, not hostile input. Its parser is still
hardened against a malformed or hostile one.

Traps found on the way (do not rediscover these):

- **`shasum -c SHA256SUMS` only checks the files the manifest lists.**
  `dev/g1/transplants/` shipped two slf4j jars the manifest never
  named, so the pre-commit hook passed them unread, and CI ran no hash
  check at all. Witness, the new check against the old manifest:
  `[check-transplants] FAIL dev/g1/transplants/slf4j-api-1.7.30.jar:
  not listed in SHA256SUMS` (same for `slf4j-simple`). Both jars match
  Maven Central's published SHA-1 (`b5a4b6d…`, `e606eac…`), so nothing
  was swapped. **Guard:** `dev/check-transplants.sh` fails on a
  mismatch or an unlisted jar. It is the single check behind the hook,
  `make check-transplants` and an unconditional CI lint step. A
  one-byte flip in a copy fails it with `slf4j-api-1.7.30.jar: FAILED`.
- **commo trusted any certificate its CA had signed, client certs
  included.** `SSLCertChecker::checkCert` verified the server's chain
  with `X509_verify_cert` and no purpose, and commo skips the hostname
  check by design (ATAK parity). TAK deployments issue client and server
  certificates from one CA, so a `clientAuth`-only certificate (any
  enrolled user's, or a leaked data package's) passed as the server.
  Proven end to end on unpatched commo (before, below): the impostor
  leg connects. **Guard:**
  `patches/commo/0002-sslcertchecker-require-server-purpose.patch`
  sets `X509_PURPOSE_SSL_SERVER` on the store context. It also adds
  `#include "openssl/x509v3.h"`: the file's existing OpenSSL headers
  don't declare the constant, so the bare one-liner would not have
  compiled. OpenSSL's server purpose accepts a leaf with `serverAuth` or
  with no extendedKeyUsage at all (TAK Server's
  `serverAuth,clientAuth` included) and rejects a `clientAuth`-only leaf
  with `X509_V_ERR_INVALID_PURPOSE` (26). `test/tls-purpose.sh` pins it
  in CI: one throwaway CA, three leaves presented by
  `fake-cot-server.py --tls` to an atak-headless SSL client.
  OpenTAKServer's own profiles confirm both sides
  (`opentakserver/ca_config.py`, upstream master): its server
  certificate is `[ server ]`, `extendedKeyUsage = critical, clientAuth,
  serverAuth`, which passes; every user certificate is `[ client ]`,
  `extendedKeyUsage = critical, clientAuth`, which is exactly the
  impostor. Certificates signed with those two sections, `critical`
  flags and keyUsage included, run through commo's `checkCert` logic
  (OpenSSL 3): `ots-server` ACCEPT before and after; `ots-client` ACCEPT
  before, REJECT (26) after. So on a stock OpenTAKServer the attack
  worked before the patch, and the real server stays reachable after it.
  CI now proves the same through real commo: `tls-purpose.sh` signs two
  more leaves with those profiles, read from
  `test/fixtures/ots-cert-profiles.cnf`, and requires `ots-server` to
  connect and `ots-client` to be refused. The copy can go stale, so
  `dev/check-ots-profiles.py` compares it with upstream's `ca_config.py`
  (every `[ client ]` and `[ server ]` occurrence; the server template's
  `subjectAltName` is ignored because commo never checks the hostname).
  It runs nightly in `ots-profile-drift.yml`, not as a PR gate: a red
  run means upstream changed. It reads one text file and runs nothing of
  OpenTAKServer's. A live run against an OpenTAKServer is still worth
  doing when one is next stood up, for the handshake as a whole; no
  server was available on 2026-11-10.
- **atak-headless printed server-supplied text raw.** `headless:
  cot-received` collapsed only whitespace, so ESC, BEL and C1 sequences
  from a hostile server reached the terminal, where they can rewrite
  earlier output or retitle the window. Worse, `CotEvent.toString` (the
  track summary) printed parsed attributes, and XML lets an attribute
  carry a real newline (`&#10;`) or a C1 control. On main, a callsign
  `EVIL&#10;headless: track uid=forged …` prints a second, forged
  `headless: track` line, and those are the lines `run.sh` greps as test
  evidence:

  ```text
  headless: track uid=u-1 type=t callsign=EVIL
  headless: track uid=forged type=a-f-G-U-C callsign=FORGED lat=0 lon=0 lat=1.000000 lon=2.000000 time= fixes=1
  ```

  **Guard:** `CotXml.printable` turns C0 controls, DEL and C1
  (U+0080–U+009F, including the 8-bit CSI) into a visible `\xNN` and
  leaves other text, non-ASCII included, alone. `HeadlessCLI` runs it
  on `cot-received` (after the whitespace collapse), contact uids and
  `cot-unparsed` messages; `CotEvent.toString` runs it per field, so a
  track stays on one line. Escaping per field is deliberate: escaping
  the whole summary and restoring its line breaks would let a callsign
  holding the literal text `\x0a` forge a line all over again.
  `CotEventSelfTest` pins six cases, among them that exact callsign:
  `callsign=EVIL\x0aheadless: track uid=forged\x9b31m`, one line.
- **commo's HTTP paths can turn TLS verification off** (dormant):
  ATAK-CIV's `simplefileiomanager.cpp`, `missionpackagemanager.cpp` and
  `urlrequestmanager.cpp` set `CURLOPT_SSL_VERIFYHOST` to 0 on every
  https request (the streaming path skips the hostname check too, by
  design). `CURLOPT_SSL_VERIFYPEER` goes to 0 only when the caller
  passes no CA certs (`if (!ioCtx->caCerts)`, "accepts any cert from
  server") and for peer-hosted mission-package downloads. Given CA
  certs, `sslCtxSetup` installs them as the `SSL_CTX` store and curl
  verifies through libssl, which already applies the TLS-server
  purpose, so finding #1's patch is not needed there. Pass 2 corrected
  the first reading ("patch these first"): the fix is a caller rule,
  not a commo patch, and patching `VERIFYPEER` on would break
  peer-hosted transfers. atak-headless calls none of them today.
  **Guard:** none yet. Whoever wires data-package or mission sync (G6
  rung 5) must always pass the truststore's CA certs to these calls;
  this entry is the reminder.
- **The tracks DB was readable by every local account** (pass 2, #7).
  `--db` handed the path to the engine's sqlite open, which created the
  file under the default umask: 0644 on macOS. The file holds every
  position received from other users. **Guard:** `TrackStore` creates a
  new file 0600 before the open (sqlite reads an empty file as a new
  database and gives its `-journal`/`-wal` files the database's mode); an
  existing file keeps its mode. `run.sh` fails unless both clients' DBs
  are 600. A `null` path is the engine's `:memory:` database, so no file.
- **A layer file can make GDAL reach the network** (deep pass, #10).
  `OGR_Content2` calls `GDALOpenEx` with no allowed-driver list, so any
  registered driver may claim the file, and some follow references in
  it. Two were proven against a loopback listener (GDAL 3.8.4, Linux
  `ogrinfo -ro -al -so`, evidence below): an OGR VRT whose
  `SrcDataSource` is `/vsicurl/http://…` fetches that URL (HEAD and
  ranged GETs), and a GML file whose `xsi:schemaLocation` names a WFS
  `DescribeFeatureType` URL downloads it (`GML_DOWNLOAD_WFS_SCHEMA`
  defaults to YES). An OGR VRT can also point at another local file
  (`CSV:/path`). Impact: a hostile file reveals the client's address and
  the moment it was opened, and sends GETs to hosts the client can
  reach, such as services on localhost or the LAN. Today `LayerCLI`
  opens only files the user names. GDAL has no single switch that turns
  its network access off. **Guard:** none, by the owner's call on
  2026-11-10. The fix when G6 imports overlays from data packages or
  peers: after `GdalLibrary::init`, deregister every vector driver
  outside an allowlist of formats that never follow references (GeoJSON,
  GPKG, KML, LIBKML, ESRI Shapefile, GPX, FlatGeobuf; the first four are
  what `layer.sh` proves), in `dev/g1/jni-extra/mactak_gdal.cpp`, with no
  engine patch. A denylist (`OGR_VRT`, `GML`, `GMLAS`, `WFS`, `OAPIF`)
  is the weaker alternative.

Evidence for #1 (CI, `cot-roundtrip.yml` dispatch runs). Before: the
test alone on `8b38d91`, unpatched commo (run 42741415679):

```text
[tls-test] ok   server-eku: accept
[tls-test] ok   server-noeku: accept
[tls-test] FAIL impostor: expected refuse
    headless: connecting 127.0.0.1:18091 ssl cert=client.p12 uid=tls-test-impostor callsign=TLS-impostor
    headless: iface-up
```

After: with the patch, on `237d36d` (run 42743222107):

```text
[g1-commo]   applied 0002-sslcertchecker-require-server-purpose.patch
[tls-test] ok   server-eku: accept
[tls-test] ok   server-noeku: accept
[tls-test] ok   impostor: refuse
    headless: iface-error CONN_SSL_PEER_CERT_NOT_TRUSTED
[tls-test] PASS: server certs accepted, client-only impostor refused
[g1-roundtrip] PASS — both ifaces up, B's presence+marker relayed to A, A's presence relayed to B, both persisted in the tracks DBs
```

The same rule, checked in C against commo's `checkCert` logic on
OpenSSL 3, for a TAK-style `serverAuth,clientAuth` leaf as well:
`server-eku`, `server-noeku`, `server-both` ACCEPT before and after;
`client-only` ACCEPT before, REJECT (26 invalid purpose) after.

OpenTAKServer's pinned profiles through real commo, on `ba7cef6`
(dispatch run 42851764473):

```text
[tls-test] ok   ots-server: accept
    headless: iface-up
[tls-test] ok   ots-client: refuse
    commo[ERROR] Error trying to make network connection for ssl:127.0.0.1:18093 - will retry (server certificate failed verification - check truststore)
    headless: iface-error CONN_SSL_PEER_CERT_NOT_TRUSTED
[tls-test] PASS: server certs accepted, client-only impostors refused (OpenTAKServer profiles included)
```

The drift check, same day: `[check-ots-profiles] OK: upstream [ client ]
and [ server ] match the pinned profiles` (this box and the PR's
`ots-profile-drift` job); exit 1 with `DRIFT [ server ]` on a copy of
upstream with `clientAuth` removed from the server profile.

Evidence for #2 (this box): `make check-transplants` →
`[check-transplants] OK: every transplant jar is listed and matches`;
shellcheck and `actionlint` clean; the hook end to end with the
manifest staged → `[pre-commit] OK`.

Evidence for #7 (CI, `cot-roundtrip.yml`). Before: the `run.sh` guard
alone on `239d51c` (dispatch run 42758526452):

```text
[g1-roundtrip] sqlite3 …/roundtrip-a.sqlite: 16 fix(es), 1 for B's marker
[g1-roundtrip] FAIL: roundtrip-a.sqlite has mode 644, want 600 (owner-only)
[g1-roundtrip] FAIL: roundtrip-b.sqlite has mode 644, want 600 (owner-only)
```

After: with the `TrackStore` fix, on `c6238ca` (run 42758809720):

```text
[g1-roundtrip] sqlite3 …/roundtrip-a.sqlite: 15 fix(es), 1 for B's marker
[g1-roundtrip] PASS — both ifaces up, B's presence+marker relayed to A, A's presence relayed to B, both persisted in the tracks DBs
```

Evidence for #10 (this box, GDAL 3.8.4, `ogrinfo -ro -al -so` on each
file; a Python listener on 127.0.0.1 logged the request paths):

```text
beacon.vrt   <SrcDataSource>/vsicurl/http://127.0.0.1:18555/beacon.geojson</SrcDataSource>
schema.gml   xsi:schemaLocation="… http://127.0.0.1:18555/gml-schema?SERVICE=WFS&REQUEST=DescribeFeatureType&TYPENAME=a"

listener:
/beacon.geojson
/beacon.geojson
/
/beacon.geojso1
/beacon.geojso1
/gml-schema?SERVICE=WFS&REQUEST=DescribeFeatureType&TYPENAME=a
```

## G1.15 — takkernel's `:shared` tests on 5.5 (2026-11-11, branch `g1/kernel-shared-tests`)

At the re-pin `make test-kernel` ran `:port` only: `:shared` does not
compile from public sources at 5.5 (`dev/spike/g55/NOTES.md` trap 11). Its
desktop MIL-STD-2525 glue (`gov.tak.platform.symbology.milstd2525`, under
`src/jre`) is written against a desktop `armyc2.c5isr` renderer that only
the TAK artifactory serves; the public build resolves one whose types are
Android `Bitmap`s, and `MilStd2525dInterop` / `RenderContextWrapper` fail
to compile. With that package left out, `shared` compiles and runs 297
tests, 43 failing. Every failure traces to the TAK-artifactory-only
pieces; none is a defect in code macTAK runs:

| Tests | Failures | Cause |
|---|---|---|
| `MilStd2525*Test` (7 classes, 67 tests) | 34 | They test the left-out package. Run without it, they resolve those classes from the android-port substitute's dex2jar'd Android ones (`Unknown Source` frames), whose symbol tables never initialize: `Cannot invoke "java.util.Map.size()" because "<local3>" is null` in `MilStd2525cSymbolTable.getAllSymbolDefs`, wrong defaults (`expected:<Point> but was:<LineString>`), one `UnsatisfiedLinkError` from GDAL's JNI |
| `ToolbarItemTest` (10 tests) | 9 | `gov.tak.api.commons.graphics.Bitmap.<init>` → `RuntimeException: Stub!`, as `:port`'s `BitmapTest` |

`dev/g1/kernel/kernel-tests.gradle` (was `port-tests.gradle`) leaves the
2525 package out of `:shared`'s main source set and its tests out of the
run, and excludes `ToolbarItemTest` by name, beside `:port`'s
`JavaResourceManagerTest` and `BitmapTest(s)`. It is an init script, so
upstream's build files stay untouched. `test-kernel.sh` runs
`:port:test :shared:test` with `--continue`:

```text
[g1-kernel-tests] PASS: :port:test :shared:test (artifactory-only code and tests excluded: kernel-tests.gradle)
port: 26 run, 0 failures, 0 errors, 0 skipped
shared: 220 run, 0 failures, 0 errors, 1 skipped
```

297 − 77 excluded (67 + 10) = 220. The one skip is upstream's own
`assumeTrue` in `Dt2FileTest.Dt2File_construction`. 4.6's `shared` needed
G0's `gradle-shared-test-deps.patch` (commons-math3, and
`ConfigMapMenuWidgetControllerTest` excluded); 5.5's needs neither, and
`ConfigMapMenuWidgetControllerTest` passes.

## G1.16 — commo names a QUIC failure's cause (2026-11-11, branch `g1/commo-quic-error-cause`)

`dev/spike/g55/NOTES.md` trap 8: a failed QUIC handshake reached commo's
log as `quic IO error during handshake` and nothing more. Two layers lost
the cause. `UdpSocket::sendto` and `recvfrom` threw a bare
`SocketException()` ("An unknown error occurred") on any error other than
would-block, so the errno was gone at the socket; and
`StreamingSocketManagement::QuicConnectionContext::connectionDoPost`
caught that exception and rethrew a fixed message, so even the bare text
was dropped. Spike 2 found `EISCONN` only with a throwaway errno probe.

`patches/commo/0006-quic-socket-error-cause.patch`:

- `netsocket.cpp`: a `socketErrorWhat(call)` helper reads `errno` right
  after the failed call (`WSAGetLastError()` on Windows, which upstream
  builds too) and both throws carry it, e.g. `recvfrom failed: Connection
  refused (errno 61)`. The error code stays `ERR_OTHER`.
- `streamingsocketmanagement.cpp`: the handshake's rethrow keeps
  `ERR_CONN_OTHER` and appends the caught message.

The guard is a third `make test-quic` leg, `cause`: a QUIC connection to a
loopback port with no listener. commo's socket is a connected UDP socket,
so the port-unreachable reply makes the next read fail with
`ECONNREFUSED`. `QuicStreamingTest` records every commo log line and
requires the interface error `CONN_OTHER` and the cause in the logged
failure. Same leg, before and after the patch:

```text
FAIL: commo logs the handshake failure's cause: Error trying to make network connection for quic:127.0.0.1:18192 - will retry (quic IO error during handshake)
PASS: commo logs the handshake failure's cause: Error trying to make network connection for quic:127.0.0.1:18192 - will retry (quic IO error during handshake: recvfrom failed: Connection refused (errno 61))
```

The accept and refuse legs, `make test-tls` and the hermetic CoT
round-trip stay green with the patch.

## G1.17 — `ManagedFeatureDefinition` consumer guards and pins for the 5.5 JNI patches (2026-11-12, branch `g1/managed-feature-definition-guards`)

Carried forward from `dev/spike/g55/NOTES.md` §JNI glue: the 5.5 guard
patches `jni-class-inits-new-in-55` and `common-managedlogger-guards`
had no test, and `ManagedFeatureDefinition`'s consumers still called
through the method IDs a failed `FeatureDefinition2_class_init` left
NULL, as `ManagedTextFormat2`'s did before
`textformat2-class-init-consumer-guards`.

`patches/managedfeaturedefinition-consumer-guards.patch` (the series is
now 39): `getRawGeometry`, `getName`, `getRawStyle` and `getAttributes`
return `TE_Err` when a method ID they call is NULL; `getGeomCoding` and
`getStyleCoding` return upstream's own fallbacks (`GeomGeometry`,
`StyleStyle`). The version-gated consumers (`getTimestamp`,
`getAltitudeMode`, `getExtrude`, `getTraits`) need nothing: the
constructor returns before the `IsInstanceOf` checks on a failed init,
so `version` stays 1.

The pins, in `make test-jni`:

- **Guards mode**, `featuredefinition_guards_test.cpp` (4 tests): a
  `ManagedFeatureDefinition` around a live Java `String` on the empty
  classpath. The constructor returns; every Java-backed consumer bails;
  `get()` fails at `Feature_create`'s raw-geometry read; the
  version-gated consumers return their defaults; the JNIEnv stays clean.
- **noslf4j mode**, a new third `run.sh` leg (`managedlogger_noslf4j_test.cpp`,
  2 tests): `JniTestsMain` under the java launcher with the kernel
  classpath minus `slf4j-api`, so `com.atakmap.coremap.log.Log`'s class
  init fails. One test checks that this is the case (slf4j and `Log`
  missing, `Pointer` present), so the leg can't pass by accident; the
  other logs at every level and checks the JNIEnv is clean. Reaching the
  tests at all means `System.load` survived `JNI_OnLoad`.

A/B on the dev Mac, each patch taken out alone:

| Without | Result |
|---|---|
| `managedfeaturedefinition-consumer-guards` | guards mode SIGSEGV in `jni_CallIntMethodV` from `ManagedFeatureDefinition::getRawGeometry` (`JavaBackedConsumersBailOut`) |
| the constructor hunk of `jni-class-inits-new-in-55` | guards mode SIGSEGV in `jni_IsInstanceOf` from the `ManagedFeatureDefinition` constructor (`ConstructorSurvivesFailedInit`) |
| `common-managedlogger-guards` | noslf4j leg fails: `System.load` throws `NoClassDefFoundError: Could not initialize class com.atakmap.coremap.log.Log` and the glue never loads |

The last differs from the spike's record (a SIGSEGV and an `hs_err`
file, through the smoke): under JDK 21 and `JniTestsMain` the pending
error escapes `JNI_OnLoad` instead. Either way the glue does not load
without the patch.

Not pinned: the `HeightmapStrategy`/`HeightmapParams` hunk of
`jni-class-inits-new-in-55`. Its lookups follow
`NativeElevationSource`'s in the same init, which fails first on any
classpath without the kernel, and all three classes ship in
`takkernel-engine`, so no real classpath reaches the new lookups with
them missing. The elevation consumers already go through `checkInit`
upstream, so they need no consumer guards.
