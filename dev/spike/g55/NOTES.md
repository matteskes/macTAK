# Spike 1 record — the 5.5 engine on macOS arm64, without 3D Tiles

Step 1 of [docs/rebase-study-5.5.md](../../../docs/rebase-study-5.5.md)
§Next steps. Question: does takkernel 8.30.5
(`TAK-Product-Center/atak-civ` @ `9f6893d`, 5.5.1.10) build on macOS
arm64 with Homebrew GDAL 3, once 3D Tiles is left out, and with
macTAK's patch series carried over? Nothing here changes the build
macTAK ships: `src/`, `dev/g1/build-native.sh` and the 4.6 pin are
untouched. The re-pin is a later step.

Each iteration of the rebase adds a dated State section here, newest on
top, and its traps continue this file's numbering (the g55 lineage).
After the re-pin this record stays as history, and new traps go back to
the G1 and G2 lineages.

## State (JDK 21 — 2026-11-11): every JVM macTAK starts runs on JDK 21; JDK 8 stays a 4.6 build tool

The 4.6 build moves its runtime to JDK 21 ahead of the re-pin, so a
JVM-version break shows on the known-good 4.6 build rather than among
5.5's changes. `dev/jdk.sh` finds both JDKs by their `release` file
(trap 5's guard, shared now). On JDK 21: the canaries, `atak-headless`
and its tests, `jni-tests`, the render harness, the GDAL bindings and the
Swift shell's in-process JVM; macTAK's Java compiles with `--release 21`.
JDK 8 stays only where 4.6 needs it until the re-pin: upstream's Gradle
6.9.1 (JDK 16 at most) and `javah` (gone since JDK 10), which 4.6
commo's JNI Makefile and `gen-jni-headers.sh` call. Every G1/G2 gate is
green on this Mac, `make test-shell` included:

```text
[smoke] java 21.0.13.0.3 (OpenJDK 64-Bit Server VM)
[smoke] SELECT 41+1 through the JNI stack = 42
[g1] jni-tests OK — guards + kernel pins green
[g1-roundtrip] PASS — both ifaces up, B's presence+marker relayed to A, A's presence relayed to B, both persisted in the tracks DBs
[tls-test] PASS: server certs accepted, client-only impostors refused (OpenTAKServer profiles included)
[check-gen-gles-shim] OK: committed shim matches the generator
render-smoke: sentinel pixels left=0/262144 content pixels=262144 centre=(255,117,0,255)
mactak-shell: libjli /Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home/lib/libjli.dylib
window-app: 5 frames, 11.3 ms/frame (incl. glFinish), glErrors=0
[shell-exit] PASS: a failed render exits 2
```

Render content pixels match the pre-move run (vector layer 23 890,
basemap 262 144). javac 21's `this-escape` lint found three
constructors calling overridable methods, in the `Matrix`, `Paint` and
`Canvas` stand-ins; each now shares a private helper with the public
method. Trap 9 below. Next: the re-pin.

## State (commo — 2026-11-11): 5.5 commo and its QUIC pass the G1 comms gates

5.5's commoncommo builds through `dev/g1/build-commo.sh` (opt-in
`MACTAK_COMMO_*` overrides) with its mandatory QUIC on ngtcp2 1.26.0's
`ossl` backend over Homebrew `openssl@3`, one OpenSSL runtime linked.
`commo.sh`'s six checks are green: streaming QUIC against an aioquic
stand-in (a clientAuth-only impostor refused, so security fix #1 holds
on QUIC), `tls-purpose.sh` and the two-client CoT round-trip (#101).
Five commo patches; trap 8 (commo hides a QUIC failure's cause) is
open. Next: the move to JDK 21, then the re-pin (§Exit).

## State (render gates — 2026-11-11): the G2 render gates pass on 5.5 with ANGLE/Metal

The nine steps of `ci.yml`'s `render-angle` job run green on the 5.5
build linked against ANGLE, each with `glErrors=0` and `KHR_debug` on,
through `dev/g2/render/env.sh`'s `MACTAK_RENDER_ENV` override (#100).
One new patch, `antialiased-lines-pattern-uint`, makes the series 38.
`GdalProjectionSmoke` accepts exactly two pixel conventions, 4.6's
`[0, w]` and 5.5's `[0, w-1]`, so 4.6 still reads exactly `(32, 32)`.
No new traps. Next: commo on 5.5. Details in §Render gates below.

## State (JNI glue — 2026-11-11): the 5.5 glue loads in a JVM and passes G1's jni-tests

`libtakenginejni` builds beside the 5.5 engine; the G1 load canary
returns `42` through Java → glue → C++ → sqlite on JDK 21, and
`dev/g1/jni-tests` pass in both modes (7 guards, 6 kernel). In CI on
`macos-26`, jar build and header-drift check included: run 43041239149
(#99). The series is 37 patches (three new; traps 5–7). The 5.5 jars are
Java 11 bytecode, so the move to JDK 21 is a step of its own before the
re-pin. Next: the render gates on 5.5. Details in §JNI glue below.

## State (spike 1 — 2026-11-11): the 5.5 engine builds on macOS arm64 without 3D Tiles

takkernel 8.30.5 with macTAK's 34-patch 5.5 series compiles and links on
`macos-26`: 471 of 471 build steps, `libtakengine.dylib` linked
(`spike-55.yml` run 42970368105, PR #98). Not yet run: no JNI glue, no
canary, no gate. Next is the JNI glue on 5.5 (§Exit). Details in
§Result below.

## Result

**Yes.** On `macos-26` (Xcode 26 toolchain, Homebrew GDAL 3.13.3), the
5.5 engine with macTAK's 5.5 patch series compiles and links: run
[42970368105](https://github.com/matteskes/macTAK/actions/runs/42970368105),

```text
[g55]   applied 34 patches
[g55] build steps: 471, failed: 0
[g55] PASS: libtakengine.dylib linked from the 5.5 tree
```

Build step 2 min 16 s at `-j3`; Homebrew install 3–5 min. Everything the
first run found was the build wrapper's, not the engine's: no 5.5 source
needed a code change beyond the ported series. Five runs got there:

| Run | Failed | What | Fix in `build-engine.sh` |
|---|---|---|---|
| [1](https://github.com/matteskes/macTAK/actions/runs/42965249188) | 5 of 471 | `GLTFv1.cpp`, `GLTFv2.cpp`, `ASSIMPSceneSpi.cpp`: headers missing; `mdbtools.h` needs `glib.h`; `ZipFile.cpp` uses `libkml_unzStringFileNameCompare` | The three headers (below), glib's include dirs, one more minizip rename |
| [2](https://github.com/matteskes/macTAK/actions/runs/42967023061) | 1 | `tiny_gltf_loader.h` includes `./json.hpp` | Copy the loader's own `json.hpp` |
| [3](https://github.com/matteskes/macTAK/actions/runs/42968123734) | link | Undefined symbols, listed only in the artifact | `summarize-build.py` prints them |
| [4](https://github.com/matteskes/macTAK/actions/runs/42969247994) | link | `curl_escape`, `curl_free` (`URIOfflineCache.cpp`); `g_malloc`, `g_malloc0`, `g_free` (`mdbtools.h` inlines) | Link libcurl and glib |
| [5](https://github.com/matteskes/macTAK/actions/runs/42970368105) | 0 | — | — |

What 5.5 asks of the build beyond 4.6:

| New need | Where | Taken from |
|---|---|---|
| tinygltf, tinygltfloader, assimp headers | `formats/gltf/GLTFv1.cpp`, `GLTFv2.cpp`, `model/ASSIMPSceneSpi.cpp`, which 4.6 wrapped in `#ifdef MSVC` and 5.5 compiles on every platform | tinygltf: upstream's `depends/tinygltf-2.4.1-mod.tar.gz` (Git LFS); tinygltfloader: upstream's in-tree `takengine/thirdparty/tinygltfloader`; assimp: Homebrew 6.0.5 (upstream builds a patched 4.0.1). The LFS tarball and the in-tree copy are upstream's own inputs at the pinned commit, so nothing enters this repo |
| libmdb (+ glib) | `formats/msaccess/MDBAccessDatabaseProvider.cpp`, a new MS Access reader | Homebrew `mdbtools`, `glib` |
| libcurl | `URIOfflineCache.cpp` | macOS SDK / Homebrew |
| `libkml_unzStringFileNameCompare` | `util/ZipFile.cpp` | One more line in the minizip rename list |
| cesium-native, draco | `formats/c3dt/` (3D Tiles) | Left out, as planned |

Still unanswered by that first iteration: whether it *runs*. The JNI
iteration below answers it for the JVM half.

## JNI glue

**It loads and runs.** The 5.5 glue (`libtakenginejni`) builds next to
the engine (624 of 624 steps); the G1 load canary passes on JDK 21
(Java → glue → C++ `Database2` → sqlite → `42`), and G1's JNI guard
tests pass in both modes, 7 guards-mode and 6 kernel-mode. The same on
`macos-26` in CI, jar build and header-drift check included (13 min 33 s):
run [43041239149](https://github.com/Chicago-Offline/macTAK/actions/runs/43041239149),

```text
[g55]   applied 37 patches
[g55] build steps: 636, failed: 0
[g55] PASS: libtakengine.dylib and libtakenginejni.dylib linked from the 5.5 tree
[smoke] PASS: engine loads and runs in-process from the JVM
[g55] jni-tests OK: guards and kernel modes green on 5.5
```

What it took:

| Step | What 5.5 asked | Answer |
|---|---|---|
| Kernel jars | Gradle 8.13 (JDK 17+); the TAK-artifactory-only `gradle-cmake-plugin`, `android-port` 6.1.2 and native runtime artifacts; JOGL 2.5.0, which Maven Central skips | `kernel/gradle-public-source-build.patch` (G0's gradle patch, redone for 5.5) gates the native hook and the artifactory artifacts behind `-PuseTakRepo=true` and adds jogamp.org's repository; `android-port/` rebuilds G0's substitute with one more stub (`Resources.getColor`, `getStringArray`) as `3.1.0-g55`. `kernel/build-kernel-jars.sh` patches a copy of `takkernel`, builds into a private Maven repo (`~/.m2` untouched) and exports the engine's runtime classpath |
| JNI headers | 5.5's glue includes one `javac -h` header per class (`com_atakmap_*.h`), not 4.6's javah bundles (`jdatabaseimpl.h`) | The Gradle build compiles with `-h`, as upstream's `generateJniHeaders`; the 116 headers are committed in `jni-include/`, so `build-engine.sh` needs no JDK. CI regenerates them and fails on a diff |
| Glue build | `CXX_STANDARD 17` (upstream's `jni/CMakeLists.txt`): `util/Tasking.h` overloads on `noexcept` function types, a redefinition below C++17; libcurl and libssl (`jlibcurlhttpclientbuilder.cpp`, new) | Set on the target; link `curl` and Homebrew `openssl@3` |
| LAS | `jsceneinfofactory.cpp` (new) registers the LAS SPIs unconditionally; libLAS is dead upstream and the engine is built without it | `jsceneinfofactory-las-optional.patch`: the LAS lines behind `LAS_ENABLED`, as upstream guards 3D Tiles with `C3DT_ENABLED` |
| Java runtime | The desktop jars are **Java 11 bytecode** (`gradle/buildconfig.gradle`); G1 and CI run Zulu 8 | The 5.5 scripts run JDK 21. The re-pin moves CI and the launcher off Java 8 |
| jni-tests | `ManagedTextFormatFactory` takes only the `JNIEnv` in 5.5 | `jni-tests/textformat2_guards_test.cpp`, a 5.5 copy of G1's with that call changed; it replaces G1's at the re-pin |

New guards (patches, in the series):

- **`common-managedlogger-guards`**: 5.5's `JNI_OnLoad` installs a
  `ManagedLogger` that routes native logging to
  `com.atakmap.coremap.log.Log`. When that class cannot load (its class
  init needs slf4j on the classpath), `FindClass` returned NULL and
  `GetStaticMethodID(NULL, …)` crashed the JVM (SIGSEGV in
  `get_method_id`) before the glue finished loading. A/B, the canary
  with slf4j left off the classpath: without the patch, SIGSEGV and an
  `hs_err` file; with it, `JNI_OnLoad` returns and native logging goes
  quiet.
- **`jni-class-inits-new-in-55`**: the guards `jni-class-init-guards`
  gives every other init, for the lookups 5.5 added or moved:
  `HeightmapStrategy` and `HeightmapParams` in
  `interop/elevation/Interop.cpp`, and the `FeatureDefinition` lookups
  that moved to `interop/feature/ManagedFeatureDefinition.cpp`, whose
  constructor also stops before `IsInstanceOf` against a class the
  init could not find.

Not done here: the `ManagedFeatureDefinition` consumers (`getRawGeometry`
and the rest) still call through the method IDs when the init failed,
as `ManagedTextFormat2`'s did before `textformat2-class-init-consumer-guards`;
and no guards-mode test pins the two new patches yet (G1's suite pins
the 4.6 ones).

## Render gates

**They pass.** The G2 render gates, the same nine steps as `ci.yml`'s
`render-angle` job, run green on the 5.5 build linked against ANGLE on
Metal: GDAL georeferencing, the GLES shim Buffer contract, the
argument canary, globe, vector layer, MBTiles basemap, the basemap
negative canary, resize mid-run, and the CAMetalLayer window surface.
Every leg has `glErrors=0`, with ANGLE's `KHR_debug` callback on
(`MACTAK_GL_DEBUG=1`):

```text
render-smoke: 128 frames, 23.6 ms/frame (incl. glFinish), glErrors=0
render-smoke: sentinel pixels left=0/262144 content pixels=26328 centre=(255,117,0,255)
[basemap-gate] PASS: an off-frame basemap fails the smoke
[g55-render] PASS: the G2 render gates are green on the 5.5 build
```

How: `render.sh` exports `MACTAK_RENDER_ENV=render-env.sh`, and
`dev/g2/render/env.sh` hands its whole job to that file when it is
set. The gate scripts run unchanged, on the 5.5 dylibs (from
`build-engine.sh` with `G55_GLES=angle`, staged in `build/dist`), the
5.5 classpath and JDK 21. `render-env.sh` regenerates the engine shadows
on every run from the 5.5 sources plus the series' Java hunks. Both
apply at `--fuzz=0`, so there is no committed copy to drift.

What 5.5 changed, and what each took:

| Found | Evidence | Answer |
|---|---|---|
| **Anti-aliased lines never drew on ANGLE/Metal.** `BatchGeometryAntiAliasedLines.vert` declares `in int a_pattern`; `GLGeometryBatchBuilder` lays it out `GL_UNSIGNED_SHORT` and feeds it with `glVertexAttribIPointer`, as `GLLinesEmulation` does. GLES 3 leaves the signed/unsigned mismatch undefined, and Metal refuses the pipeline | Vector-layer leg: 44 × `GL_INVALID_OPERATION` from frame 32; `MACTAK_GL_DEBUG=2` names it: *Vertex attribute _ua_pattern(7) of type int cannot be read using MTLAttributeFormatUShort*, from `GLBatchGeometryRenderer4::drawLineBuffers` (all 113 debug messages were this one) | `antialiased-lines-pattern-uint.patch`: `in uint a_pattern`, `f_pattern = int(a_pattern)`. The value must stay unsigned: `0xFFFF` has to read as 65535 for `solidLine`. The same patch changes the lollipop draw's constant `glVertexAttrib1f(a_pattern, 0)` to `glVertexAttribI4ui`, since GLES 3 leaves a current-value type mismatch undefined too (found in review; the gates don't show whether that path ran). After: `glErrors=0` and no `KHR_debug` message at all, content 25 292 → 26 328 px, and the strokes are back in the PNG |
| `GLBatchGeometryRenderer4`'s unguarded `glEnableVertexAttribArray` calls (the open question from the patch port) | No `GL_INVALID_VALUE` in the `KHR_debug` log, so no attribute location comes back -1 on this scene | No attribute guards needed; `attrib-location-guards` stays without a `GLBatchGeometryRenderer4` hunk |
| **5.5 changed the georeferencing pixel convention.** `GdalDatasetProjection2.GeoTransform` scales image coordinates by `(w-1)/w`, so the geo extent maps to the addressable `[0, w-1]` (upstream's comment says so) | `GdalProjectionSmoke` on 5.5: ground(centre) → image(31.5, 31.5), and the smoke wanted (32, 32) | The smoke asserted 4.6's convention, not the axis order it exists for. It now takes the expected centre from the SE corner's image (4.6: 64 → 32; 5.5: 63 → 31.5) and requires that corner to fall in `[w-1, w]`. An axis swap or a non-linear map still fails. 4.6: `make test-gdal-projection` PASS, centre still (32, 32) |
| 5.5 deprecates the `FeatureDataStore` APIs that `LayerStore` (6 uses), `RenderSmoke` and `WindowApp` (2 each) build layers with | `-Xlint:all` deprecation warnings | Compiled with `-Xlint:-deprecation` for now; moving to `FeatureDataStore4` is re-pin work |
| JDK 21's javac adds the `this-escape` lint, which `android.graphics.Matrix` trips | `-Werror` on JDK 21 | `-Xlint:-this-escape`; this comes from the Java 8 → 21 move, not from 5.5 |

Shipping files touched, both inert or equivalent on 4.6:

- `dev/g2/render/env.sh` gains the `MACTAK_RENDER_ENV` hook; unset, the
  file is unchanged.
- `GdalProjectionSmoke` gains the convention-free centre check.

4.6, verified after both changes: `MACTAK_GLES=angle build-native.sh`
(all 4 canaries), `make test-render`, `make test-gdal-projection` and
`make check-engine-shadows`, all green. Not run on 5.5:
`dev/g1/headless/test/layer.sh`, the headless launcher's canary,
because it waits for the launcher's move off Java 8.

## Commo

Study step 2. **5.5 commo builds on macOS, speaks QUIC, and passes the G1
TLS and round-trip gates**, with its QUIC on ngtcp2's `ossl` backend
over the same Homebrew `openssl@3` (3.5.9) as the rest of commo.
`commo.sh` runs six steps, all green, locally and on `macos-26` in CI
(run [43062762143](https://github.com/Chicago-Offline/macTAK/actions/runs/43062762143),
job "5.5 commo + QUIC"):

```text
[g55-commo] ok: one OpenSSL runtime (openssl@3), ngtcp2 + crypto_ossl inside libcommoncommo
PASS: the server completed a takstream handshake and received the marker over QUIC
PASS: the refusal is CONN_SSL_PEER_CERT_NOT_TRUSTED (got CONN_SSL_PEER_CERT_NOT_TRUSTED)
[tls-test] PASS: server certs accepted, client-only impostors refused (OpenTAKServer profiles included)
[g1-roundtrip] PASS — both ifaces up, B's presence+marker relayed to A, A's presence relayed to B, both persisted in the tracks DBs
```

**The QUIC backend decision.** 5.5 commo always compiles
`quicconnection.cpp` and links `-lngtcp2 -lngtcp2_crypto_quictls`.
Its use of the backend is narrow: two `configure_*_context` calls, and
everything else is ngtcp2's generic `ngtcp2_crypto_*` callbacks.

| Option | Verdict |
|---|---|
| Upstream's quictls: `openssl-3.0.14-quic1` + ngtcp2 1.6.0, from `takthirdparty/distfiles` | Rejected. OpenSSL 3.0 reached end of life on 2026-09-07, and it would be a second OpenSSL beside the `openssl@3` macTAK's TLS work stands on (security fix #1, the legacy-provider shim) |
| Homebrew `libngtcp2` 1.26.0, whose `ngtcp2_crypto_ossl` links `openssl@4` | Rejected. `SSL*` objects from commo's `openssl@3` would cross into a second OpenSSL runtime; using it means moving commo's TLS to OpenSSL 4 |
| **ngtcp2 1.26.0 built against `openssl@3`, `ossl` backend** (OpenSSL 3.5's own QUIC TLS API, `SSL_set_quic_tls_cbs`) | **Chosen.** One OpenSSL runtime, the one macTAK already supports; the same release Homebrew packages, sha256 cross-checked against its formula; static, so nothing more to stage. The cost is a commo patch |

What 5.5 commo took (series in `patches/commo/`, `-p1`, fuzz 0):

| Patch | Why |
|---|---|
| `0001-diag-socketRead-errno` | G1's five `[commo-diag]` probes, ported to 5.5's restructured transmit loop (`ctx->ioWrite`). Diagnostics only; nothing reads them |
| `0002-sslcertchecker-require-server-purpose` | Security fix #1, unchanged (5.5 still lacks it) |
| `0003-quic-ossl-backend` | The backend switch: one `ngtcp2_crypto_ossl_ctx` per connection as ngtcp2's native handle, `configure_*_session(ssl)` in place of quictls' `configure_*_context(ctx)`, the `SSL_CTX` still pinned to TLS 1.3 as quictls did, `ngtcp2_crypto_ossl_init()` once, and `SSL_set_app_data(ssl, NULL)` before `SSL_free` as the header asks |
| `0004-platform-socket-cloexec-macos` | 5.5's `createSocket` passes Linux's `SOCK_CLOEXEC` to `socket()`; on macOS, `fcntl(FD_CLOEXEC)` instead |
| `0005-udpsocket-connected-sendto-macos` | The QUIC client's UDP socket is `connect()`ed, and commo still `sendto`s with an address. Linux accepts that; BSD returns `EISCONN`, so no QUIC packet ever left (found with a throwaway `sendto` errno probe: `errno=56 (Socket is already connected)`). On macOS a connected socket now sends without an address |

How it runs: `dev/g1/build-commo.sh` builds 5.5 commo itself, through
opt-in overrides (`MACTAK_COMMO_SRC`, `_PATCHES`, `_WORK`,
`MACTAK_NATIVE_DIST`, `MACTAK_NGTCP2_PREFIX`; unset, the script is
unchanged), into `build/commo-dist` beside the 4.6 engine. The headless
launcher loads both, and the 5.5 engine needs a JDK the launcher doesn't
run on yet. The QUIC check is `commo/QuicStreamingTest.java` against
`commo/fake-quic-server.py` (aioquic 1.7.2, pinned, in a venv): a
`takstream` server, as a TAK server's QUIC endpoint is.

Findings:

- **commo has two QUIC protocols.** Streaming to a TAK server (ALPN
  `takstream`, truststore, security fix #1 applies) and peer-to-peer
  between clients (`takcot`/`takfdp`, no certificate verification, as
  ATAK's mesh). The first test paired a streaming client with commo's
  peer inbound; the TLS alert 120 (`no_application_protocol`) it got
  was the correct answer.
- **Peer-to-peer QUIC is untested here, and blocked on macOS by a
  pre-existing bug.** Peers learn each other's QUIC endpoint from UDP
  mesh presence, and commo's interface scanner reports `lo0` as
  `127.51.68.120` on macOS, so a loopback UDP inbound hears nothing.
  `hwifscanner.cpp` is identical in 4.6, and macTAK has never used the
  mesh path (the headless app streams over TCP). Worth its own look
  before mesh networking is on the roadmap.
- **5.5 deprecates `Commo.addStreamingInterface` without a transport.**
  `HeadlessCLI` calls it, and the launcher compiles with `-Werror`.
  The re-pin moves it to the `StreamingTransport` overload, which 4.6
  lacks. Until then, `atak-headless` takes `MACTAK_HEADLESS_CLASSES` and
  `MACTAK_JAVAC_LINT` (unset: unchanged), and `commo.sh` sets
  `all,-deprecation` with its own class directory.
- **5.5 commo stamps `access="Undefined"`** on its own pings: the
  MIL-STD-6090 change the rebase study noted for `CotXml`.

4.6, verified after the shipping-script changes: `build-commo.sh` (all
3 canaries), `make test-tls` (5 legs) and the `run.sh` round-trip
against `fake-cot-server.py`, all green.

## Reproduce

```sh
brew install cmake ninja rsync proj geos gdal libspatialite minizip nlohmann-json libxml2 mdbtools glib assimp openssl@3 googletest
git clone --filter=blob:none --no-checkout https://github.com/TAK-Product-Center/atak-civ ../atak-civ
git -C ../atak-civ sparse-checkout set takkernel khronos takengine/thirdparty/tinygltfloader depends
git -C ../atak-civ checkout 9f6893dd657feacc35ec5de03dad721c2e44170e
git -C ../atak-civ lfs pull --include=depends/tinygltf-2.4.1-mod.tar.gz
bash dev/spike/g55/kernel/build-kernel-jars.sh ../atak-civ   # JDK 21 + JDK 8; network on first run
make angle gdal-java                                         # ANGLE + org.gdal, as G2 (JDK 8, swig)
G55_GLES=angle bash dev/spike/g55/build-engine.sh ../atak-civ
bash dev/spike/g55/smoke.sh
bash dev/spike/g55/jni-tests.sh
bash dev/spike/g55/render.sh ../atak-civ
# commo (adds commoncommo to the sparse checkout; needs dev/g1/native-dist
# from build-native.sh, plus protobuf libmicrohttpd curl):
git -C ../atak-civ sparse-checkout add commoncommo
bash dev/spike/g55/commo.sh ../atak-civ
# re-sort the 4.6 series against a 5.5 tree (writes clean + refreshed only):
python3 dev/spike/g55/refresh-patches.py ../atak-civ/takkernel/engine/src/main /tmp/out
```

CI: `.github/workflows/spike-55.yml` (dispatch, or a push to a
`spike/g55-*` branch that touches this directory) runs the same scripts
on `macos-26` in two jobs, engine and commo, and uploads the build and
Gradle logs, `summary.txt`, the jni-tests XML, the render PNGs and the
commo logs. It is not a required check; a red run is the spike's
answer, as G0's was ([docs/ci-qa.md](../../../docs/ci-qa.md) §7).

## What's here

| Path | Role |
|---|---|
| `refresh-patches.py` | Sorts the 4.6 series against a 5.5 tree, stacked in build order: clean, refreshed, review, upstream, failed |
| `patches/` | The 5.5 series: 38 patches, applying at `--fuzz=0` in `build-native.sh`'s order (`gdal-drift-*` first, then sorted) |
| `build-engine.sh` | `build-native.sh` against a 5.5 checkout: the engine, the JNI glue and the jni-tests, staged in `build/dist`; `G55_GLES=angle` links ANGLE; `c3dt` left out; `ninja -k 0` |
| `summarize-build.py` | Every failing source with its first error, the errors grouped by kind, and the undefined symbols of a failed link |
| `kernel/` | `build-kernel-jars.sh`, its Gradle patch, and `runtime-classpath.gradle` (exports the engine's resolved runtime classpath) |
| `android-port/` | `build-android-port.py` and the stub sources it adds to G0's `android-port-3.1.0` substitute; the jar is deterministic |
| `jni-include/` | The 116 `javac -h` headers of takkernel 8.30.5 (generated; regenerate with `kernel/build-kernel-jars.sh`) |
| `jni-tests/` | 5.5 copies of G1 jni-tests whose 4.6 versions no longer compile |
| `runtime.sh` | Sourced: JDK lookup (`G55_JDK<v>_HOME`, else a version-checked `java_home`) and the kernel-first classpath |
| `smoke.sh`, `jni-tests.sh` | The G1 load canary and the G1 jni-tests on the 5.5 build |
| `render.sh`, `render-env.sh` | The G2 render gates on the 5.5 build: `render.sh` runs ci.yml's render steps; `render-env.sh` is what `dev/g2/render/env.sh` sources instead (`MACTAK_RENDER_ENV`) |
| `patches/commo/` | The 5.5 commo series: 5 patches, `-p1` on `commoncommo`, fuzz 0 |
| `commo.sh`, `commo/` | Spike 2: `fetch-ngtcp2.sh` (ngtcp2 against `openssl@3`), `QuicStreamingTest.java` and `fake-quic-server.py` (the QUIC canary); `commo.sh` builds and runs it all |

## The patch port

37 patches at the pin (34 in `dev/g1/patches`, 3 `gdal-drift-*` in
`dev/spike/g0/patches`). On 5.5:

| Outcome | Count | Patches |
|---|---|---|
| Unchanged (apply at fuzz 0) | 17 | `gdal-drift-GdalDatasetProjection2`, `glsl-es-version-on-angle`, the `ioproviderfactory-*`, `jglmapview-*`, `jglobe-*`, `jni-renderable-*`, `jnilayer2-*`, `jnilayerspi2-*` series, `managedrendercontext-sweep-guards`, `stlvectoradapter-bind-contents` |
| Refreshed by the tool (context intact, indentation drift) | 1 | `glmapview2-srid-capability` |
| Hand-ported, same hunks (whitespace, blank lines, offsets or upstream's own edits in the context) | 7 | `gdal-drift-GdalDatasetProjection`, `gdal-drift-OGR_Content2`, `common-onload-classloader-guards`, `gdal3-axis-order-cpp-default`, `glbatchshaders-dead-store`, `managedrendercontext-guards`, `vsi-jfile-gdal3-api` |
| Hand-ported, reworked for 5.5's code | 9 | below |
| Dropped: fixed upstream | 3 | `cpp17-legacy-headers`, `megatexture-sharetile-comma-operator`, `terraintile-ecef-ge` |

The nine reworked ports:

- **`attrib-location-guards`**: the `GLGlobe` and `GLMapView2` hunks
  carry over. `renderer/feature/GLBatchGeometryRenderer3.cpp` is gone in
  5.5, so its hunks are dropped. `GLBatchGeometryRenderer4` has the same
  unguarded `glEnableVertexAttribArray` calls but this patch never
  covered it; the render gate's `KHR_debug` count decides at the JNI
  iteration.
- **`gdal3-axis-order-traditional-gis`**: fuzz put
  `traditionalGisOrder()` inside an `if/else` chain of
  `GdalLibrary.java`; placed by hand after `ImportFromEPSG(4326)` and at
  the end of the class.
- **`jni-class-init-guards`**: 21 of 27 files carry over. Three
  class-init functions were rewritten upstream; they are guarded by the
  patch's own rule, every lookup checked, including the lookups 5.5
  added (`Collection.size`, the `RenderSurface2` class).
- **`megatexture-release-erase-while-iterating`**: 5.5 fixed the
  use-after-free its own way, draining with `while(!tiles.empty())`.
  That loop never ends once a tile is shared: `releaseTile` then drops
  one share and returns without erasing the entry. `shareTile` has no
  callers in 5.5 either, so the hang is latent. The port keeps
  macTAK's snapshot-of-keys loop in place of upstream's.
- **`projection-math-interop-guards`**: 5.5 moved
  `ManagedProjection::forward/inverse` onto `JNILocalRef` (fixing a
  local-reference leak) but still checks no exceptions; the four checks
  are re-added there.
- **`projection-sweep-hygiene`**: `Map.size` is gone from
  `model/Interop.cpp`; the remaining lookups are guarded by the same
  rule, including 5.5's new `ModelInfo.<init>`.
- **`quadtilenode4-resolvetexture-program-bind`**: fuzz put the program
  bind into a draw loop of another method; placed by hand at
  `resolveTexture`'s FBO block, which still binds no program in 5.5.
- **`terraintile-guard-missing-attribs`**: 5.5 guards `aNoDataFlag`
  (`!= -1`) but not `aNormals` or `aEcefVertCoords`; the no-data hunks
  are dropped as upstream, the rest ported.
- **`textformat2-class-init-consumer-guards`**: 5.5 deleted
  `TextFormatFactory_class`; the factory now calls the static
  `GLText.createTextFormat` and initialises inside `createTextFormat`
  as a function-local `static`. A guard placed before that line, where
  fuzz put it, would fail the first call and names a struct that no
  longer exists. Rewritten: the init guards the `GLText` lookups, and
  `createTextFormat` checks the method ID after the init.

Left for the JNI iteration (the guard series does not reach code 5.5
added): `FeatureDefinition` lookups moved to the new
`jni/interop/feature/ManagedFeatureDefinition.cpp`, and
`jni/interop/elevation/Interop.cpp` gained unguarded `HeightmapStrategy`
lookups. Both are guarded now (§JNI glue), which with the LAS and logger
patches brings the series to 37.

## Traps found on the way (do not rediscover these)

1. **`--fuzz=3` places hunks with no context.** GNU patch at fuzz N
   ignores N context lines at each end of a hunk; a 3-line-context hunk
   at fuzz 3 matches anywhere, and an addition-only hunk lands at its
   old line number plus the running offset. That put
   `traditionalGisOrder()` inside an `if/else` in `GdalLibrary.java`
   and the program bind into the wrong method of `GLQuadTileNode4`,
   with patch reporting success. The study's "9 fuzz-only" number
   came from these dry-runs. **Guard:** `refresh-patches.py` accepts a
   fuzzed result only when the regenerated hunks, context included,
   read the same as the original (whitespace and blank lines aside);
   anything else is `review`, rolled back and ported by hand.
2. **A reverse dry-run at fuzz 3 "finds" fixes that are not there.**
   `glbatchshaders-dead-store` reverse-applied at fuzz 3, so the study
   counted it as upstream; the dead store is still at line 447.
   **Guard:** the upstream check runs at `--fuzz=0`.
3. **`git log | grep -q` under `pipefail`** (G2 trap 8 again, in the
   port's own replay helper): `grep -q` exits on the first match, `git
   log` takes SIGPIPE, and the pipeline reports failure, so an applied
   patch read as not applied. Read the log into a variable first.
   It is the third time (G1 trap 2, G2 trap 8). **Guard:**
   `dev/check-pipefail-grep.sh` (`make lint`, CI's lint job) fails any
   script under `dev/` that sets `pipefail` and pipes into `grep -q`,
   `--quiet`, `-m` or `--max-count`. On `main` before the fix it found
   four more, all fixed on branch `chore/rebase-guards`:

   ```text
   [check-pipefail-grep] FAIL dev/g1/build-commo.sh:240: pipes into an early-exit grep under pipefail
   [check-pipefail-grep] FAIL dev/g2/fetch-angle.sh:86: pipes into an early-exit grep under pipefail
   [check-pipefail-grep] FAIL dev/g2/fetch-angle.sh:87: pipes into an early-exit grep under pipefail
   [check-pipefail-grep] FAIL dev/g2/fetch-angle.sh:113: pipes into an early-exit grep under pipefail
   ```

   After: `[check-pipefail-grep] OK: no early-exit grep at the end of a
   pipe under pipefail`. The fixed `fetch-angle.sh` re-staged ANGLE and
   passed its triangle smoke (`make angle`: `egl-triangle: PASS`).
4. **A new workflow escaped the Brewfile drift check.** `spike-55.yml`
   installs `ninja`, `mdbtools`, `glib` and `assimp`, none of them in
   the `Brewfile`. `supply-chain.yml`'s drift step reads every workflow,
   but the job ran only on PRs touching `ci.yml`, `cot-roundtrip.yml`,
   itself or the Brewfile pair, so #98 merged green and the next PR to
   touch `ci.yml` (#102) went red for it:

   ```text
   ##[error]Brewfile != union of the workflows' brew install lines
     in workflows only: assimp glib mdbtools ninja
   ```

   **Guard:** the four are in the `Brewfile` and its lock, and the job
   now triggers on any change under `.github/workflows/*.yml`, so a
   workflow that adds a package fails in its own PR (branch
   `ci/brewfile-spike-deps`).
5. **`java_home -v N` answers a missing JDK with the default one.** With
   no JDK 13 installed, `/usr/libexec/java_home -v 13` prints JDK 27's
   home and exits 0, so a script asking for JDK 8 silently ran on
   whatever is newest. **Guard:** `runtime.sh`'s `g55_jdk_home` checks
   `JAVA_VERSION` in the JDK's `release` file and fails on a mismatch.
6. **The android-port substitute shadows kernel classes.** It carries
   the 5.5.1.8 apk's own `com.atakmap.*`, including an Android
   `coremap.log.Log` that calls `android.util.Log`, whose substitute
   throws `Stub!`. With the jars in directory order, `android-port-*`
   came before `takkernel-*` and `EngineLibrary.initialize` died in
   `Log.w`. G1's classpath has the same order constraint. **Guard:**
   `g55_kernel_classpath` puts the kernel jars first and android-port
   last.
7. **A missing slf4j crashed `JNI_OnLoad`** (5.5's `ManagedLogger`,
   §JNI glue). **Guard:** `common-managedlogger-guards.patch`; the
   canaries take slf4j from the engine's own runtime classpath.
8. **commo swallows the cause of a QUIC failure.** Any exception from
   the handshake's `write`/`read` became "quic IO error during
   handshake", `CONN_OTHER`, whatever it was (here `EISCONN` from
   `sendto`). `QUIC_TEST_VERBOSE=1` prints commo's whole log, and a
   throwaway errno probe on `sendto` found it. **Guard: none yet (open).**
   Closing it takes a commo patch that carries the errno or exception
   text into the QUIC failure's error message, pinned by a
   `QuicStreamingTest` leg that forces a socket error and expects the
   cause in the output.
9. **The Swift shell boots whatever JDK `JAVA_HOME` names.**
   `jni_boot.c` loads `$JAVA_HOME`'s `libjli` and `shell/run.sh` never
   set it, so an inherited JDK 8 booted under classes `env.sh` had
   compiled for 21. A/B, `JAVA_HOME` pointing at Zulu 8, without the
   guard:

   ```text
   mactak-shell: libjli …/zulu-8.jdk/Contents/Home/jre/lib/jli/libjli.dylib
   java.lang.UnsupportedClassVersionError: mactak/render/WindowApp has been compiled by a more recent version of the Java Runtime (class file version 65.0), this version of the Java Runtime only recognizes class file versions up to 52.0
   ```

   **Guard:** `shell/run.sh` exports `JAVA_HOME` as the JDK that
   compiled the classes; with it, the same run boots
   `zulu-21.jdk/…/lib/libjli.dylib` and passes.

## Exit

The question this spike asked, whether 5.5's engine builds on macOS
without 3D Tiles, is answered yes, in one day of work, most of it the
patch port. The JNI and render steps took about a day together: the 5.5
glue loads in a JVM, passes G1's JNI tests and draws every G2 render
gate on ANGLE/Metal. Spike 2 took half a day: 5.5 commo, QUIC included,
passes the G1 comms gates. What remains before the re-pin (study step
4), in order, with estimates made from this spike's pace:

1. ~~**JNI glue on 5.5**~~ **Done** (§JNI glue). Carried forward: the
   `ManagedFeatureDefinition` consumer guards and guards-mode pins for
   the two new patches. Decided on #99's review: the 5.5 jars stay built
   in CI as here (CONTRIBUTING allows it), and **moving off Java 8**
   (the 5.5 jars are Java 11 bytecode: CI's Zulu 8 jobs, the launcher
   and the headless app) is its own PR on JDK 21, after this stack and
   before the re-pin.
2. ~~**The render gates on 5.5**~~ **Done** (§Render gates). Carried
   forward: `LayerStore`, `RenderSmoke` and `WindowApp` off the
   deprecated `FeatureDataStore` APIs, and the headless `layer.sh`
   canary, which waits for the launcher's move off Java 8.
3. ~~**Spike 2, commo on 5.5**~~ **Done** (§Commo): ngtcp2's `ossl`
   backend over `openssl@3`. Carried forward: `HeadlessCLI` onto the
   `StreamingTransport` overload; peer-to-peer QUIC, after the
   pre-existing interface-scanner bug; and whether ngtcp2 is built in CI
   as here or committed.
4. ~~**The Java 8 → 21 move**~~ **Done** (§State, JDK 21): every JVM
   on JDK 21. Carried forward to the re-pin: JDK 8 itself, kept for
   4.6's Gradle 6.9.1 and `javah`; the re-pin's 5.5 Gradle 8.13 and
   `javac -h` remove it.
5. **The re-pin** (1–2 days): fold `build-engine.sh`'s wrapper changes into
   `build-native.sh`, move `dev/spike/g55/patches` to `dev/g1/patches`,
   `jni-include/` to `dev/g1/jni-include` (replacing `gen-jni-headers.sh`,
   whose javah bundles 5.5 no longer uses) and `jni-tests/` over G1's,
   point `dev/g2/render/env.sh` at the 5.5 build (dropping the
   `MACTAK_RENDER_ENV` hook and the committed engine shadows for
   `render-env.sh`'s regenerated ones), move `patches/commo` and
   `fetch-ngtcp2.sh` into `dev/g1` (dropping `build-commo.sh`'s and
   `atak-headless`'s overrides), and change the 14 files that name
   `889eee2`.

About a week to a 5.5 baseline with today's gates green, 3D Tiles
still out: the Java 8 move and the re-pin.
