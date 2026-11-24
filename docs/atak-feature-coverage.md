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
| Map display: imagery and vector overlays | Engine | **Working** in a window: GeoJSON, GPKG, KML and SHP open through the native OGR provider; MBTiles and GeoTIFF imagery render under them, and GeoTIFF and DTED elevation draw as terrain (`make test-render`, `make test-shell`). The live window pans, zooms, tilts and turns with Apple Maps–style gestures at 60 fps over real imagery and terrain (`make exit-run`; G2 stays open on one dropped frame in 10–20 runs, in the window server) |
| CoT messaging, presence, contacts, tracks | commo | **Working**: TCP and SSL to FreeTAKServer and OpenTAKServer, TLS hardened (G1 security audit), received tracks persisted (`make test-roundtrip`, `make test-tls`). The app connects over TCP, TLS with client certificates, and QUIC (G3.2, `make test-app`) |
| Server certificates: Keychain, enrollment, device profile | App and commo | **Working** in the app: certificates in the login keychain, enrollment by username and password through commo, the device profile over commo's curl (G3.2c), and Quick Connect, enrolling against the system's public CAs (G3.2e) |
| Connection data packages (server and certificates) | App | **Working** in the app: the Servers section imports them, read as ATAK 5.5 does (G3.2b, G3.2d) |
| Elevation and terrain: DTED, slope | Engine | **In engine**: `DtedElevationSource`, `ElevationManager`, `ElMgrTerrainRenderService`, `GLTerrainSlopeAngleLayer` |
| 3D models and 3D Tiles | Engine | **In engine**: the model layer and Cesium 3D Tiles (`C3DTTileset`, `B3DM`) exist at 4.6; nothing exercises them |
| Coordinates (MGRS, UTM), range and bearing, measurement | Engine (math) and app (UI) | **Coordinates working** in the app (G3.6):<br>• MGRS, UTM, DD, DM and DMS, written and read as ATAK 5.5 does, golden-tested against 5.5's own formatter<br>• altitude in MSL (EGM96) or HAE, feet or metres<br>• ATAK's Units preferences, typed positions in any format, and the self readout over the map<br>• ADDR: addresses looked up with Apple Maps or an imported Nominatim server, for the placed position and for points, sent with a point as `<__address>`; addresses received on contacts and markers (G3.6c, G3.9d)<br>• range and bearing from me in a contact's details, true, magnetic (5.5's WMMHR-2025) or grid north, golden-tested against the engine (G3.8a)<br>• the R&B line tool: a line between markers or places, 5.5's label, following its markers (G3.8b–c)<br>• R&B lines shared as 5.5's `u-rb-a` CoT, to chosen contacts or everyone, and others' lines drawn (G3.8d)<br>• lines kept across launches (G3.9a), and R&B from a point's menu (G3.9c)<br>Not yet: range circles, the bullseye, Bloodhound, the dynamic R&B tool, measurement |
| Self-SA, self details and contacts | App (`cot`, `location`, `contact`, `comms/ReportingRate`) | **Working** in the app (G3.4):<br>• the self-SA as ATAK 5.5 builds it, golden-tested against the kernel (`make test-cot-golden`)<br>• `ReportingRate`'s pace: reliable to servers, unreliable to the mesh<br>• the self details under ATAK's preference keys, 5.5's custom roles, a hardware-derived device uid<br>• a contacts list with ATAK's stale and removal timing |
| Markers and MIL-STD-2525 symbols | App (`icons`, `cot/importer`) and takkernel `shared` (symbology) | **Working** in the app (G3.7):<br>• 5.5's own 2525 renderers (missioncommand's, Apache-2.0) in the app's JVM; the CoT type → 2525C mapping in Swift, golden-tested against the kernel<br>• contacts in 5.5's role icons and team colours, the self marker turned by the course<br>• received CoT markers with 5.5's icon for each: `icon_filters.xml`, 2525C symbol or unknown-type; damaged, colour tint, Spot Map<br>• 5.5's stale and removal timing, and delete tasks<br>• points dropped with a click: 2525C's four affiliations and Spot Map's colours, named as 5.5 names them (G3.9b)<br>• a right-click menu and an inspector for any CoT marker: name, affiliation, colour, remarks, address, move or drag, send, delete (G3.9c)<br>• points sent as 5.5's marker CoT field by field, golden-tested against the kernel; others' updates read as `MarkerImporter` reads them (G3.9d)<br>• map items kept across launches, as 5.5's StateSaver (G3.9a)<br>Not yet: the type picker, 2525D/E points, user icon sets, Mission Specific and vehicle palettes, coordinate entry for placing or moving, labels below the icon |
| Mesh networking: SA, chat and direct TCP with no server | App and commo | **Working** in the app, on by default as in ATAK: SA on 239.2.3.1:6969, chat on 224.10.10.1:17012, direct TCP on 4242, on every interface as it comes and goes (G3.3) |
| Mission packages, file transfer | commo and app | **In engine** (commo), switched off. Wiring them in must apply the G1 security rules first: pass the truststore on every transfer (#4) and restrict GDAL's drivers (#10), [dev/g1/NOTES.md](../dev/g1/NOTES.md) §G1.14 |
| Chat (GeoChat) | App (`chat`) | **Working** in the app (G3.5):<br>• messages and receipts built and read as ATAK 5.5 does, golden-tested against the kernel<br>• All Chat Rooms, team and role rooms, user-made groups and one-to-one, over servers and the mesh<br>• delivered and read receipts in one-to-one, as in 5.5<br>• history and user groups in SQLite; a Messages-style Chat window<br>Not yet: attachments, canned replies, TADIL-J |
| Drawing and shapes | App (`drawing`, `editableShapes`) | **To build**: about 19K lines |
| Routes and navigation | App (`routes`, `navigation`) | **To build**: about 31K lines |
| Geofences, Bloodhound, emergency, hashtags | App | **To build**: about 15K lines together |
| Image markup: rubbersheet, GRG, image capture | App | **To build**: about 33K lines with `image` |
| Fires, 9-line, MEDEVAC (`fires`, `munitions`, `medline`) | App | **To build**: about 10K lines |
| Layer, overlay and import managers; toolbars; preferences | App UI | **To build** (G3–G4) |
| TAK Server missions and sync, content services | App (`missionpackage`, `contentservices`) | **To build** (G6 rung 5): `missionpackage` alone is about 21K lines |
| Video (UAS and FMV) | App and platform | **To build** on AVFoundation (G6 rung 2): `video` is about 11K lines |
| GPS, Bluetooth, laser rangefinders, radios, camera | Platform | **Platform**: the self position comes from CoreLocation, or is placed by hand (G3.4b). External GPS, CoreBluetooth and serial I/O are G6 rung 4 |
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
  by porting a hot Java renderer to C++ one at a time.
- Porting cost is paid per package, so G3's feature list
  ([roadmap.md](roadmap.md) G3) is also its porting order.

## Recommendations

1. Settle the upstream baseline first: [rebase-study-5.5.md](rebase-study-5.5.md).
   Any app-layer port should target the version macTAK will ship.
2. ~~Record the reuse-or-rewrite decision, after the spike above.~~ Done
   2026-11-12: rewrite in Swift (above).
3. Finish M3.3–M3.4 (pan, zoom, gestures): no app-layer tool is usable on a
   static map, whichever option wins.
