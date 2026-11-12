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

Still unanswered, on purpose: whether it *runs*. No test, canary or JVM
load was attempted; the JNI glue and the gates are the next iteration
(Exit).

## Reproduce

```sh
brew install cmake ninja rsync proj geos gdal libspatialite minizip nlohmann-json libxml2 mdbtools glib assimp
git clone --filter=blob:none --no-checkout https://github.com/TAK-Product-Center/atak-civ ../atak-civ
git -C ../atak-civ sparse-checkout set takkernel/engine/src/main khronos takengine/thirdparty/tinygltfloader depends
git -C ../atak-civ checkout 9f6893dd657feacc35ec5de03dad721c2e44170e
git -C ../atak-civ lfs pull --include=depends/tinygltf-2.4.1-mod.tar.gz
bash dev/spike/g55/build-engine.sh ../atak-civ
# re-sort the 4.6 series against a 5.5 tree (writes clean + refreshed only):
python3 dev/spike/g55/refresh-patches.py ../atak-civ/takkernel/engine/src/main /tmp/out
```

CI: `.github/workflows/spike-55.yml` (dispatch, or a push to a
`spike/g55-*` branch that touches this directory) runs the same script
on `macos-26` and uploads `build.log` and `summary.txt`. It is not a
required check; a red run is the spike's answer, as G0's was
([docs/ci-qa.md](../../../docs/ci-qa.md) §7).

## What's here

| Path | Role |
|---|---|
| `refresh-patches.py` | Sorts the 4.6 series against a 5.5 tree, stacked in build order: clean, refreshed, review, upstream, failed |
| `patches/` | The 5.5 series: 34 patches, applying at `--fuzz=0` in `build-native.sh`'s order (`gdal-drift-*` first, then sorted) |
| `build-engine.sh` | The core-engine half of `build-native.sh` against a 5.5 checkout; `formats/c3dt` left out; `ninja -k 0` |
| `summarize-build.py` | Every failing source with its first error, the errors grouped by kind, and the undefined symbols of a failed link |

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
lookups.

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

## Exit

The question this spike asked, whether 5.5's engine builds on macOS
without 3D Tiles, is answered yes, in one day of work, most of it the
patch port. What remains before the re-pin (study step 4), in order,
with estimates made from this spike's pace:

1. **JNI glue on 5.5** (2–3 days). Regenerate the pinned javah headers
   (`dev/g1/gen-jni-headers.sh`) from the 5.5 jars; drop `jni/c3dt` and
   `jni/interop/formats/c3dt` as `build-native.sh` drops `/c3dt/` today;
   extend the guard series to the class-inits 5.5 added (above); rebuild
   `dev/g1/jni-tests` and the JVM load canary. The engine jar and the
   android-port transplant need their 5.5 builds (with `SHA256SUMS`, per
   CONTRIBUTING).
2. **The render gates on 5.5** (2–4 days). `make test-render` against
   ANGLE: the engine shadows (`GLQuadTileNode4` and the rest) regenerate
   from the 5.5 patches, and `KHR_debug` decides whether
   `GLBatchGeometryRenderer4` needs the attrib guards
   `GLBatchGeometryRenderer3` had.
3. **Spike 2, commo on 5.5** (study step 2; 3–5 days): the QUIC backend
   decision.
4. **The re-pin** (1–2 days): fold `build-engine.sh`'s wrapper changes into
   `build-native.sh`, move `dev/spike/g55/patches` to `dev/g1/patches`,
   and change the 14 files that name `889eee2`.

Roughly two to three weeks to a 5.5 baseline with today's gates green,
3D Tiles still out.
