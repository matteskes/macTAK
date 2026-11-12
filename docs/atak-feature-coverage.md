# ATAK feature coverage: what macTAK supports today

Research note, 2026-11-11. Question: does the codebase as it stands either
support, or put within easy reach, the full ATAK-CIV feature set? The
answer is measured against the pinned upstream source, not against
marketing material: ATAK publishes no 5.x release notes, and web sources
only list features in general terms.

Companion to [rebase-study-5.5.md](rebase-study-5.5.md), which looks at
the newer upstream tree this analysis points to.

## Verdict

Nothing in the architecture blocks a core ATAK feature, except plugins,
which are already out of scope ([roadmap.md](roadmap.md) G6 rung 6).
But almost every user-facing feature lives in a layer macTAK has not
started yet:

- **Engine and comms — ported.** `takkernel` (rendering, data stores,
  elevation, coordinate math) and `commoncommo` (CoT networking) build and
  run on macOS arm64. Much of ATAK's functionality ultimately runs through
  them.
- **The ATAK app — not started.** Every tool a user sees is Android code
  in `atak/ATAK/app`: 1,781 Java files, about 441K lines, 95 feature
  packages at the 4.6 pin. Roadmap gates G3–G6 rebuild it.

The roadmap's 3–5 year estimate for full parity still holds.

## Method

- Feature inventory: the package list of
  `atak/ATAK/app/src/main/java/com/atakmap/android` at `889eee2`
  (v4.6.0.5), with file and line counts per package.
- Engine capability: file and class lookups in `takkernel` at the same
  pin (for example `DtedElevationSource`, `C3DTTileset`, `MGRSPoint`,
  `GeoCalculations`).
- Android coupling: `import android.*` statements per app file, split into
  UI imports (`android.widget`, `android.view`, `android.app`) and the rest.
- macOS status: what the `make` targets and CI gates exercise today.

## Feature map

Status key: **Working** — exercised by a `make` target or CI gate.
**In engine** — the machinery is in the ported engine or commo but nothing
calls it yet. **To build** — app-layer code with no macOS counterpart yet.
**Platform** — needs a macOS framework in place of Android hardware APIs.

| ATAK feature | Where it lives upstream | macTAK status |
|---|---|---|
| Map display: imagery and vector overlays | Engine | **Working** in a window: GeoJSON, GPKG, KML and SHP open through the native OGR provider; MBTiles renders under them (`make test-render`, `make test-shell`). GeoTIFF is partway (G2.4 b.1). The frame is static: pan, zoom and gestures are M3.3–M3.4 |
| CoT messaging, presence, contacts, tracks | commo | **Working**: TCP and SSL to FreeTAKServer and OpenTAKServer, TLS hardened (G1 security audit), received tracks persisted (`make test-roundtrip`, `make test-tls`) |
| Connection data packages (server and certificates) | App | **Working** in the headless client (`atak-headless --datapackage`) |
| Elevation and terrain: DTED, slope | Engine | **In engine**: `DtedElevationSource`, `ElevationManager`, `ElMgrTerrainRenderService`, `GLTerrainSlopeAngleLayer` |
| 3D models and 3D Tiles | Engine | **In engine**: the model layer and Cesium 3D Tiles (`C3DTTileset`, `B3DM`) exist at 4.6; nothing exercises them |
| Coordinates (MGRS, UTM), range and bearing, measurement | Engine (math) and app (UI) | **In engine** for the math (`MGRSPoint`, `GeoCalculations`, `CoordinateFormatUtilities`); UI to build |
| Mission packages, file transfer, UDP mesh | commo and app | **In engine** (commo), switched off. Wiring them in must apply the G1 security rules first: pass the truststore on every transfer (#4) and restrict GDAL's drivers (#10), [dev/g1/NOTES.md](../dev/g1/NOTES.md) §G1.14 |
| Chat (GeoChat) | App | The messages are CoT, which works; UI to build (G3) |
| Drawing and shapes | App (`drawing`, `editableShapes`) | **To build**: about 19K lines |
| Routes and navigation | App (`routes`, `navigation`) | **To build**: about 31K lines |
| Geofences, Bloodhound, emergency, hashtags | App | **To build**: about 15K lines together |
| Image markup: rubbersheet, GRG, image capture | App | **To build**: about 33K lines with `image` |
| Fires, 9-line, MEDEVAC (`fires`, `munitions`, `medline`) | App | **To build**: about 10K lines |
| Layer, overlay and import managers; toolbars; preferences | App UI | **To build** (G3–G4) |
| TAK Server missions and sync, content services | App (`missionpackage`, `contentservices`) | **To build** (G6 rung 5): `missionpackage` alone is about 21K lines |
| Video (UAS and FMV) | App and platform | **To build** on AVFoundation (G6 rung 2): `video` is about 11K lines |
| GPS, Bluetooth, laser rangefinders, radios, camera | Platform | **Platform**: CoreLocation, CoreBluetooth, serial I/O (G6 rung 4) |
| Plugins | Android plugin SDK | Out of scope by decision; a macOS extension API instead |

Largest app packages at the pin, by lines: `maps` 42K, `routes` 23K,
`missionpackage` 21K, `image` 19K, `user` 16K, `layers` 14K, `track` 13K,
`drawing` 12K, `importfiles` 12K, `video` 11K.

## The app-layer decision: rewrite in Swift (decided 2026-11-12)

The roadmap's G3 does not yet say whether ATAK's app code is reused or
rewritten, and that choice sets the cost of everything after G2.

- 1,249 of the 1,781 app files (70%) import some Android API, but only 587
  (33%) import Android UI.
- The core map-item model is mostly not UI: `maps` has 147 files and only
  13 import UI; `cot` has 54 files and 3 do. What they need is Android's
  plumbing: `Context`, `Intent`, `Bundle`, `SharedPreferences`, broadcasts
  (ATAK's `AtakBroadcast`).
- macTAK has 21 Android stand-in classes today, written for the engine's
  render path (`dev/g2/render/src/android`). The app imports 335 distinct
  Android classes.

Two options:

- **A — run ATAK's own model on the JVM.** Extend the stand-ins (the
  approach G2 took for rendering) so ATAK's map-item model and CoT
  handlers run unchanged, and write only the UI natively.
- **B — rewrite in Swift.** Port behaviour package by package, using the
  Java as a specification.

This note leaned A for the model and CoT layers, because it reuses tested
code, and proposed a spike to settle it.

**Decided 2026-11-12 by the owner: B.** ATAK's app code is rewritten in
Swift, package by package, with the Java as the specification. The spike
above is not needed. What follows from it:

- The Android stand-ins stay scoped to the engine's render path
  (`dev/g2/render/src/android`); they do not grow to host app code.
- The engine and commo stay as ported (`takkernel` on the in-process JVM,
  `commoncommo`).
- **commo: the Swift app layer calls commo's C++ API directly** (decided
  2026-11-12), not through its Java binding. Fallback: if that proves
  challenging, it reverts to the existing JNI boundary, which the G1
  comms gates already exercise.
- **The engine: a hybrid, JVM first** (decided 2026-11-12). Swift calls
  a narrow Java facade (`EngineBridge`) over JNI, since the Java side
  owns the imagery renderers, `GLMapView` and the layer objects; it
  calls the engine's C++ directly only where C++ is the source of truth
  and the call is easy from Swift, and records each such carve-out.
  Swift map items (markers, routes, shapes) become features in an engine
  feature store, written in batches, so the engine's batch renderer
  draws them; Swift never draws GL itself. Why: the boundary carries
  user-rate calls, so it costs little either way; the overhead that
  matters (garbage-collection pauses, per-GL-call JNI in the Java
  renderers, JVM memory and startup) is inside the engine, and is
  measured at G2's exit run and paid down where the numbers show it,
  by porting a hot Java renderer to C++ one at a time. Dropping the JVM
  entirely is the long-term limit of that path, not a G3 step.
- Porting cost is paid per package, so G3's feature list
  ([roadmap.md](roadmap.md) G3) is also its porting order.

## Recommendations

1. Settle the upstream baseline first: [rebase-study-5.5.md](rebase-study-5.5.md).
   Any app-layer port should target the version macTAK will ship.
2. ~~Record the reuse-or-rewrite decision, after the spike above.~~ Done
   2026-11-12: rewrite in Swift (above).
3. Finish M3.3–M3.4 (pan, zoom, gestures): no app-layer tool is usable on a
   static map, whichever option wins.
