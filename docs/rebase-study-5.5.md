# Rebase study: ATAK-CIV 4.6.0.5 → 5.5.1.10

Study, 2026-11-11. Question: what would it take to move macTAK's upstream
baseline from the pinned 4.6 tree to the newer public source? No code
changes yet; this records the measurements so the follow-up spike starts
from them.

## Why now

macTAK pins `deptofdefense/AndroidTacticalAssaultKit-CIV` at `889eee2`
(v4.6.0.5). The roadmap and the risk registers assumed upstream was
frozen since October 2024 ([roadmap.md](roadmap.md) G6,
[pathway-c.md](pathway-c.md) §5 R7). That no longer holds: the source
now lives at
[TAK-Product-Center/atak-civ](https://github.com/TAK-Product-Center/atak-civ),
public and GPL-3.0, at 5.5.1.10 (latest commit 2025-12-01, "Merge branch
'upstream/5.5.1.10'").

Store listings already ship 5.6 or later, so even 5.5 trails the current
client by a minor version. The `VERSION.md` in the new tree stops at
4.6.1.0, so there is no upstream changelog for 4.6 → 5.5; everything below
comes from comparing the code.

[atak-feature-coverage.md](atak-feature-coverage.md) explains why the
baseline matters now: the app-layer port (G3 onward) should target the
version macTAK will ship.

## Recommendation

**Rebase to 5.5, in stages, before G3.** It is a real project rather than
a re-pin, mainly because of two new native dependencies (cesium-native and
ngtcp2/quictls) that upstream does not build for macOS. Sequence in
[§Next steps](#next-steps).

## Method

- Both trees side by side: the 4.6 pin (sparse checkout) and a shallow,
  sparse clone of `TAK-Product-Center/atak-civ` at `9f6893d`, limited to
  `takkernel`, `commoncommo`, `takcot`, `takproto`, `takthirdparty` and
  `depends`.
- Source files compared by path and content (`*.java`, `*.cpp`, `*.h`,
  `*.c`, `*.hpp`, CMake and Gradle files, `*.proto`, `*.xsd`).
- Every engine and commo patch dry-run against 5.5 exactly as the build
  applies it: `patch --forward --fuzz=0 -p3` on `takkernel/engine/src/main`
  (commo: `-p1` on `commoncommo`), then again with `--fuzz=3`, then in
  reverse to detect fixes already upstream. As a control, all patches
  were dry-run against the 4.6 pin: every one applies cleanly there.
- Every engine and commo class that macTAK's own Java imports looked up in
  the 5.5 tree.

## What changed upstream

| Area | 4.6 pin | 5.5.1.10 | What it means for macTAK |
|---|---|---|---|
| Engine (`takkernel`) version | 0.59.1 | **8.30.5** | — |
| Engine source files | 2,406 | 2,838 | 691 added, 259 removed; of the 2,147 files both share, 1,439 changed and 708 did not |
| Engine macOS build | `cmake/MacOSSources.cmake` | Still present | Upstream still carries a macOS build route |
| New engine dependencies | — | **cesium-native, draco** (3D Tiles; `formats/c3dt`, 21 new files) | Wired into the Android, Linux and Windows source lists, **not macOS**. `CommonSources.cmake` adds `CesiumNative.cpp` to every platform's sources, including the `elseif(APPLE)` branch, while only the other three platforms add cesium-native's include and library paths, so a stock 5.5 macOS build will not compile. cesium-native pulls in abseil, s2geometry and more; upstream's `cesium-native/` folder is only a build wrapper (Conan recipe, vcpkg overlay ports, `build-android.sh`) |
| GDAL | `gdal-2.4.4-mod` | **Still `gdal-2.4.4-mod`** | macTAK builds against Homebrew GDAL 3, so the GDAL 3 patches stay necessary |
| `stl-soft` | Used by `util/IO*.cpp` | No references | One dependency fewer; `build-native.sh` still adds its include path, which is harmless |
| Engine Java packages | — | 148 files added under `engine/.../java`, 113 under `shared/.../java` | macTAK's own Java is unaffected (below) |
| commo source files | 199 | 220 | 21 added, none removed; 57 changed |
| commo Java API | — | Grew only | Added: QUIC inbound interfaces, certificate enrollment, CoT detail extenders, destination-UID insertion. Nothing removed, so `atak-headless` keeps compiling |
| commo QUIC | none | **Required** | `quicconnection.cpp` and `quicmanagement.cpp` are always compiled and link `-lngtcp2 -lngtcp2_crypto_quictls`, so commo needs ngtcp2 built against quictls, a fork of OpenSSL |
| Wire protocol (`takproto`) | — | 3 of 10 files changed, additions only | Detail extensions (`ExtensionEncodedDetail`, a supported-extensions list in `takcontrol.proto`); 4.6 clients stay compatible |
| ATAK app layer | 1,781 Java files | 1,962 (+10%) | Two new packages: `databridge` and `eud` |

## macTAK's patches on 5.5

37 engine patches (34 in [dev/g1/patches](../dev/g1/patches) and 3 GDAL
drift patches in [dev/spike/g0/patches](../dev/spike/g0/patches)) and 2
commo patches. The 34 in `dev/g1/patches` touch 62 files: 50 changed in
5.5, 11 did not, and one is gone
(`renderer/feature/GLBatchGeometryRenderer3.cpp`).

Measured by porting them (spike 1, [dev/spike/g55/NOTES.md](../dev/spike/g55/NOTES.md)
§The patch port, which names every patch):

| Result on 5.5 | Count |
|---|---|
| Apply unchanged at `--fuzz=0` | 17 |
| Refreshed by `refresh-patches.py` (context intact, indentation drift) | 1 |
| Hand-ported, same hunks | 7 |
| Hand-ported, reworked for 5.5's code | 9 |
| Dropped, fixed upstream: `cpp17-legacy-headers`, `megatexture-sharetile-comma-operator`, `terraintile-ecef-ge` | 3 |

The 5.5 series is 34 patches. The rework is mostly the JNI guard series,
`vsi-jfile-gdal3-api` (5.5's `vsi_jfile.cpp` still targets GDAL 2's VSI
interface) and `megatexture-release-erase-while-iterating`, whose
upstream fix hangs once a tile is shared.

This study first reported 17 clean, 9 fuzz-only and 11 failing, with
`glbatchshaders-dead-store` already upstream. Those dry-runs ran at
`--fuzz=3`, which matches a hunk with no context: hunks landed in the
wrong place and a reverse match was spurious (the dead store is still in
5.5). Spike 1's traps 1–2 record both and the guard.

commo:

- `0002-sslcertchecker-require-server-purpose` (G1 security audit #1)
  **applies cleanly, and the bug is not fixed upstream**: 5.5's
  `internalutils.cpp` still never sets `X509_PURPOSE_SSL_SERVER`. The
  patch must carry over.
- `0001-diag-socketRead-errno` applies only with fuzz.

macTAK's own Java imports 73 engine and commo classes, all present in 5.5.
Two moved: `com.atakmap.map.Interop` (gone; `com.atakmap.interop.Interop`
remains) and `com.atakmap.util.Disposable` (now `gov.tak.api.util.Disposable`).
Only the `GLQuadTileNode4` engine shadow uses them, and engine shadows are
regenerated from the patches, so they follow whatever the patch refresh
produces. The calls the render and headless code depend on keep their
signatures (`GLMapView(RenderContext, Globe, int, int, int, int)`,
`DatabaseImpl.openOrCreate(String)`).

## Finding independent of the rebase

5.5's `takproto/cotevent.proto` notes that CoT's `access` attribute,
optional in early implementations, is required by MIL-STD-6090: new
clients should send it on every outgoing message, as `Undefined` when
there is no real value. macTAK's CoT builder
([CotXml.java](../dev/g1/headless/src/mactak/headless/CotXml.java))
never emits it. TAK servers accept CoT without it today; adding
`access="Undefined"` is a small fix that does not depend on the rebase.

## Next steps

1. **Spike the 5.5 engine on macOS without 3D Tiles.** Leave the
   cesium-native and draco sources out, as G0 left out the drivers it
   could not build, and port the patch series. This is the G0-style answer to whether 5.5 builds here.
   **Done 2026-11-11: it builds** (471 of 471 steps, `libtakengine`
   links); the record, the remaining steps and a time estimate are in
   [dev/spike/g55/NOTES.md](../dev/spike/g55/NOTES.md). **The JNI glue
   followed the same day:** it loads in a JVM and passes G1's JNI
   tests, and showed that the 5.5 desktop jars need Java 11 or later
   (macTAK runs Java 8 today). **So did the render gates:** all of the
   G2 render gates pass on ANGLE/Metal, after one shader fix.
2. **Spike 5.5 commo.** Decide the QUIC crypto backend: Homebrew's ngtcp2,
   a quictls build, or a patch onto OpenSSL 3.5's own QUIC support. Then
   rerun `make test-roundtrip` and `make test-tls`.
   **Done 2026-11-11: OpenSSL 3.5's own QUIC support**, through ngtcp2's
   `ossl` backend built against `openssl@3`. quictls is OpenSSL 3.0,
   which reached end of life on 2026-09-07, and Homebrew's ngtcp2 links
   `openssl@4`. 5.5 commo then passes the TLS and round-trip gates, and
   QUIC to a `takstream` server works, purpose check included
   ([dev/spike/g55/NOTES.md](../dev/spike/g55/NOTES.md) §Commo).
3. **Add cesium-native and draco** only when 3D Tiles is needed on macOS.
4. **Re-pin.** CI checks out `889eee2` in two workflows
   (`ci.yml`, `cot-roundtrip.yml`), and twelve more files name it: the
   README, CONTRIBUTING, five docs, two NOTES, and three files under
   `dev/g1/tools`. Move them to the 5.5 tree, and update the
   roadmap's baseline paragraph and the risk registers.

No time estimate yet: the first spike is the natural point to make one,
as G0 was for 4.6.
