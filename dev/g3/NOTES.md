# G3 — the core client skeleton

G3 turns G2's map window into a TAK client: a contacts list, CoT markers
and routes on the map, GeoChat, server connections with certificates in
the macOS Keychain, a layer manager and coordinate tools. **Exit:** two
Mac clients on one TAK server see each other's markers and chat live
(`docs/roadmap.md` G3).

## State (G3.7 done — 2026-11-18): servers, identity, mesh, SA, GeoChat, coordinates and markers

`app/` is a Swift package. Its SwiftUI app, `MacTAK`, opens the engine's
live map beside a sidebar (G3.0), and talks to TAK servers through
`CommoClient` over `CCommoShim` (G3.1). G3.2 made it a client of real
servers:

- over TCP, TLS with client certificates, or QUIC (G3.2a)
- with certificates kept in the Keychain and ATAK data packages imported
  (G3.2b)
- with client certificates enrolled for by username and password, and
  the device profile fetched (G3.2c)
- with a Servers section in the sidebar to add, import, enroll and
  connect, and its status shown per server (G3.2d).

Every TAK connection uses commo's OpenSSL 3, and the bundle carries
OpenSSL's legacy provider.

G3.3 made it a client with no server too. It joins the local network's
TAK mesh (SA, chat and direct TCP, on ATAK's ports) on every interface,
on by default as in ATAK (G3.3a, #191). The sidebar's Mesh section
switches it and shows its status (G3.3b, #192). Two copies of the app
on `en0` saw each other with no server.

G3.4 made it a TAK client that reports itself and lists its team:

- **The CoT model is Swift** (`MacTAKCot`). The kernel's own `CotEvent`
  is its test oracle: both are held to the same golden events
  (`make test-cot-golden` in CI's JVM job) (G3.4a, #196).
- **The self-SA goes out as ATAK 5.5 sends it.**
  - At `ReportingRate`'s pace: reliable to servers, unreliable to the
    mesh, and at once on a change.
  - With the self details under ATAK's preference keys, including 5.5's
    custom roles.
  - With a device uid made from the Mac's hardware UUID.
  - With a position from CoreLocation, from one placed by hand, or both
    (G3.4b, #197).
- **The sidebar's Contacts section** lists who is heard on a server or
  the mesh, greyed and removed on ATAK's timing. A My Details sheet edits
  this client's own details. Two copies on `en0` checked it all by hand
  (G3.4c, #198).

G3.5 made it a GeoChat client, as ATAK 5.5 chats:

- **The chat events are Swift** (`MacTAKCot`): messages and receipts
  are built and read as 5.5 does. Eleven ATAK-shaped chat events joined
  the kernel's golden test (G3.5a, #200).
- **The rooms come from the contacts:** All Chat Rooms, a room for each
  team and role, user-made groups, and one-to-one. Only your own team's
  and role's rooms take messages. Delivered and read receipts come back
  in a one-to-one only; pending is read, never sent. The history and
  user groups persist in SQLite. A chat leg for each room kind runs in
  CI, through the fake server and on the mesh (G3.5b, #201).
- **A Chat window** laid out like Messages, with unread counts in the
  sidebar. Two copies checked every room kind, the receipts, user groups
  and the history by hand (G3.5c, #202).

G3.6 gave it ATAK's coordinates:

- **The coordinate math is Swift** (`MacTAKCot`): MGRS (the default),
  UTM, DD, DM and DMS, written and read as 5.5 does, and altitude in
  MSL or HAE from the engine's EGM96 grid. 5.5's own formatter and the
  engine's geoid code are the golden test's oracles (G3.6a, #206).
- **The app shows them as set:** a Units pane in Settings under ATAK's
  preference keys; contacts and My Details in the chosen format and
  altitude; positions typed in any format, read exactly as 5.5 reads
  them; and a self readout over the map that pans to you or cycles the
  format. Two copies checked it all by hand (G3.6b, #207).

G3.7 put markers on the map, drawn as ATAK 5.5 draws them:

- **The 2525 renderers run in the app's JVM.** Spike #171 found that
  5.5's own renderers are public, under Apache-2.0: missioncommand's
  2525C set for markers, and 2525D/E for later. The CoT type → 2525C
  mapping is Swift. The kernel is the golden test's oracle: 1,200
  symbols drew pixel-identical to it (G3.7a, #209).
- **The map draws contacts and the self marker:**
  - Contacts get 5.5's role icons in their team colour, or their 2525
    symbol.
  - Stale contacts turn grey.
  - The self marker is 5.5's blue arrow, turned by the course.

  A CI render gate checks the markers' pixels (G3.7b, #210).
- **CoT markers that aren't contacts draw too**, with 5.5's icon for
  each:
  - its `icon_filters.xml` icon, its 2525C symbol, or else the
    unknown-type icon
  - the damaged icon when not ready, the marker's colour as a tint,
    and Spot Map dots

  They go stale and are removed on 5.5's timing, and a delete task
  greys or removes one. A hand check ran a marker for each rule
  (G3.7c, #214).

Next: G3.8, routes, dropping, editing and deleting points, and the layer
manager.

## The plan (approved 2026-11-13)

Decided before this plan (`docs/atak-feature-coverage.md` §The app-layer
decision): ATAK's app code is rewritten in Swift with the Java as the
spec; Swift calls commo's C++ API directly (the JNI binding is the
fallback); Swift reaches the engine through a narrow Java facade,
`EngineBridge`, and map items become engine features written in batches.

Decided with the plan:

- **The app is a SwiftPM package at `app/`**, not an Xcode project and
  not scripts under `dev/`: product code, buildable with `swift build`
  in CI.
- **SwiftUI for the panels; the map stays the AppKit Metal view**, hosted
  with `NSViewRepresentable`, so its render loop and input don't change.
- **The exit runs against FreeTAKServer and OpenTAKServer**, both in
  containers. G1 found OpenTAKServer stricter: it doesn't echo a client's
  own events back, so it catches a round trip that only passes on the
  echo (`dev/g1/NOTES.md` §Round-trip contract).
- **The exit runs over TLS with client certificates from the Keychain**
  (port 8089), which is how real TAK servers are run.

Found while planning: commo's own Objective-C binding
(`src/commoncommo/objc`) is not a shortcut. It targets iOS 9.1, has no
QUIC, and covers about half of the C++ API. commo's C++ API is C-shaped
(`const char*`, byte buffers, plain enums), which Swift's C++ interop
handles; its callbacks are abstract C++ classes, which Swift cannot
subclass, so G3.1 adds a small C++ shim that forwards them to Swift.

| Milestone | What | Gate |
|---|---|---|
| **G3.0** | the package, the SwiftUI skeleton, `EngineBridge` v0, `make app` | `make test-app` (CI); G2's gates unchanged |
| **G3.1** | commo from Swift: a C++ listener shim, a `CommoClient` actor | two clients through `fake-cot-server.py` see each other (CI) |
| G3.2 | servers and identity: `.p12` and data-package import into the Keychain, TLS, **certificate enrollment** (1) and the device profile, **QUIC** (2) | TLS and QUIC legs against fake servers, in a throwaway keychain; an enrollment leg against a fake `signClient` |
| G3.3 | **mesh networking** (3): multicast SA and chat, direct TCP, with no server | two clients on one Mac see each other with no server |
| G3.4 | SA: the CoT model, contacts, **`ReportingRate`** (4), and **the self details** (5): a persistent uid, extended roles, `precisionlocation`, the location source | CoT parse tests; golden tests against the kernel's serializer; the rates and stale times follow `ReportingRate`'s rules |
| G3.5 | **GeoChat** (6): All Chat Rooms, one-to-one, team and role rooms, user groups, delivered, read and pending receipts | a chat leg per room kind, with receipts |
| G3.6 | **coordinates** (7): MGRS (the default), DD, DM, DMS, UTM; altitude in MSL (the default) or HAE | conversion tests against the engine's |
| G3.7 | **markers on the map with 2525 symbols** (8), the self marker; the renderer comes from the #171 spike | markers' pixels where expected (CI) |
| G3.8 | routes, dropping, editing and deleting points, the layer manager | a route render; a dropped point reaches the other client |
| Exit | `make g3-exit`: two app instances, TLS, FTS and OTS | each sees the other's contact, marker (on screen) and chat |

The numbers in bold refer to the sanity check's gaps (§Plan revision, below).
Before the revision, the order was G3.2 the CoT model and markers, G3.3
GeoChat, G3.4 servers and the Keychain, G3.5 routes and points, G3.6 the
layer manager and coordinate tools.

## Plan revision (2026-11-13): the 5.5 sanity check

After G3.1, the plan was checked against how ATAK 5.5 implements each
feature. The 5.5 app was read at the pin (`atak-civ` `9f6893d`), from
`src/`'s git objects, since the sparse checkout leaves the app out:
`git -C src show 9f6893d:<path>`. Findings came from reading code, not
from running it.

### What already matched

- **Map items as engine features.** 5.5 draws map items through
  `MapItemsFeatureDataStore`, `GLMarkerFeature` and `GLPolylineFeature`,
  on by default (`mapitem.features.enabled` = 1). That is what this plan
  does through `EngineBridge`.
- **commo as the comms core.** ATAK drives the same core through its Java
  binding (`CommsMapComponent`); G3.1 drives it from Swift.
- **The self-SA's shape.** `takv platform='macTAK'` stays: macTAK is not
  an official TAK product.

### The eight gaps, adopted by the owner in this order

1. **Certificate enrollment.** TAK Server users usually get a certificate
   by username and password. ATAK enrolls through commo's own API
   (`enableEnrollment`; `core/impl/enrollmentmanager.cpp` builds
   `signClient`). It then fetches a device profile from
   `/api/tls/profile/enrollment?clientUid=…`, with basic auth on port 8446
   (`CertificateEnrollmentClient`, `DeviceProfileOperation`).
2. **QUIC streaming.** 5.5's stream transports are `tcp`, `ssl` and
   `quic`, with `network_quic_enabled` on by default. ATAK also opens a
   QUIC inbound interface on port 4243. Our commo already has QUIC
   (`make test-quic`).
3. **Mesh networking.** With no server, ATAK still works peer to peer:
   SA on multicast 239.2.3.1:6969, chat on 224.10.10.1:17012, and direct
   TCP on port 4242 (`TadilJContact`, `ChatManagerMapComponent`,
   `CotMapComponent`). macOS's Local Network permission is asked for
   once, at the first multicast, and the app's `Info.plist` gives the
   reason (G3.3b).
4. **SA pacing (`ReportingRate`).**
   - It keeps two streams, unreliable (mesh) and reliable (servers).
   - The strategy is "Dynamic" by default: 30 s and 180 s when
     stationary, and between 20 s and 2 s when moving.
   - "Constant" sends every 3 s and 15 s.
   - The stale time is padded past the interval (`STALE_PADDING`, 15 s).

   G3.1 beacons on a fixed interval with a 30 s stale.
5. **The self details.**
   - **A persistent device uid:** ATAK's `bestDeviceUID` is never cloned
     with the preferences. Stable uids also matter on OpenTAKServer
     (issue 145).
   - **5.5's extended roles:** `customRole`, `customRoleAbbreviation` and
     `displayAsSymbologyGraphic`, mapped to `__group` by the kernel's
     `gov.tak.api.cot.detail.GroupDetailHandler`.
   - **`precisionlocation`.**
   - **A location source:** CoreLocation, manual entry ("set my
     location"), or both.
6. **GeoChat rooms and receipts.** Besides "All Chat Rooms" and
   one-to-one, ATAK has team rooms (`TeamGroup`), role rooms (`RoleGroup`)
   and user-made groups (`ChatDatabase`'s `Groups`), with delivered, read
   and pending receipts (`b-t-f-d`, `b-t-f-r`, `b-t-f-p`, through
   `__chatreceipt`).
7. **Coordinates.** `CoordinateFormat` has MGRS (the default), DD, DM,
   DMS, UTM and ADDR (a street address, which needs a geocoder). Altitude
   shows in MSL by default (`UnitPreferences`), which needs a geoid.
   ADDR waits for a geocoder.
8. **Marker symbols.** 5.5 renders MIL-STD-2525 symbols through the
   kernel (`gov.tak.platform.symbology.milstd2525`, on `mil-sym-java`).
   The revised plan uses a 2525 renderer instead of drawing an icon set
   of our own. Correction (2026-11-13, §Decided below): that code is not
   in our JVM and does not build from public sources, so which renderer
   is a spike (#171).

### Decided (2026-11-13): port the kernel's app-level code to Swift

5.5 moved code that used to be the app's into takkernel's `shared`
module. The question was whether the app calls it on the JVM through
`EngineBridge` or ports it to Swift. Measured at the pin (`main` and
`jre` source sets):

| Package | Lines | ATAK app files importing it | Runs on our JVM? |
|---|---|---|---|
| `gov.tak.api.cot` (CoT model, `CotDetailManager`, group and bullseye handlers, roles) | 6.5k | 29, plus 152 on `com.atakmap.coremap.cot.event` | mostly: `CotEvent` imports `Parcel`; `RolesManager` draws with `android.graphics` (Stub! at runtime) |
| `gov.tak.api.importfiles` (file-type resolvers) | 2.8k | 52 | partly: `android.net.Uri` (G2 has a shim), `android.util.Pair` (stub) |
| contacts API | 1.1k | 2 | yes |
| 2525 symbology | 6.4k | about 20 | **no**: the desktop glue compiles only against the TAK artifactory's renderer (G1.15 in `../g1/NOTES.md`) |
| widgets | 14.3k | — | GL widgets on the map; SwiftUI and AppKit replace them |

Two facts settled it:

- **The detail handlers G3.4 needs never moved.** The kernel has the
  manager and the group and bullseye handlers. The 31 others (contact,
  track, status, `precisionlocation`, `takv`, link, remarks, …) are
  still in the app (`com.atakmap.android.cot.detail`), written against
  `MapItem` and `MapView`, so they are ported to Swift either way.
- **The app doesn't ship `shared`.** `build/MacTAK.app` carries the
  engine, port and annotation jars only; `shared` is built for
  `make test-kernel` alone. The earlier "already in our JVM" was wrong.

**The decision (owner, 2026-11-13):**

- **Port to Swift**: the CoT model and detail manager, contacts and the
  import resolvers, as the original G3 plan had it. CoT stays on the
  commo → `CCommoShim` → Swift path with no JNI round trip, no Android
  stub runs at runtime, the security fixes (#167, #168) land in code we
  own, and the JVM stays the render engine only, which keeps G6 rung 8
  open.
- **The kernel is the test oracle.** Reuse's best upside, emitting what
  Android peers emit, is kept by golden tests: a test leg runs the
  kernel's `CotEvent` and `CotDetailManager` (already compiled and
  tested by `make test-kernel`) over the same inputs as the Swift port
  and diffs the XML. Upstream's serializer defines correct without being
  in the runtime path. G3.4 adds the leg.
- **2525 is decided separately**, after a spike (#171): neither the JVM
  nor Swift gets the symbols for free from public sources. G3.7 waits
  on it.
- **Widgets are skipped.** SwiftUI and AppKit replace them.

### Not adopted (yet)

A G3 exit leg against a real ATAK-CIV client, such as an Android
emulator, would catch interop drift that two macTAK clients can't. It
was suggested in the sanity check but not adopted.

## G3.0 — the app skeleton (2026-11-13, branch `g3/app-skeleton`)

### What changed

- **`app/Package.swift`**, with four targets:
  - `CJavaBoot`: the C that finds `libjli` and creates the JVM, moved
    from `dev/g2/shell` (`jni_boot.c`, `include/bridge.h`).
  - `MacTAKCore`: `JNI` (Swift over the JNI function table, main thread
    only), `JavaBoot`, `EngineBridge` (the Swift client and
    `MapConfig`) and `MetalView` (the map's view and its input, moved
    from the shell).
  - `mactak-shell`: the G2 harness, now only option parsing, the
    scripted input and the gates' window life cycle.
  - `MacTAK`: the SwiftUI app. `LaunchConfig` reads
    `Resources/engine/launch.json`; `EngineHost` boots the JVM, starts
    the map and tears it down on quit.
- **`jni.h` is the repo's pinned copy** (`dev/g1/jdk-include`). The JNI
  calls used are JNI 1.8's, which JDK 21 serves unchanged, so building
  the package needs no JDK; CI's shell job dropped its JDK step.
- **`mactak.engine.EngineBridge` and `MapConfig`**
  (`dev/g2/render/src/mactak/engine`). `MapConfig` is a plain data holder
  whose public fields Swift sets by name; `EngineBridge` delegates to
  `WindowApp`, which keeps the render thread, the gates and the frame log.
  `MapConfig.contentGate` (default true) lets the app skip the
  first-frame content check: its data may keep loading after the first
  frame.
- **`build-shell.sh`** runs `swift build -c release --product
  mactak-shell` and copies the binary to `dev/g2/build/mactak-shell`, the
  path `run.sh` and the gates use.
- **`app/bundle.sh`** (`make app`) assembles `build/MacTAK.app`: the app,
  the render classes, the jars, the engine natives and ANGLE, GDAL's JNI
  library, the starting data and `launch.json`, ad-hoc signed. It's a
  development bundle for this Mac: it starts the JDK 21 that `java_home`
  finds, and the natives link Homebrew's libraries by absolute path. A
  self-contained bundle is G5's work.
- **`make test-app`** builds every product and runs `swift test`. CI runs
  it in the shell job. Its two tests are drift checks across the JNI
  boundary: Swift's `MapConfig` sets exactly the fields `MapConfig.java`
  declares, and Swift's `Gesture` matches `InputBridge`'s kinds.

### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app` | 2 tests pass. A/B: a field added to `MapConfig.java` alone fails the drift test ("Java fields Swift never sets: probe") |
| `make test-shell` | all four legs pass (first frame, exit code, live with resize, gestures) |
| `make test-render` | all four gates pass |
| `render/test/input-bridge.sh` | passes |
| `make exit-run` | 4 runs: 3 with zero dropped frames; 1 dropped one frame (27 ms at 4.48 s, 0.6 ms CPU, 0.26 ms GPU): trap 77 of G2, tracked in #125, at its usual rate |
| `make app` | the window opens with the sidebar and the map: NAIP imagery, terrain and the landmarks, interactive; ⌘Q tears the engine down and exits |
| `make lint` | passes |

### Traps

- **1 — SwiftUI sizes the map view twice before it settles.** The view
  joins its window and gets a first size, and SwiftUI then resizes it
  while laying out the window. Starting the engine on the first size
  created the window surface after the layer's drawable had moved on, and
  the surface check failed ("rebuilt surface did not take the new size").
  `MetalView` now reports ready only once it's in a window with a
  non-empty size, and the app starts the engine one run-loop turn later.
  A resize by the user in the half second before the surface exists could
  still race; the G2 gates never resize then, and the app shows the
  failure rather than hanging.

## G3.1 — commo from Swift (2026-11-13, branch `g3/commo-from-swift`)

### What changed

- **`CCommoShim`** (C++): one `Forwarder` class implements commo's
  `CommoLogger`, `CoTMessageListener`, `ContactPresenceListener` and
  `InterfaceStatusListener` and forwards each callback to a C function
  pointer with the caller's context. Its API (`commo_shim.h`) is plain C:
  create and destroy, add and remove a streaming interface (TCP, or SSL
  with PKCS#12 bytes), broadcast, and send to contacts. No C++ exception
  leaves the shim; each failure comes back as a message.
  `mactak_commo_init_libraries` does what the Java binding's
  `initThirdpartyNativeLibraries` does (libxml2, OpenSSL, curl), finding
  the functions with `dlsym` because commo has already loaded them, so the
  shim needs none of their headers or link flags.
- **`MacTAKComms`**: the `CommoClient` actor (connect, disconnect,
  broadcast, send, `shutdown`) with one `AsyncStream<CommoEvent>` for CoT,
  contacts, interface changes and commo's log (filtered by level). Its
  beacon sends self-SA on a period and once more 500 ms after each
  interface comes up. `Presence` builds the self-SA, ported from G1's
  `CotXml.presence` and `xmlEscape`.
- **`MacTAKCommsTests`**: two clients through `fake-cot-server.py` on a
  free port. A connects and beacons; B connects, beacons and drops a
  marker. The test passes when A sees B as a contact and gets B's marker,
  and B gets A's presence: G1's round-trip contract (`dev/g1/headless/run.sh`).
  Two smaller tests check that a shut-down client refuses to send and that
  the presence escapes its text.
- **`make test-app-comms`** runs the package's build and tests with
  `MACTAK_COMMO_LIB` set to commo's directory. (It first staged commo
  through `app/stage-commo.sh`, retired with trap 2's fix below.) CI runs it in
  the comms job, right after `build-commo.sh`.

### Decided while building

- **A C API, not Swift's C++ interop.** The plan had Swift calling commo's
  C++ API directly, with a shim only for the callbacks. Swift's C++
  interop is a per-module compiler mode that can carry over to the
  modules that import one built with it: here, `MacTAKComms` and then the
  app. With a plain C header, the shim does the C++ calls as well, and
  the rest of the package stays ordinary Swift. The shim is about 400
  lines with its header.
- **The comms targets are optional, for now.** `Package.swift` adds
  `CCommoShim`, `MacTAKComms` and their tests only when `MACTAK_COMMO_LIB`
  is set. Building them needs commo's headers (`src/`) and a built commo,
  which CI's shell job doesn't have and shouldn't build for every app
  change. The comms job has both. The switch is an environment variable,
  so it's explicit; the targets come and go with it (checked with
  `swift package describe`). G3.2 has to settle this, since the app itself
  will need commo: the likely answer is that the shell job builds against
  the comms job's commo artifact.
- **`MacTAKComms` is its own module**, not `MacTAKCore/Comms` as planned,
  so that `MacTAKCore` still builds without commo.

### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app-comms` | 3 comms tests pass; the two-client test takes 4.2 s and passed 5 more runs in a row. A/B: with the shim's CoT forwarding disabled, it fails after 15 s waiting for B's marker |
| `make test-app` | 2 tests pass; the package still builds without commo (the comms targets are absent) |
| `make lint` | passes |

### Traps

- **2 — commo's install name points next to its loader.**
  `build-commo.sh` names the dylib `@loader_path/libcommoncommo.dylib`,
  which is right for the JNI library beside it. A Swift binary linked
  against it would look for commo in its own directory: the test bundle's,
  or the app's `MacOS/`. `app/stage-commo.sh` copies it to
  `app/.build/commo` with the install name `@rpath/libcommoncommo.dylib`
  (signed again: `install_name_tool` breaks the signature), and the shim's
  target adds that directory as an rpath. G1's copy is left as it is.
  **Fixed at the source** (2026-11-16, #152, `dev/g1/NOTES.md` §G1.32):
  `build-commo.sh` now names commo `@rpath/libcommoncommo.dylib`, its JNI
  library finds it through an `@loader_path` rpath, and the Swift package
  links `dev/g1/native-dist` directly; `app/stage-commo.sh` is gone.
- **3 — the app claimed macOS 14; its floor is macOS 27.** G3.0 set
  macOS 14 in `Package.swift` and `Info.plist` without a decision behind
  it, while every native library the app loads was built for the build
  machine's macOS: commo and the engine for 27.2, Homebrew's GDAL for
  27.0 (ANGLE's pair for 12.0). The owner's floor is macOS 27, so both
  now say 27.0 (2026-11-13). Two consequences:
  - **CI:** a package built for 27 doesn't launch on 26, so the two jobs
    that run it, `shell compile` and `comms stack`, moved from `macos-26`
    to `xcode-27`, GitHub's macOS 27 image. It's a preview: GitHub warns
    it can be unstable and queue longer. actionlint doesn't know the label
    yet, so `.github/actionlint.yaml` lists it. The other jobs never
    launch the app and stay on `macos-26`.
  - **The libraries:** the linker still warns, because commo is built for
    27.2, newer than the floor. `build-commo.sh` and `build-native.sh` set
    no deployment target, so the libraries need whatever macOS built them.
    G5's self-contained bundle has to build commo, the engine and the
    Homebrew libraries for 27.0.

## G3.2 — servers and identity (plan approved 2026-11-16)

Four PRs (plan: `~/.claude/plans/refactored-wibbling-muffin.md`):

| PR | Branch | What |
|---|---|---|
| **a** (#184) | `g3/commo-in-app` | commo in every build; the QUIC transport; the mutual-TLS and QUIC legs |
| **b** (#186) | `g3/keychain-identity` | identities in a file-based keychain, exported to commo as in-memory PKCS#12; data-package import, ported from ATAK 5.5 with `DataPackage.java`'s hardening |
| **c** (#187) | `g3/enrollment` | certificate enrollment through commo; the device profile; a fake enrollment server |
| **d** | `g3/servers-pane` | the app's servers pane: add, import, enroll, connect |

Decided with the plan (owner, 2026-11-16):

- **The app always builds with commo.** This settles G3.1's open
  question: CI's shell job builds against the commo the comms job uploads
  instead of building its own.
- **One TLS stack: OpenSSL 3.** Every connection to a TAK server goes
  through commo, or through the curl and OpenSSL 3 that commo already
  carries, reached from `CCommoShim`. The device profile's HTTPS GET
  (G3.2c), which commo's own API can't make, is a shim function, not
  `URLSession`. No `URLSession` or Network.framework for TAK traffic, now
  or later. The Keychain stores identities and passwords; it does no TLS.
- **The keychain is the file-based kind** (`SecKeychain`), not the data
  protection keychain, which needs a team-ID entitlement that the
  ad-hoc-signed development bundle can't have. Tests use a throwaway
  keychain in a temporary directory.

### G3.2a — commo in every build, TLS and QUIC (2026-11-16, branch `g3/commo-in-app`)

#### What changed

- **`app/Package.swift`**: `CCommoShim`, `MacTAKComms` and their tests are
  always targets. commo comes from `dev/g1/native-dist`, or the directory
  `MACTAK_COMMO_LIB` names; the manifest stops with the fix when commo or
  `src/`'s headers are missing, rather than failing at link time.
- **The QUIC transport**: `MACTAK_COMMO_QUIC` in the shim, commo's
  `TRANSPORT_QUIC`, with the same certificate arguments as SSL. Swift's
  `CommoTransport` is `.tcp`, `.ssl(TLSCredentials)` or
  `.quic(TLSCredentials)`; `TLSCredentials` holds the identity and the CA
  as PKCS#12 bytes and their passwords, in memory.
- **`fake-cot-server.py --client-ca CA`**: mutual TLS, as a TAK server's
  port 8089 runs. A client must present a certificate that chains to the
  CA; the server logs each accepted client's CN.
- **`fake-quic-server.py` relays** each client's events to the other
  clients, on the bidirectional stream each client opened (commo's client
  reads its own stream), framed on `</event>` like the TCP server. Its
  aioquic venv moved into `test/quic-venv.sh`, which `quic.sh` and
  `make test-app` share.
- **The tests** (`app/Tests/MacTAKCommsTests`): the round trip from
  G3.1 is now `Support/TwoClients.swift`, run over each transport.
  `Support/TestPKI.swift` makes a throwaway PKI with Homebrew's openssl@3
  (one CA, a serverAuth leaf, clientAuth leaves, and an impostor from a
  second CA). `SecureTransportTests` adds three legs:
  - two clients over mutual TLS (the server sees CN `a` and `b`)
  - an impostor from another CA refused: its handshake fails at the server,
    and its marker never reaches the connected client
  - two clients over QUIC through `fake-quic-server.py`.
  `make test-app` passes the venv's python in `MACTAK_QUIC_PYTHON`, and
  `MACTAK_REQUIRE_ALL_LEGS` turns the QUIC leg's skip (outside make) into
  a failure.
- **`make test-app`** runs every leg, and `make test-app-comms` is now
  its alias. **CI:** the shell job `needs` the comms job, checks out
  `src/` (sparse), installs commo's runtime libraries from Homebrew
  (openssl@3, libxml2, protobuf with abseil), downloads the
  `commo-stack-macos-arm64` artifact into `dev/g1/native-dist` and runs
  `make test-app`. The comms job's own Swift step is gone.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app` | 8 tests pass (2 core, 6 comms); the comms tests take 23 s; 5 runs in a row pass |
| CI's shell job | passes; its first run and one rerun hung until trap 5's fix |
| A/B: trap 5's fix reverted | the comms tests use 24.7 s of CPU in 25.7 s (one core spinning), against 3.7 s with the fix |
| A/B: the server stops verifying client certificates (`CERT_NONE`) | the impostor test fails ("server never printed tls handshake failed"), and the mutual-TLS test fails on the missing CNs |
| A/B: the shim sends QUIC as SSL | the QUIC leg fails: A's interface never comes up |
| `make test-quic` | passes (the relaying server and the shared venv) |
| `make test-tls` | passes (`fake-cot-server.py --tls` without `--client-ca` is unchanged) |
| `make lint` | passes |

#### Traps

- **4 — commo's socket writes raise SIGPIPE, and only the JVM ignored
  it.** commo writes with no `SO_NOSIGPIPE` or `MSG_NOSIGNAL`. When a
  server closes a connection commo then writes to (here, the server
  refusing the impostor's certificate), the process gets SIGPIPE, and a
  process that hasn't ignored it dies: the comms test runner exited with
  signal 13, 3 runs out of 3. G1 never saw it because the JVM ignores
  SIGPIPE. `mactak_commo_init_libraries` now ignores it for the whole
  process, so the write fails with `EPIPE` and commo reconnects. The app
  inherits the fix, since every `CommoClient` goes through it.
- **5 — a `FileHandle` readability handler spins at end of file.** The
  test helper `FakeServer` drains each fake server's output with
  `readabilityHandler`. At end of file, `availableData` is empty and the
  handler, left in place, is called again at once, forever: every server a
  test had stopped kept one dispatch queue busy-looping. On the dev Mac
  that cost a core and nothing else. On CI's 3-core runner, two spinning
  queues starved the code that notices a child exiting, and `stop()`'s
  `waitUntilExit()`, which has no timeout, waited for a python server that
  had already exited: the shell job hung for 18 minutes, then again on a
  rerun. A stack sample from a temporary watchdog step showed both: the
  test in `FakeServer.stop()` → `waitUntilExit`, and two queues in the
  handler. The handler now removes itself at end of file, and `stop()`
  waits on a `terminationHandler` for at most 10 s after SIGTERM and 5 s
  after SIGKILL. CI's test step has its own 12-minute limit.

### G3.2b — identities in the Keychain, data-package import (2026-11-17, branch `g3/keychain-identity`)

#### What changed

- **`DataPackage`** (`MacTAKComms/Import`): the server connections an
  ATAK data package carries. The plan said to port G1's
  `DataPackage.java`, but its key names turned out not to be ATAK's
  (§Found while building). So this is a port of what ATAK 5.5 does, read
  at the pin:
  - `PreferenceControl.loadSettings`: `cot_streams`' `count`, and for each
    index `connectString`, `description`, `enabled`, `useAuth`,
    `cacheCreds`, `caLocation`, `caPassword`, `certificateLocation`,
    `clientPassword`, `enrollForCertificateWithTrust` and `enrollUseTrust`.
  - `ImportCertResolver`: certificates named in `app_preferences` are the
    default for a connection that names none of its own;
    `locationCallsign` is the callsign.

  It reads every `.pref` in the package, as ATAK does, and finds each
  named certificate by basename, as ATAK copies every `.p12` into one
  directory. The hardening of `DataPackage.java` carries over:
  - suspicious entry names are refused
  - every entry is size-capped (#31)
  - two PKCS#12 files with one basename are refused (#32)
  - the connect string is parsed strictly (#32), now with `quic`
  - a DOCTYPE or entity declaration is refused
  - no description prints a password.
- **`ZipArchive`**: Foundation has no zip reader and commo carries none,
  so this is about 200 lines over the Compression framework (raw
  DEFLATE). It reads stored and deflated entries only, and refuses
  zip64, encryption and multi-disk archives. The size cap holds against
  the bytes actually inflated: an entry that claims fewer bytes than it
  holds fills a one-byte overflow and is refused. Every CRC-32 is
  checked. Nothing is written to disk.
- **`IdentityStore`** (`MacTAKComms/Identity`), over a file-based keychain
  (the login keychain, or a test's throwaway one):
  - A client identity is a real Keychain identity. `credentials` exports
    it as PKCS#12 under a random password, in memory, each time commo
    needs it. Apple exports with legacy algorithms (RC2-40, 3DES), which
    commo reads because it loads OpenSSL's legacy provider (trap 7).
  - A truststore is kept as the PKCS#12 bytes and password it came with,
    in one generic-password item. The Keychain can't export certificates
    alone as PKCS#12 (`SecItemExport` returns -50), and commo needs a
    PKCS#12.
  - Both are named by a certificate's SHA-256 (`Fingerprint`). Every
    `.p12` is parsed in memory first (`kSecImportToMemoryOnly`, macOS 15
    and later), so a wrong password reaches no keychain (trap 6), and a
    second import of the same identity is harmless.
- **`ServerConfig`**: what the app keeps per server, built from a package
  by `IdentityStore.importServers(from:)`: the address, ATAK's flags and
  the two fingerprints, no secret, `Codable`. `transport(using:)` gives
  commo `.tcp`, `.ssl` or `.quic`, with credentials exported from the
  store.
- **The tests**:
  - `ImportParsingTests`: connect strings, the zip reader (including an
    archive from the system's `zip`), a package with two servers and
    default certificates, and each refusal.
  - `IdentityStoreTests`: the gate leg, plus a wrong password, a second
    import, removal, a truststore offered as an identity, and nothing
    reaching the login keychain.
  - Test helpers: `Support/ZipWriter.swift` crafts the hostile archives,
    and `Support/TemporaryKeychain.swift` makes the throwaway keychain.
    `SecKeychainCreate` is deprecated, so it lives in the tests, not the
    library.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app` | 24 tests pass: 2 core and 22 comms (16 new) |
| The gate leg | two clients import a data package each into a throwaway keychain and see each other over mutual TLS with the exported identities; the server logs CN `a` and `b` |
| A/B: the export hands commo a wrong password | the gate leg fails |
| A/B: no overflow byte in the inflate | "an entry larger than its header says" passes the cap, and its test fails |
| A/B: no entry-name check | the hostile-package test fails |
| Login keychain after the runs | no test certificate or identity; no throwaway keychain left behind |
| `make lint` | passes |

#### Found while building

- **G1's importer reads key names ATAK 5.5 doesn't write.**
  `DataPackage.java` takes the address from `addressN` and the
  certificates from `plugin_firecrypt`'s `ClientFile`, `CAFile` and
  `Password`. Its class comment says the shape was a guess ("not yet
  verified against a real OpenTAKServer package"). ATAK 5.5 reads
  `connectStringN`, `caLocationN`, `certificateLocationN` and the two
  passwords (`PreferenceControl`, `ImportCertResolver`). The Swift
  importer follows 5.5. G1's `--datapackage` flag and its canary still
  use the old names; whether to fix them is open.

#### Traps

- **6 — `SecPKCS12Import` without a keychain imports into the login
  keychain.** On macOS, leaving out `kSecImportExportKeychain` doesn't
  parse in memory: it imports into the default keychain. A probe written
  while designing the store left a test CA in the login keychain. It was
  found with `security find-certificate` and deleted by its hash. The
  store parses every `.p12` with `kSecImportToMemoryOnly` and imports
  only with an explicit keychain, or none (the login store), on purpose.
  `testNothingReachesTheLoginKeychain` guards it.
- **7 — the app bundle has no OpenSSL legacy provider.** Apple's PKCS#12
  export, and ATAK's own `.p12` files, use RC2 and 3DES, which OpenSSL 3
  reads only with its legacy provider. commo loads it
  (`cryptoutil.cpp`: `OSSL_PROVIDER_try_load(NULL, "legacy", 1)`), from
  OpenSSL's module directory, which on this Mac is Homebrew's cellar.
  `app/bundle.sh` doesn't stage `ossl-modules/legacy.dylib`, so a
  self-contained `MacTAK.app` could read neither. **Fixed in G3.2d**: the
  bundle stages it and the app sets `OPENSSL_MODULES`.

### G3.2c — certificate enrollment and the device profile (2026-11-17, branch `g3/enrollment`)

#### What changed

- **The shim** forwards commo's `EnrollmentIO` to a new callback,
  `enrollment_update`. Only signing's success carries data: the new
  identity and the server's CAs as PKCS#12. The private key from keygen
  is never passed out on its own. `mactak_commo_enroll_init` and
  `mactak_commo_enroll_start` are separate calls, so Swift can register
  its waiter for the id before any update can arrive. `enroll_init`
  refuses to run without a CA: commo with no CA accepts any server
  (#146), and an A/B below shows it enrolling with a server from another
  CA.
- **`mactak_commo_https_get`**: the device profile's GET, through the
  curl commo carries (8.23.0 on OpenSSL 3, from `fetch-curl.sh`), called
  directly against commo's exports, with curl's headers from
  `dev/g1/build-curl/prefix/include`. Settings:
  - the CA from a PEM blob only, with `CURLOPT_CAINFO` and `CURLOPT_CAPATH`
    cleared, so no system roots come in
  - peer verification always on; host verification as asked
  - https only, no redirects, a body cap, a timeout, basic auth.

  This is the one-TLS-stack rule (§G3.2) in practice.
- **Swift**:
  - `CommoClient.enroll(host:port:user:password:ca:…)`, with a
    watchdog timeout.
  - `TakHTTPS.get`.
  - `IdentityStore.enroll(_:user:password:using:)`, which runs ATAK
    5.5's flow (`CertificateEnrollmentClient`, `DeviceProfileOperation`,
    read at the pin). It enrolls on port 8446 with the server's
    truststore, with 4096-bit keys. It keeps the new identity, and the
    CAs the server sent as the server's truststore. Then it GETs
    `/Marti/api/tls/profile/enrollment?clientUid=` on the same port with
    the same basic auth. A data package comes back as a `DataPackage`
    (now allowed to carry no server); 204 or 404 means no profile.

  Host verification follows ATAK: off when the trust is the server's own
  truststore, as servers are often reached by an address their
  certificate doesn't name.
- **`dev/g3/test/fake-enroll-server.py`**: TAK Server's enrollment port.
  It's stdlib Python plus `openssl` to sign the CSR, serving `tls/config`,
  `signClient/v2` and `profile/enrollment` behind basic auth.
- **CI**: the comms job's artifact carries curl's headers too, and the
  shell job downloads it into `dev/g1`.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app` | 28 tests pass: 2 core and 26 comms (4 new) |
| The gate leg | `alice` and `bob` enroll through two `CommoClient`s; the server signs `CN=alice, O=macTAK test, OU=fake enrollment`; the profile's callsign arrives; the two then see each other over mutual TLS with the enrolled identities (the TLS server logs CN `alice` and `bob`) |
| Refusals | a wrong password fails at the config request ("authentication failed", the server logs a 401); a server from another CA gets no request, from enrollment or the GET; a certificate without the host's name fails the GET's name check; an `http` URL is refused |
| A/B: curl stops verifying the peer | the untrusted-server test fails: the GET fetched, and a request reached the server |
| A/B: commo gets no CA | the untrusted-server test fails: commo enrolled with a server from another CA (#146) |
| `make lint` | passes |

#### Not yet

- **Quick connect**: ATAK's enrollment with no truststore, trusting the
  system's public CAs (`getQuickConnect()`). commo takes CAs only as
  PKCS#12, and the Keychain can't export certificates alone in that form
  (G3.2b). So `IdentityStore.enroll` refuses a server without a
  truststore. It needs a PKCS#12 of the public roots, built by OpenSSL
  in the shim, say.

#### Traps

- **8 — a pretty-printed signing reply crashes commo.**
  `parseSigningXML` (`enrollmentmanager.cpp`) builds a `std::string` from
  every child node's text, and a whitespace text node between
  `<signedCert>` and `<ca0>` has none: a NULL pointer, and the process
  dies with SIGSEGV. Checked by making the fake server indent its reply,
  which killed the test runner with signal 11. TAK Server sends the reply
  compact, so the fake does too. But any trusted enrollment server that
  indents its XML would crash the app. An empty element (`<ca0/>`)
  crashed it the same way.

  **Fixed (2026-11-17):** commo patch 0009 reads only element children,
  and fails the signing step ("Empty certificate returned by server")
  on an element with no text. The fake server's `--reply-shape indented`
  and `--reply-shape empty-ca` drive two tests in `EnrollmentTests`:
  - an indented reply enrolls
  - an empty CA fails at signing.

  Without the patch, both kill the test runner with signal 11. With it,
  all 44 app tests pass.
- **9 — `http.server` does a reverse DNS lookup when it binds.**
  `HTTPServer.server_bind` sets `server_name` from
  `socket.getfqdn(host)`. On CI's first run of this PR, three of four
  enrollment tests failed with "server never printed listening": the fake
  enrollment server was still running at the 15 s limit with no output,
  so it hadn't reached its "listening" line. The fourth, the first to
  run, passed. A lookup that hangs on the runner fits, and G1's
  `http-witness.py`, which binds through `socketserver.TCPServer` (no
  lookup), has never hung on CI. `fake-enroll-server.py` now binds the
  same way and keeps `http.server`'s request handling; nothing uses the
  name. The diagnosis is the likely cause, not a measured one: this Mac
  never showed the hang. CI's reruns of the shell job are the check.

### G3.2d — the servers pane (2026-11-17, branch `g3/servers-pane`)

#### What changed

- **`ServerConnections`** (`MacTAKComms/Servers`), the model under the
  pane:
  - one `CommoClient` for every enabled server, with a beacon
  - the server list persisted as JSON in a settings store (`UserDefaults`
    in the app); certificates only in the `IdentityStore` (the login
    keychain)
  - adding, removing, enabling and disabling servers
  - importing a data package, or a server's `.p12` files
  - enrolling (G3.2c), applying a package's or profile's
    `locationCallsign`
  - a status per server: off, connecting, connected, or failed with
    commo's reason (`NetInterfaceErrorCode` by name, from
    `netinterface.h`), matched by endpoint id. An interface can come up
    before `connect` returns its id, so up endpoints are remembered.

  The uid (`MACTAK-<UUID>`) and callsign persist too, as placeholders
  for G3.4's self details.
- **The app**: a Servers section heads the sidebar (`ServersView.swift`):
  - a row per server with its status and an on/off switch
  - a + menu: Add Server…, Import Data Package…
  - sheets to enroll and to import certificates; Remove in the row's menu.

  `AppDelegate` starts the connections at launch, and stops them before
  the engine at quit. The app target now depends on `MacTAKComms`.
- **OpenSSL's legacy provider in the bundle** (trap 7): `app/bundle.sh`
  stages `ossl-modules/legacy.dylib` as one more `stage-runtime.py` root,
  relinked to the bundle's `libcrypto`. `CommsRuntime.configure()` sets
  `OPENSSL_MODULES` to `Contents/Frameworks` before any `CommoClient`
  exists. commo loads the provider in every `Commo` constructor
  (`CryptoUtil::staticInit`).
- **`MacTAK --check-comms-runtime`**: starts commo as the app does,
  prints commo's own line about the legacy provider, and exits 0 when it
  loaded. `app/test/bundle-runtime.sh` (`make test-app-bundle`) runs it as
  its third leg. The leg requires `legacy.dylib` to come from the
  bundle's `Frameworks`, and its images join the "nothing from outside
  the bundle" check.
- **The commo rpath moved off `CCommoShim`**, which handed it to every
  binary linking the shim, onto `MacTAKCommsTests`: the app's binary must
  carry no absolute rpath. `dev/deps/check-bundle.py` now resolves an
  `@executable_path` rpath in an executable (the app's own directory),
  since the app links commo through one. In a library it still counts for
  nothing.
- **Tests** (`ServerConnectionsTests`):
  - a data package imported through the model connects over mutual TLS
    and shows connected
  - the list, uid and callsign persist
  - disabling disconnects (the server sees the client leave), and
    removing forgets the server
  - a refused connection shows "connection refused"
  - an SSL server with no certificates says so.

  `FakeServer.waitFor(_:within:)` is the async wait for main-actor tests
  (§Found while building).

#### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app` | 31 tests pass: 2 core and 29 comms (3 new) |
| `make app` | the bundle builds; `check-bundle.py` passes 136 Mach-O files, `legacy.dylib` among them |
| `make test-app-bundle` | all three legs pass: commo in the bundle logs "ossl legacy provider loaded successfully" with `OPENSSL_MODULES` at the bundle's `Frameworks`, and nothing loads from outside the bundle |
| A/B: `CommsRuntime.configure()` made a no-op | commo still loads the provider, from Homebrew's cellar, and the check exits 0: the leg's dyld checks are what catch it (`legacy.dylib` from `/opt/homebrew/Cellar/openssl@3/…`) |
| The app, launched from the bundle | the map draws and commo starts beside it, with no commo error. The engine's three startup errors (`IO2.cpp` code 8, `file://`, system typefaces) appear on `main`'s bundle too. The first launch's first frame took 439 ms (cold); two relaunches, 19 ms |
| `make lint` | passes |

Not run by an agent: the pane by hand (add, import, enroll and connect
through the GUI), against a real TAK server.

#### Found while building

- **A main-actor test can't wait on the main actor with a sleep.** The
  first run of the disable test failed: the server never saw the client
  leave. `ServerConnectionsTests` is `@MainActor`, and the synchronous
  `FakeServer.waitFor` sleeps the thread, so the model's disconnect task,
  queued on the same actor, never ran until the wait gave up. Two probes
  showed `CommoClient.disconnect` closing the socket at once over TCP and
  TLS. Giving the async wait its own label (`within:`) keeps Swift from
  preferring it at the synchronous call sites: overloading on `async`
  alone broke them.

## G3.3 — mesh networking (plan approved 2026-11-17)

Gap 3 (§Plan revision). Two PRs:

| PR | Branch | What |
|---|---|---|
| **a** (#191) | `g3/mesh-transport` | the shim's mesh calls; `CommoClient.startMesh`; two clients on one Mac over `lo0` with no server |
| **b** (#192) | `g3/mesh-pane` | the app's Mesh section, interface tracking, the Local Network permission |

What ATAK 5.5 does (read at the pin):

- **Defaults** (`CotService._addDefaultInputs`, `ChatManagerMapComponent`,
  `network_connections_preferences.xml`):
  - SA in and out on 239.2.3.1:6969
  - chat on 224.10.10.1:17012
  - unicast UDP and direct TCP in on 4242
  - multicast TTL 64, multicast loopback off, address reuse on
  - mesh on (`enableNonStreamingConnections`).
- **Interfaces:** one commo interface per network interface, by name
  (`CommsMapComponent.addInputsForMcastSet`).

Decided with the plan (owner, 2026-11-17): **mesh on by default**, as in
ATAK.

### G3.3a — the mesh transport (2026-11-17, branch `g3/mesh-transport`)

#### What changed

- **The shim** creates `Commo` with `MODE_NAME`, so interfaces are named
  as the system names them ("en0", "lo0"). By MAC address, the default,
  `lo0` can't be named at all: it has none. Streaming and enrollment take
  no interface address, so they don't change.
- **New shim calls:**
  - `mactak_commo_set_mesh_options` (TTL, loopback, address reuse)
  - `mactak_commo_add_inbound`, `mactak_commo_add_broadcast` (SA or chat)
    and `mactak_commo_add_tcp_inbound`
  - `mactak_commo_remove_mesh`.

  Each returns an id (`in:<if>:<port>`, `out:<if>:<group>:<port>`,
  `tcp:<port>`), and the status callbacks now carry that id for mesh
  interfaces. Before, they carried "" for anything not streaming. commo
  can report an interface before its add call returns, so the shim holds
  such statuses and replays them, in order, once the id is known.
- **Swift:**
  - `MeshConfig`, with `.atak` holding 5.5's defaults.
  - `NetworkInterfaces.meshCapable()`: the interfaces that are up,
    multicast-capable and IPv4. Not loopback, point-to-point, `utun`,
    `awdl` or `llw`.
  - `CommoClient.startMesh(_:interfaces:)`, `stopMesh()`,
    `addMeshInterface` and `removeMeshInterface`. Per interface: SA,
    chat and unicast UDP in; SA and chat out. TCP in, once.
- **Two commo patches** (`dev/g1/patches/commo/0007`, `0008`): traps 10
  and 11.
- **Tests** (`MeshTests`, on `lo0` with loopback on, off ATAK's ports so a
  real ATAK nearby neither hears nor disturbs them):
  - two clients see each other's SA on the SA group, with no server
  - a chat event goes out on the chat group and not the SA group
  - a send to one contact arrives over direct TCP
  - commo advertises `127.0.0.1:4242:tcp`
  - a client with no mesh, or on another SA port, hears nothing
  - a second `startMesh` is refused, and an interface comes and goes.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app` | 37 tests pass: 2 core and 35 comms (8 new) |
| The gate leg | two `CommoClient`s on one Mac become contacts and get each other's SA over 239.2.3.1, with no server |
| A/B: SA inbound joins no group | the presence leg fails |
| A/B: no TCP inbound | the direct leg fails |
| A/B: without patch 0007 | every UDP listen socket fails ("Unable to create listening UDP socket"); every leg that needs to hear fails |
| A/B: without patch 0008 | removing `lo0` kills the test runner with SIGSEGV (`HWIFScanner::removeHWAddress`) |
| `make test-quic` | passes on the patched commo (G1's `QuicPeerTest` uses mesh interfaces on `lo0` too) |
| `make lint` | passes |

#### Found while building

- **commo writes the contact endpoint itself.** Every SA it sends gets
  a new `<contact endpoint>` (`datagramsocketmanagement.cpp`,
  `CoTMessage::endpointForType`):
  - on the mesh, `<source address>:4242:tcp`, with the port fixed at 4242
  - to a server, `*:-1:stcp`.

  What the event said is replaced, so `Presence` needs no mesh mode,
  and the address is right for each interface on a Mac with several.
  But peers only ever send direct messages to port 4242. A second client
  on one host takes another port and gets none (`MeshConfig.tcpPort`).
- **commo receives its own SA with loopback on.** A client hears its own
  multicast, and reports itself as a contact. ATAK keeps loopback off,
  and so will the app. The contacts list (G3.4) should still drop its
  own uid.
- **Multicast on `en0` from this Mac timed out** in a Python probe, while
  `lo0` worked. It was Local Network privacy: once the owner granted
  access, the probe worked (§G3.3b).

#### Traps

- **10 — commo's address reuse fails every bind on macOS.**
  `PlatformNet::socketSetAddrReuse` has branches for Windows and Linux.
  Anything else returns an error before `setsockopt`. With reuse on, as
  ATAK sets it, every UDP listen socket fails. Patch 0007 sets
  `SO_REUSEPORT` and `SO_REUSEADDR` on Apple. The BSD stacks need both
  for two sockets to bind one wildcard UDP port and each get the
  multicast, which is what `SO_REUSEADDR` alone does on Linux.
- **11 — removing the last interface on a network interface reads freed
  memory.** `removeBroadcastInterface` and `removeInboundInterface`
  (`datagramsocketmanagement.cpp`) delete the context, which is the
  interface, then pass `iface->addr` to `HWIFScanner::removeHWAddress`.
  Usually the freed memory still holds the pointer, so nothing shows.
  Here it crashed the second time the test removed `lo0`. Patch 0008
  passes the interface map's own copy of the address, which is freed
  only after.

### G3.3b — the Mesh section (2026-11-17, branch `g3/mesh-pane`)

#### What changed

- **`MeshNetwork`** (`MacTAKComms/Mesh`), the model under the section:
  - It runs the mesh on the app's one `CommoClient`. `ServerConnections`
    takes it as an optional dependency, hands it the client when commo
    starts, and forwards commo's events to it.
  - It is **on by default**, as in ATAK. Being on and the `MeshConfig`
    persist in the settings store.
  - It shows a status per interface (starting, up, down, or failed with
    the reason) and for direct TCP.
  - Changes queue one after another, so a refresh never interleaves with
    a restart.
- **`InterfaceWatcher`**: a `SCDynamicStore` watch on every interface's
  IPv4 state. Each change calls `MeshNetwork.refresh()`, which opens the
  mesh on interfaces that appeared (`NetworkInterfaces.meshCapable()`) and
  closes it on ones that went. SystemConfiguration only watches; no TAK
  traffic goes through it.
- **Direct TCP when the port is taken.** commo's `addTcpInboundInterface`
  doesn't fail when another process holds the port: it returns the
  interface and retries the bind, so `tcp:<port>` never comes up. The
  section shows direct messages as "waiting for the port" until it does.
- **The app:**
  - a Mesh section under Servers: an on/off switch, a row per interface,
    direct messages' port
  - a settings sheet for the SA and chat groups and ports, TCP and UDP
    ports, TTL and loopback, with ATAK's defaults a click away
  - `Info.plist` gains `NSLocalNetworkUsageDescription`
  - `--settings-suite NAME` keeps a copy's settings in another defaults
    suite, so a second copy on one Mac is a second client.
- **Tests** (`MeshNetworkTests`, plus one more `MeshTests` leg):
  - on by default, and the settings persist
  - it runs on its interfaces and follows them as they go and come back
  - turning it off closes everything, and an interface change while off
    opens nothing
  - an interface that can't open says why
  - a second client whose TCP port is taken still hears and is heard.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app` | 42 tests pass: 2 core and 40 comms (5 new) |
| `make app` | the bundle builds; `check-bundle.py` and the license gate pass |
| The gate, in the app | two copies on `en0` see each other as contacts with no server (by hand, above) |
| `make lint` | passes |

**By hand, on the dev Mac (owner present, 2026-11-17):**

- **Local Network permission:** macOS asked for it twice, once for the
  terminal running the probe and once for macTAK. The owner allowed
  both. With it granted, the `en0` multicast probe that had timed out
  got its packet back at once. So the earlier timeout was the
  permission, not the network.
- **Two copies of the app on `en0`** (`--settings-suite mactak-mesh-1`
  and `-2`, loopback on in both, the second on TCP 4252): each copy's
  Mesh section showed `en0` up. Within a second of the second copy
  starting, each logged the other as a contact (`contact added:
  MACTAK-MESH-TEST-1` / `-2`, below). Copy 1 sent from `en0`'s address
  and listened on UDP 6969, 17012 and 4242 and TCP 4242.
- No ATAK device was on the LAN, so there is no check against ATAK
  itself yet.

`ServerConnections` logs each contact added or removed to the system log
(subsystem `io.github.matteskes.macTAK`, category `comms`) until G3.4
lists contacts in the app.

## G3.4 — SA (plan approved 2026-11-17)

Gaps 4 and 5 (§Plan revision) and decision 2's golden leg. Three PRs:

| PR | Branch | What |
|---|---|---|
| **a** (#196) | `g3/cot-model` | the CoT model in Swift (`MacTAKCot`); the kernel as its test oracle |
| **b** (#197) | `g3/sa-reporting` | `ReportingRate`, the self details, the location source |
| **c** (#198) | `g3/contacts-pane` | contacts and the My Details sheet |

What ATAK 5.5 does (read at the pin):

- **The self-SA** (`CotMapComponent.getSelfEvent`):
  - `how` is `m-g` with a location provider, `h-e` when placed by hand,
    and `h-g-i-g-o` otherwise.
  - The details, in order: `takv`, `contact`, `remarks`, `uid`,
    `precisionlocation`, `__group`, `status`, `track`.
  - `__group` comes from the kernel's `GroupDetailHandler`: `name`,
    `role`, and 5.5's `exrole`, `abbr` and `typeicon`.
- **`ReportingRate`**: two streams, reliable to servers and unreliable to
  the mesh, on a 1 s tick.
  - Dynamic (the default): 30 s and 180 s when stationary, and between
    20 s and 2 s when moving, linear between 1 and 30 mph.
  - Constant: 3 s and 15 s.
  - A report goes out at once on an altitude change over 50 m, a speed
    change over 7 mph, or a change to the callsign, team, role or
    remarks.
  - The stale time is the rate times 4 or 2, plus 15 s.

Decided with the plan (owner, 2026-11-17): **the device uid comes from
the hardware**, `MACTAK-<IOPlatformUUID>`, as ATAK's comes from the
device's serial or MAC address. It is kept apart from every settings
suite, so no import or settings copy carries it (G3.4b).

### G3.4a — the CoT model (2026-11-17, branch `g3/cot-model`)

#### What changed

- **`MacTAKCot`**, a new pure-Swift target with no commo, so its tests
  run in milliseconds:
  - `CotEvent`, `CotPoint` and `CotDetail` (an ordered tree), ported
    from the kernel's `com.atakmap.coremap.cot.event` classes.
  - **`CotEvent.parse`** follows the kernel's `CotContentHandler`:
    - uid and type are required, and so are a point's lat and lon.
    - hae, ce and le that are missing or NaN are 9999999.
    - A time that can't be read is now.
    - Only the first `<detail>` counts. Everything under it is kept,
      unknown elements included.
    - A leaf keeps its trimmed text.

    Unlike the kernel, a DOCTYPE refuses the whole event, as G1's parser
    did.
  - **`CotEvent.xml()`** writes the kernel's layout: the XML
    declaration, `'` quotes, `access='Undefined'`, and the point rounded
    to 7, 3 and 1 decimals. It escapes every value; the kernel leaves
    type and how alone.
  - **Typed views** of the SA details: `GroupDetail` (with
    `ensureValidGroup`: an unknown team reads as Pink), `PrecisionLocation`,
    `TakVersion` and `Track`.
  - **`SelfEvent`** ports `getSelfEvent` and replaces G3.1's `Presence`.
    `CommoClient` beacons it (still every 5 s with a 30 s stale, until
    G3.4b). `setPosition` became `setLocation(_:)`, which takes the
    source.

  `MacTAKComms` re-exports `MacTAKCot`.
- **The golden test** (decision 2). The fixtures are in
  `dev/g3/test/cot-golden`:
  - `parse/*.xml`: peer events. They cover ATAK 5.5's SA with extended
    roles, escaping, and unknown details including a second `<detail>`.
  - `self/*.properties`: self specs, one with no location, one from a
    provider and one placed by hand with an extended role.
  - `expected/*.xml`: what each one must write.

  Two legs check the same files:
  - **The Swift leg** (`MacTAKCotTests.GoldenTests`, in `make test-app`)
    holds the port to them.
  - **The kernel's leg** (`dev/g3/test/CotOracle.java`, `make
    test-cot-golden`) holds the kernel's own `CotEvent` to them. It runs
    as a source set added to takkernel's `:shared` by an init script
    (`cot-oracle.gradle`), on `:shared`'s test classpath. CI runs it as
    its own step in the `jvm-tests` job, after the kernel's unit tests.

  Both legs compare in one canonical form: attributes sorted, `<point>`
  numbers to 7 decimals, and empty text the same as none. The kernel keeps
  attributes in a `HashMap`, so byte equality was never on offer.
  `MACTAK_COT_GOLDEN_WRITE=1 swift test --filter GoldenTests` rewrites
  the expected files from the port. The kernel's leg must then pass on
  them unchanged.
  - **The self specs:** precisionlocation and `how` come from app code
    (`PrecisionLocationHandler`, `getSelfEvent`), which isn't in the
    kernel. For those, the oracle restates ATAK's rules. The rest of
    each event is the kernel's own work: the event, point and detail
    classes, and `GroupDetailHandler.toCotDetail` for `__group`.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app` | 58 tests pass: 13 CoT (new), 2 core and 43 comms |
| `make test-cot-golden` | the kernel writes all 6 fixtures as expected |
| A/B | `role='Medic'` → `'Medics'` in one expected file fails both legs (the kernel's: "FAIL: 1 of 6"; Swift's: `testSelfEventsAreWhatTheKernelBuilds`) |
| `make app` | the bundle builds; `check-bundle.py` and the license gate pass |
| `make lint` | passes |

#### Traps

- **12 — android-port's XML pull parser is a stub, and the kernel's parse
  swallows it.** On `:shared`'s test classpath, the android-port
  substitute comes before kxml2. Its
  `org.xmlpull.v1.XmlPullParserFactory.newInstance` throws "Stub!".
  `CotContentHandler.parseXML` catches every `Throwable`, logs it and
  returns an empty event, so `CotEvent.parse` "succeeds". The first sign
  was an NPE in `toString` (no time). `cot-oracle.gradle` puts kxml2
  first and fails if it isn't on the classpath. This is G55 trap 6's
  shape (android-port shadowing real classes) in a new package.

### G3.4b — ReportingRate, the self details, the location (2026-11-17, branch `g3/sa-reporting`)

#### What changed

- **`ReportingRate`** (`MacTAKComms/SA`) ports ATAK 5.5's class. It is a
  value with a `tick(now:altitude:speed:)` that returns the reports due,
  so tests drive it without a clock. Upstream's constants and quirks are
  kept:
  - Dynamic pads both streams' stale with the reliable multiplier (2).
  - An ASAP before any report records stale 0, so the next tick reports
    again.
  - The stale buffer only matters when the rate grows past the last
    stale.
- **Two streams.** `mactak_commo_broadcast` takes a send method (commo's
  `CoTSendMethod`), and `CommoClient.broadcast(_:via:)` a `SendRoute`. As
  ATAK's `CotDispatcher` does, reliable goes to `.server`
  (`SEND_TAK_SERVER`) and unreliable to `.mesh` (`SEND_POINT_TO_POINT`).
- **`CommoClient.startReporting(_:)`** replaces G3.1's fixed beacon:
  - A 1 s tick asks `ReportingRate`.
  - An interface coming up asks for a report at once.
  - `updateSelf` reports at once when the identity changes: callsign,
    unit type, `__group` or remarks. These are ATAK's monitored
    preferences.

  Tests that need a fast beacon use `.every(seconds: 1)` (Constant).
- **`SelfDetails`** persists under ATAK's own preference keys, as
  strings:
  - `locationCallsign`, `locationTeam` (`ensureValidGroup` on load),
    `atakRoleType`, `customRole`, `customRoleAbbreviation`,
    `customRoleUseTypeIcon`, `locationUnitType`, `userRemarks`
  - the strategy and the eight rate keys. A negative or non-numeric rate
    falls back to the default, as in ATAK.

  G3.2d's `mactak.callsign` carries over once. A data package or profile
  `locationCallsign` lands here.
- **`DeviceUID`** (owner's choice): `MACTAK-<IOPlatformUUID>`.
  - It is kept in `~/Library/Application Support/macTAK/device-uid`,
    outside every settings suite. A random UUID is the fallback if IOKit
    won't say.
  - `--settings-suite NAME` appends `-NAME`, and the suffix isn't kept.
  - G3.2d's random `mactak.uid` setting is dropped, so each install's uid
    changes once.
- **The location.**
  - `LocationMode` picks the source:
    - device: CoreLocation only
    - manual: the placed position only
    - both (the default): CoreLocation while it has a fix, else the
      placed position.

    A still Mac may get one fix and no more, so a fix counts until
    CoreLocation fails or is denied, not until it ages. This narrows the
    plan's "while it is fresh".
  - A fix's HAE comes from `ellipsoidalAltitude`: CoT altitude is HAE,
    and `CLLocation.altitude` is MSL. Invalid accuracies are unknown.
  - `how` and `precisionlocation` follow the source (G3.4a's
    `SelfEvent`).
  - `Info.plist` gains `NSLocationUsageDescription` and
    `NSLocationWhenInUseUsageDescription`.
- **`SelfReporter`** joins the details, the location and the battery
  (IOPowerSources, 100 on a Mac with none, once a minute). It pushes them
  to the client in order: each update waits for the previous one.
  `ServerConnections` takes it (`me:`) and gets its uid and callsign from
  it. The app builds it with a `LocationService`; the UI to edit it is
  G3.4c.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app` | 82 tests pass: 13 CoT, 2 core and 67 comms (24 new: `ReportingRateTests` 10, `SelfDetailsTests` 12, `SelfReportingTests` 2) |
| `make test-cot-golden` | the kernel writes all 7 fixtures as expected (a placed position with altitude added) |
| A/B, the routes | every route sent as `SEND_ANY`: the routing test fails ("B gets the server broadcast happened") |
| A/B, at once | no ASAP on an identity change: the team change misses its 5 s (Dynamic's next mesh report is 30 s away) |
| `make test-app-bundle` | passes |
| `make lint` | passes |

The app's CoreLocation prompt and a placed position seen by a peer are
checked by hand with the owner in G3.4c, with the sheet that sets them.

### G3.4c — contacts and My Details (2026-11-17, branch `g3/contacts-pane`)

#### What changed

- **`ContactStore`** (`MacTAKComms/Contacts`) keeps everyone the client
  hears, on a server or the mesh.
  - A contact is an atom (`a-…`) event with a `<contact endpoint>`, as
    ATAK's `ContactListDetailHandler` takes it. A dropped marker has a
    callsign but no endpoint, so it isn't one. The client's own uid is
    dropped.
  - Each `Contact` keeps its team, role and custom role, point, `how`,
    `precisionlocation`, takv, track and battery. It also keeps how it
    was heard (`.mesh` or `.server(id)`, matched by commo's endpoint id).
  - Stale and removal follow ATAK 5.5 (`MarkerImporter`,
    `CotMarkerRefresher`), timed by this Mac's clock from when the SA
    arrived:
    - a contact goes stale 1.5 × (stale − start) after its last SA
      (`autoStaleDuration`), and is listed greyed
    - it is removed 5 minutes after it went stale
      (`expireStaleItemsTime`), or when commo reports the contact gone.
  - `ServerConnections` feeds it commo's CoT and expires it every 5 s.
    This replaces G3.3b's `os_log` of contacts.
- **The Contacts section** of the sidebar:
  - "me" first: callsign, role, where the self-SA says this Mac is, and
    the My Details button
  - then a row per contact: team colour, callsign, role, how long ago,
    greyed when stale
  - a popover per contact: team, role and custom role, position, source,
    track, battery, how it was heard, the client and the uid.
- **My Details** (`MyDetailsView.swift`) edits a draft and applies it on
  Save:
  - callsign, team (ATAK's 14 teams), role (the kernel's `RolesManager`
    defaults), custom role and abbreviation, the type-icon flag, unit
    type, remarks
  - the location source and a placed position
  - the reporting strategy and its rates.

  The unit type is a CoT type text field. ATAK picks it from the whole
  2525 type tree (`CoTSelector`), which comes with G3.7's symbols, so a
  short list would have been invented.
- **`TypedPosition.parse`** reads a position as people type it:
  - `lat, lon`, `lat lon` or `lat, lon, hae`
  - N/S/E/W and degree signs
  - any dash or minus character (trap 13).

  If the field can't be read, the sheet quotes it, with the codes of any
  non-ASCII characters. MGRS and the other formats are G3.6's.
- Positions show as decimal degrees until G3.6.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app` | 90 tests pass: 13 CoT, 2 core and 75 comms (8 new: `ContactStoreTests` 6, `TypedPositionTests` 2) |
| `ContactStoreTests.testTwoClientsOnAServerListEachOther` | two `ServerConnections` on `fake-cot-server.py` list each other with team and role, heard via the server |
| `make app` | the bundle builds; `check-bundle.py` and the license gate pass |
| `make lint` | passes |

**By hand, on the dev Mac (owner present, 2026-11-17).** Two copies ran
from `build/MacTAK.app` (`--settings-suite mactak-mesh-1` and `-2`,
loopback on, the second on TCP 4252), with copy 2 set to Red and Medic:

- **The contacts list:** copy 1 listed MAC-COPY-2 with a red dot and
  "Medic", heard seconds before.
- **CoreLocation:** macOS asked for location permission.
- **A detail change at once:** copy 2's team set to Green in My Details
  turned its dot green in copy 1 right away. Dynamic's next mesh report
  was 30 s off.
- **A placed position:** after trap 13's fix, copy 1's
  `51.5007, -0.1246` saved, and copy 2's popover for MAC-COPY-1 showed
  it.

The device uid file holds `MACTAK-<IOPlatformUUID>`.

#### Traps

- **13 — a minus typed into the sheet may not reach it as `-`.** Placing
  a position failed twice by hand while the parser's tests passed on the
  same text:
  - first with separate latitude and longitude fields, which couldn't
    take the pair the owner was asked to type
  - then with one field that read "lat, lon", but only ASCII
    hyphen-minus.

  The next build read every dash and minus character (U+2010–2015,
  U+2212, U+FE63, U+FF0D) and a no-break space, and it worked. Nothing
  else about the parsing changed between the second and third tries, so
  a substituted character is the likely cause. The owner's account has
  macOS's smart dashes at their default, on. The character itself was
  never seen: the warning that would have shown it shipped with the
  fix. Text that people type in this app should be read with that
  substitution in mind.

## G3.5 — GeoChat (plan approved 2026-11-17)

Gap 6 (§Plan revision). Three PRs, then a docs PR:

| PR | Branch | What |
|---|---|---|
| **a** (#200) | `g3/chat-model` | the chat and receipt events in `MacTAKCot`; chat fixtures in the golden test |
| **b** (#201) | `g3/chat-service` | rooms, sending, receiving, receipts; history and user groups in SQLite |
| **c** (#202) | `g3/chat-pane` | the sidebar's Chat section and the Chat window |

What ATAK 5.5 does (read at the pin, `atak/.../android/chat`):

- **A message** is a `b-t-f` event (`GeoChatService.bundleToCot` and
  `addSendDetails`):
  - uid `GeoChat.<sender>.<room>.<messageId>`, how `h-g-i-g-o`, stale a
    day later, at the self position (0,0 when hidden)
  - `__chat` with the room (`id`, `chatroom`), `messageId`,
    `senderCallsign`, `parent` and `groupOwner`; a `chatgrp` child lists
    the sender (`uid0`) and the destinations; a user group adds its
    members as a `hierarchy`
  - a `p-p` link to the sender, `__serverdestination`, and `remarks`
    with the text (`to` only in a one-to-one).
- **Rooms.** All Chat Rooms is a broadcast (its old name, All Streaming,
  is still read). One-to-one, team, role and user-made rooms go point to
  point to each member. A team room has a member for each contact in the
  team and the parent `TeamGroups`. A role room has one for each contact
  with the role (no Team Member room). Only your own team's and role's
  rooms take messages (`setUnmodifiable`).
- **Receipts** are `b-t-f-d` (delivered) and `b-t-f-r` (read), with
  `__chatreceipt` in place of `__chat`, the message id as the event uid,
  and sender and receiver swapped. 5.5 sends them **only in one-to-one
  chats**: delivered on arrival, read when the line is shown. A status
  only replaces a lower one, in `ChatLine.Status`'s order. `b-t-f-p`
  (pending) is in that enum but 5.5 never sends it.

Decided with the plan (owner, 2026-11-17):

1. History and user groups persist in **SQLite**, as `ChatDatabase`
   does: system `libsqlite3`, in Application Support, one file per
   settings suite.
2. Conversations show in a **Chat window** laid out like Messages; the
   sidebar gets a Chat section with unread counts.
3. Receipts **match 5.5 exactly**: delivered and read in one-to-one
   chats only; pending is read and shown, never sent.

Left out: TADIL-J, plugin connectors, attachments, canned replies, and
the access, caveat and releasability preferences (`Undefined`).

### G3.5a — the chat events (2026-11-17, branch `g3/chat-model`)

#### What changed

- **Sending** (`ChatEvent.swift`):
  - `OutgoingChat` builds a message event and `ChatReceipt` a delivered
    or read receipt, both through one port of `addSendDetails`. What 5.5
    reads from the map, the contacts and the preferences comes in as
    values: `ChatSender` is this client (uid, callsign, type, position,
    address), and the service (G3.5b) supplies the room's members,
    parent and hierarchy.
  - `ChatStatus` keeps `ChatLine.Status`'s order, and `takes(_:)` is its
    forward-only rule.
  - `ChatHierarchy` is a user group's member tree (`Contacts.buildPaths`,
    `ChatMessageParser.getPaths`).
- **Receiving** (`ReceivedChat.swift`) ports `ChatMessageParser` as far
  as the event alone goes:
  - CHAT3 (with a `chatgrp`) and the older GeoChat. In GeoChat the room
    and the sender are named by callsign, which the contacts resolve in
    G3.5b.
  - The sender's uid comes from WinTAK's `sourceID`, else from `remarks`
    `source`, else from the event uid. The room falls back to the event
    uid, and the destinations fall back to `__serverdestination`.
  - A receipt's message is the event's uid.
  - `isLegacyGroupCandidate` is 5.5's legacy-group test, short of the
    contact lookup.
- **Golden fixtures**: 11 ATAK-shaped chat events in
  `dev/g3/test/cot-golden/parse`, written by hand from `addSendDetails`.
  There is one for each room kind, plus a user group with its hierarchy,
  escaped text, delivered and read receipts, a pending receipt from a
  peer, an ATAK one-to-one and an old GeoChat event. The kernel's leg
  round-trips them like the SA fixtures. `ChatTests` holds the builders
  to them, so what this client sends is ATAK's form, not just
  self-consistent.

#### Found while building

- **`pending` outranks `read`.** `ChatLine.Status` is `NONE, DELIVERED,
  READ, PENDING`, and `GeoChatService.onCotEvent` drops a receipt whose
  ordinal isn't higher. A pending receipt after a read one is therefore
  taken. That's an upstream quirk, kept (decision 3), and pinned in
  `testStatusOnlyMovesUpIn55sOrderPendingLast`.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `swift test --filter MacTAKCotTests` | 31 tests pass: 18 chat (new), 11 model and 2 golden |
| `make test-cot-golden` | the kernel writes all 18 fixtures as expected (11 new) |
| A/B | numbering `chatgrp` from `uid1` fails 8 of the 18 chat tests |
| `swift build` | every product builds |

### G3.5b — rooms, sending, receipts, history (2026-11-17, branch `g3/chat-service`)

#### What changed

- **`ChatStore`** (`MacTAKComms/Chat`) keeps the history and user groups
  in SQLite through the system's `libsqlite3`. It uses `ChatDatabase`'s
  table and column names where they carry over, and adds `outgoing` and
  `seen`. The app opens `Application Support/macTAK/chat.sqlite`, or
  `chat-<suite>.sqlite` for a `--settings-suite` copy. Deleting a group
  deletes its history, as `ChatDatabase.removeGroup` does.
- **`ChatService`** ports `GeoChatService` and the sending half of
  `ChatManagerMapComponent`:
  - **Rooms** (`ChatConversation`) come from the contacts:
    - All Chat Rooms
    - a room for each of the 14 teams
    - a room for each role but Team Member, hidden while empty
    - the user groups
    - a one-to-one for each contact, and for each past conversation with
      a contact that has gone.

    Only your own team's and role's rooms take messages.
  - **Sending:** All Chat Rooms is broadcast (`SendRoute.any`). Any other
    room is sent to each member's uid through commo, and a user group
    carries its hierarchy. The line is kept even when no member is there.
  - **Receiving** does the contact lookups G3.5a left out:
    - an old GeoChat event is resolved by callsign
    - a room equal to this client's uid is a one-to-one, filed under the
      sender
    - a hierarchy updates the user groups. A group made here never
      changes; the owner replaces a group's members, anyone else adds to
      them
    - a legacy group is made from the `chatgrp`
    - `deleteChild` removes the group.
  - **Receipts:** a one-to-one from a known contact is answered with
    delivered, and with read when `markSeen` shows it. Read is sent once.
    An incoming receipt moves the status up only.
  - Sends go out in order on one task. A failure is shown in
    `lastError`, not thrown.
- **`ServerConnections`** takes an optional `ChatStore`. With one, every
  CoT event also goes to its `ChatService`, which sends through the same
  `CommoClient`. A change to the self details refreshes the rooms.
  `SelfReporter.chatIdentity` names the sender: the uid, callsign, unit
  type and self position, plus this Mac's address
  (`NetworkInterfaces.primaryIPv4`).

#### Unlike 5.5 (decided while building)

- **A sender with no SA gets no receipt.** 5.5 makes a contact from the
  packet's source address. commo doesn't pass that address on, and
  `CommoClient.send` reaches only contacts commo knows.
- **A message heard twice is kept once**, for example over a server and
  the mesh.
- **TADIL-J messages are dropped** (out of scope).
- **A group-delete notice isn't kept as a line.** Its "Deleted group: …"
  would otherwise open a stray Groups room.
- **An old GeoChat room named by this client's callsign is a one-to-one.**
  5.5 looks the callsign up in its contacts, which this client isn't in.
  It would then file the message under a room named by the callsign.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

| Gate | Result |
|---|---|
| `make test-app` | passes; `MacTAKCommsTests` 99 tests, 24 new: 16 `ChatServiceTests`, 5 `ChatStoreTests`, 3 `ChatCommsTests` |
| the G3.5 gate legs (`ChatCommsTests`) | over `fake-cot-server.py`: All Chat Rooms, a team, a role and a user group each reach their members, with no receipts; a one-to-one comes back delivered, then read. On the mesh (lo0): All Chat Rooms on the chat group, and a one-to-one over direct TCP |
| A/B | sending a delivered receipt in every room fails 6 assertions in `ChatServiceTests` and 12 in the server's room leg |
| `make app` | the bundle builds; `check-bundle.py` and the license gate pass |

### G3.5c — the Chat window (2026-11-17, branch `g3/chat-pane`)

#### What changed

- **The sidebar's Chat section** (`ChatView.swift`) lists All Chat Rooms
  and the rooms with messages, newest first, with unread counts. A row,
  or "Open Chat…", opens the Chat window on that room.
- **The Chat window** is a second `Window` scene (`id: "chat"`), laid out
  like Messages (decision 2):
  - Rooms, grouped as All Chat Rooms, Teams, Roles, Groups and Direct.
    The Groups header's + opens a New Group sheet (a name and contacts),
    and a group's context menu deletes it.
  - The conversation: bubbles with the sender in rooms and the time
    under each. This client's own one-to-one lines show "sent",
    "delivered", "read" or "pending".
  - The composer. Return sends, and so does ⌘Return. In another team's
    or role's room it gives way to a note saying who can write there.
- **Read receipts follow what is seen.** A room's lines are marked seen
  only while the Chat window is key and that room is open. In a
  one-to-one, that is when the read receipt goes out.
- `ChatSelection` holds the open room. The app shares it between the
  sidebar and the window.

#### Checked by hand (owner present, 2026-11-17)

On one Mac, only the copy holding TCP 4242 takes direct mesh sends, and
every peer sends a one-to-one there (MeshTests). So the check ran through
`fake-cot-server.py` on 127.0.0.1:8087 with the mesh off. Two copies ran
from `build/MacTAK.app` (`--settings-suite mactak-chat-1` and `-2`). Copy
2 was set to Red and Medic. Each leg was confirmed in the server's log
and in both copies' `chat-*.sqlite`:

1. **All Chat Rooms**, both ways.
2. **One-to-one**, both ways: delivered, then read once the other
   copy's Chat window showed it.
3. **Team rooms:** copy 1's Cyan room was writable. Its Red room showed
   "Only the Red team can write here" (the owner's report).
4. **The Medic room**, with both copies medics: a message from copy 2
   reached copy 1.
5. **User groups:**
   - A group made on copy 2 reached copy 1.
   - Copy 1, a member, deleting it removed only copy 1's own copy, as in
     5.5: `ContactPresenceDropdown.deleteGroups` notifies only when
     `isUserCreated()`.
   - Copy 2, the owner, deleting it sent `deleteChild`, and it left both
     copies.
   - A group made on copy 1 reached copy 2, and copy 1's delete removed
     it from both.
6. **History:** both copies quit and relaunched with their All Chat Rooms
   and one-to-one lines.

## G3.6 — coordinates (plan approved 2026-11-17)

Gap 7 (§Plan revision). Two PRs, then a docs PR:

| PR | Branch | What |
|---|---|---|
| **a** (#206) | `g3/coord-model` | MGRS, UTM, DD, DM and DMS, the geoid and altitude in `MacTAKCot`; the coordinate golden test |
| **b** (#207) | `g3/coord-pane` | the Units settings, positions in every format in the app, typed positions in any format, the self readout over the map |

What ATAK 5.5 does (read at the pin):

- **`CoordinateFormat`** (app): MGRS (0, the default), DD, DM, DMS, ADDR
  and UTM, under the `coord_display_pref` key. An unknown name reads as
  MGRS.
- **`CoordinateFormatUtilities`** (app) writes and reads each format. It
  puts N/S and E/W in place of signs and a left-to-right mark (U+200E)
  before each space, and rounds HALF_UP with `DecimalFormat`. Its parsing
  is the reverse; it returns null for some bad input and throws for the
  rest. It uses only kernel classes.
- **`MGRSPoint`** and **`UTMPoint`** (kernel, pure Java) cover WGS84
  between 80°S and 84°N, with no UPS. Norway's 32V and Svalbard's
  31X–37X zones are special-cased.
- **Altitude** (`UnitPreferences`): `alt_display_pref` is MSL (the
  default) or HAE, and `alt_unit_pref` is feet (the default) or metres.
  The strings come from `EGM96.formatMSL` and `formatHAE`, through
  `SpanUtilities.format`.
- **The geoid.** `EGM96.getOffset` calls
  `ElevationManager_getGeoidHeight`. 5.5 configures no `egm96-file`, so it
  always falls through to the WMM grid compiled into the engine
  (`formats/wmm/EGM9615.h`: 721 × 1441 floats at 15′), interpolated
  bilinearly by `MAG_GetGeoidHeight`. The WMM code is public domain.
- **The self readout** (`SelfCoordOverlayUpdater`) shows the location
  source, the callsign, the position in the chosen format, the altitude,
  heading, speed and accuracy. A tap does what `self_coord_action` says:
  pan to self (the default) or cycle the format DD → DM → DMS → UTM →
  MGRS.

Decided with the plan (owner, 2026-11-17):

1. **The geoid grid is committed**, as `app/Resources/egm96-15.grid`: 4.2
   MB of float32s, written from the engine's own `EGM9615.h`. CI checks
   that it still matches the pin. App builds then need no ATAK source.
2. **The self readout goes over the map in G3.6**, not with G3.7's self
   marker.

Left out: ADDR, which needs a geocoder; AGL (`alt_display_agl`, off by
default), which needs elevation data; and the north reference for the
readout's heading (true only until there is a magnetic model).

### G3.6a — coordinates in `MacTAKCot` (2026-11-17, branch `g3/coord-model`)

#### What changed

- **`MacTAKCot/Coordinates`**, ported from 5.5 at the pin:
  - `UTMPoint` and `MGRSPoint`, from the kernel's classes. The USGS
    series are copied term by term, because floating point isn't
    associative and the strings floor to the metre.
  - `CoordinateFormat`, and `Coordinates.format` and `Coordinates.parse`
    from `CoordinateFormatUtilities`: the long and short strings, and
    convert for each format, with 5.5's error messages.
  - `Geoid`: `MAG_GetGeoidHeight` line for line, over the committed grid.
  - `Altitude`: MSL or HAE, in feet or metres, with 5.5's strings.
  - `JavaNumber`: the Java rules the strings depend on.
    - `DecimalFormat` rounds the double's exact value HALF_UP, so 1.005
      is 1.00. A negative value that rounds to zero keeps its sign
      ("-0.00").
    - `Math.round` takes halves up, so −2.5 is −2, where Swift's
      `.toNearestOrAwayFromZero` gives −3.
    - `Double.parseDouble` takes "2d" and "Infinity", but not "inf".
    - The `(int)` cast never traps.
- **The coordinate golden test**, `dev/g3/test/coord-golden`. Fixtures:
  - points: 5.5's own test points, every quadrant, Norway and Svalbard,
    the band edges and beyond, the poles, the antimeridian, ±0, and
    rounding edges
  - typed text: each format, good and bad
  - altitudes
  - extra geoid points: the grid's edges, NaN, off the earth.

  Two oracles write the expected files, both at the pin
  (`make test-coord-golden`, CI's `jvm-tests` job):
  - `CoordOracle.java` compiles **5.5's own** `CoordinateFormat` and
    `CoordinateFormatUtilities` (the app's, from `src/`) against the
    kernel jars. The job's sparse checkout gains that one app folder.
    Locally, the script reads the files from `src/`'s git objects.
  - `geoid-oracle.cpp` is built from the engine's `formats/wmm`
    unchanged. It writes the grid, which must equal the committed file,
    and the heights at the fixture points.

  `CoordinateTests` (`make test-app`) holds the Swift port to every
  expected file. Strings must match exactly; positions and heights must
  agree to 1e-9 (relative above 1).

#### What 5.5 does that the port keeps

- The poles have no UPS: 90°N writes `31X EV 00000 97964`. Reading UTM
  back at 90°S gives a latitude near −8 × 10³³.
- Minutes and seconds round up to 60, so 72.4999595°N writes DMS short
  as `29' 60"`.
- Typed DD, DM and DMS read only 5.5's own spacing.
  `N 38.89770° W 77.03650°`, typed with plain spaces, is null. Only the
  form with left-to-right marks, or plain signed numbers, reads.
- A bad band or square letter in MGRS reads as a position, not an
  error: `18IUJ12345678` reads as 86°S.
- An unknown or out-of-range altitude shows "-- ft MSL", even with
  metres set.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

- `make test-coord-golden`: 4 expected files from 5.5's formatter, plus
  the grid and 50 geoid heights from the engine's code, all PASS.
- `swift test --filter MacTAKCotTests`: 40 tests, including
  `CoordinateTests`' 9, all PASS on the first run. Every string matched
  5.5's, the pole and rounding quirks included.
- A/B: making the port round only digits above 5 (not HALF_UP) failed
  18 of 5.5's strings. Restored, they pass.

### G3.6b — coordinates in the app (2026-11-17, branch `g3/coord-pane`)

Decided while building (owner, 2026-11-17): **typed positions read
exactly as 5.5 reads them** (`Coordinates.parse`). Only text in 5.5's
own spacing, or plain signed numbers, reads; making entry more forgiving
can come later. The only thing undone first is macOS's own text
substitution: a smart dash or typographic minus is a minus (trap 13).

#### What changed

- **`UnitPreferences`** (MacTAKComms) keeps the choices under 5.5's keys:
  `coord_display_pref`, `alt_display_pref`, `alt_unit_pref`,
  `speed_unit_pref` and `self_coord_action`. The defaults are 5.5's:
  MGRS, MSL, feet, MPH, pan to self. A value ATAK would have written (a
  data package's or device profile's) reads back. The geoid comes from
  the bundle (`app/bundle.sh` stages `egm96-15.grid`). Without it, MSL
  shows unknown rather than passing HAE off as MSL.
- **The Settings window** (⌘,) has a Units pane: coordinate format (with
  an example), altitude reference and units, speed units, and what a
  click on the self readout does. ADDR isn't offered.
- **Contacts:** the Me row, a contact's position, and a new Altitude row
  follow the settings.
- **My Details:** a placed position is typed in a chosen format (the
  display format by default), and its altitude in the chosen reference
  and units. A field left as shown keeps the placed point as it was,
  since MGRS and UTM floor to the metre. A change of format rewrites
  what's typed. 5.5's own error messages show.
- **The self readout** sits in the map's lower right, as 5.5's
  `SelfCoordOverlayUpdater` lays it out:
  - the source, green for CoreLocation, or "NO GPS" in red for a placed
    position
  - the callsign (cut at 40 characters)
  - the position (MGRS as `getFormattedString`)
  - altitude and heading (AngleUtilities' bearing, then T)
  - speed and accuracy.

  With no location at all, only NO GPS shows. A click pans to self (the
  default) or cycles the format DD → DM → DMS → UTM → MGRS.
- **`EngineBridge.panTo(lat, lon)`** (Java and Swift) queues
  `CameraController.Programmatic.panTo` (animated) on the render thread.
  It is the map's first programmatic camera call.
- `SelfReporter` publishes the self track, for the readout.
- The oracle gains AngleUtilities' headings (`headings.tsv`).
  `Motion.heading` must match them, plus the T.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

- `make test-coord-golden` PASS, with headings added.
- `UnitPreferencesTests`: 7 tests, and `CoordinateTests`: 11 tests, all
  PASS.
- `make app` PASS: the grid is in `Contents/Resources`, and
  `check-bundle.py` and the license check pass.

#### To check by hand (owner present)

1. **Settings › Units:** every coordinate format shows its example. The
   choices survive a relaunch.
2. **The readout:**
   - It shows NO GPS with no location.
   - With CoreLocation or a placed position, it shows the position in
     each format.
   - A click pans the map to the position.
   - With "Changes the coordinate format" set, a click steps DD → DM →
     DMS → UTM → MGRS.
3. **My Details:** place yourself by MGRS (e.g. `10S EG 53376 83302`,
   the Ferry Building), with an altitude in ft MSL. The Me row and the
   readout show it, and reopening the sheet shows the same text.
4. **Contacts:** a second copy's position and altitude follow the Units
   settings.

Two things to know first:

- **Test inside San Francisco.** The bundle's only basemap is
  `sf-naip-2024.tif`. A pan to anywhere else (DC, say) works, but the
  map shows black because there's nothing to draw there.
- **Two copies on one Mac need loopback.** In each copy's Mesh
  settings, turn on "Hear this Mac's own multicast" and click **Save**:
  the sheet keeps nothing without Save. The second copy can't hold TCP
  4242 (its Direct messages waits for the port) unless it is moved, to
  4252 say. SA doesn't need it.

**By hand, on the dev Mac (owner present, 2026-11-17):**

- **Settings › Units** (1): each picker takes effect at once. The
  choices are saved under 5.5's keys (`coord_display_pref = UTM`,
  `alt_display_pref = HAE` read back from the suite). A relaunch wasn't
  run for this leg; the copies were relaunched earlier in the session.
- **The readout** (2): NO GPS with no location, the position with a
  placed one, and a click pans to it. The first try looked like a
  black-screen bug: the point was in DC, outside the imagery. With
  "Tapping my coordinates" set to "Changes the coordinate format", each
  click steps to the next format.
- **My Details** (3): the Me row and the readout show the typed MGRS
  and its altitude, and the sheet reopens with the same text. That
  holds only after a fix found here: the Me row showed the position
  without the altitude. It now adds the altitude, when known, in the
  chosen reference and units, on up to two lines.
- **Contacts** (4): two copies (default suite and `--settings-suite
  mactak-coord-2`), mesh with loopback on. Each lists the other, and
  the other's position and Altitude row follow every change in Settings
  › Units: format, MSL/HAE and ft/m.

## G3.7 — markers with 2525 symbols (plan approved 2026-11-18)

Gap 8 (§Plan revision). Three PRs, then a docs PR:

| PR | Branch | What |
|---|---|---|
| **a** (#209) | `g3/milsym` | missioncommand's 2525 renderers in the app's JVM; `EngineBridge.symbolPng` / `canRenderSymbol`; the CoT type → 2525C mapping in Swift, golden-tested against the kernel |
| **b** (#210) | `g3/map-markers` | the engine's marker layer; contacts drawn as 5.5 draws them, and the self marker; a render test in CI |
| **c** (#214) | `g3/cot-markers` | received non-contact CoT as markers: `icon_filters.xml`, then 2525, then unknown-type; hand check |

Not in G3.7: placing markers by hand, the CoT type picker
(`CoTSelector`), marker details and the radial menu, tactical graphics,
user icon sets.

### Spike #171: a public 2525 renderer (2026-11-18)

- **It exists, on Maven Central, under Apache-2.0.** ATAK 5.5's 2525
  providers run on missioncommand's renderers, and their desktop builds
  are public: `mil-sym-renderer` 0.1.41 with five sibling jars
  (`ArmyC2.C2SD`, `sec.web.renderer`) for 2525C, and `mil-sym-java`
  2.1.5 (`armyc2.c5isr`, with jsvg 1.6.1 and geodesy 1.1.3) for 2525D
  and E. Both draw headless on JDK 21 (`java.awt`). takkernel's own
  `gradle/versions.gradle` pins exactly these versions.
- **5.5's CoT markers are 2525C.** A marker's code comes from
  `CotUtils.mil2525cFromCotType`: 15 characters, which picks the 2525C
  provider. `mil-sym-java` 2.1.5 serves only the 2525D and E providers,
  which the type picker and the drawing tools use.
- **G1.15 had the cause wrong** (trap 14): the glue doesn't need an
  artifactory-only renderer; android-port shadowed the public one.
- **Decided (owner, 2026-11-18):** the renderers run on the app's JVM,
  called through `EngineBridge`; Swift ports only the type → code
  mapping; the app still ships no `shared` (decision 2 stands). **Both
  families ship now**: the 2525C set for markers, and 2525D/E ready for
  the drawing tools (about 3.5 MB of jars).

### G3.7a — the renderers in the app (2026-11-18, branch `g3/milsym`)

#### What changed

- **Nine jars join the engine's** (`dev/g1/kernel/runtime-classpath.gradle`
  resolves them at takkernel's own versions into `kernel-dist`;
  `classpath.sh` already puts android-port last). Each has an
  `inventory.csv` row and is in `engine-jars.txt`. JSVG's MIT text is its
  jar's own (`licenses/texts/jsvg-license.txt`); `JavaRendererUtils`
  carries the project's symbol fonts under its Apache-2.0.
- **`mactak.engine.Symbols`** draws one code as 5.5's providers would
  for a marker. A 15-character code goes to the 2525C renderer, anything
  else to 2525D/E. The icon is 32 pixels times the relative scaling;
  for 2525C, `KEEPUNITRATIO` and `ICON` are false. Civilian units are
  filled purple unless hostile or suspect. No modifiers are drawn. A
  2525C code renders only if 5.5's symbol table would take it (a graphic,
  or a unit, with a path and not under "Basic Shapes") and it is a point.
  `EngineBridge.symbolPng(code)` returns PNG bytes, and `canRenderSymbol`
  says whether that call would draw.
- **`CotSymbols`** (`MacTAKCot`) is the Swift port of
  `mil2525cFromCotType`, with its quirks: a lower-case result, the
  parent-type fallback, the cache, and "" for non-atoms. The app passes
  `EngineBridge.canRenderSymbol` to it.
- **The golden test** (`make test-symbol-golden`, CI's `jvm-tests` job)
  works like this:
  - takkernel compiles `:shared` with its 2525 glue, with the mil-sym
    jars ahead of android-port.
  - It registers 5.5's three providers, as `ATAKUtilities` does.
  - The kernel's own mapping runs over 900 types: one per 2525C unit,
    plus `types.txt`'s edge cases.
  - For every code the mapping can ask about (1,233), it records
    whether the kernel draws it.
  - `Symbols` must answer every code the same way. Each symbol both
    draw (1,200) must match the kernel's pixel for pixel.

  `CotSymbolsTests` holds the Swift port to the same files, answering
  its renderer's questions from `renderable.tsv`.
- **`MacTAK --check-symbols`**: the bundle's JVM draws a 2525C and a
  2525D code, and refuses nonsense; `bundle-runtime.sh` leg 4 runs it.
- **G2's `android.graphics.Bitmap`** gains the private
  `(BufferedImage)` constructor and `getAwtBufferedImageImplementation`.
  takkernel's desktop `BitmapMarshal` reaches for both by reflection
  (trap 15).
- **Left out of the plan's PR a:** `get2525DFrom2525C`. It needs the
  kernel's C→D table and both providers' affiliation and status setters,
  and nothing in G3.7 draws 2525D. It comes with the type picker.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

- `make test-symbol-golden` PASS: 900 types, 1,233 codes, and 1,200
  symbols pixel-identical to the kernel's.
- `CotSymbolsTests` 4 tests PASS. The port matched every type on the
  first run.
- `make app` PASS: 59 jars, and the license gate passes.
  `make test-app-bundle` PASS, leg 4 included.

#### Traps

- **14 — android-port shadows missioncommand's 2525 renderer.**
  `android-port-3.1.0-g55.jar` (from the 5.5.1.8 apk) carries its own
  Android-typed `armyc2.c5isr` classes, 326 entries. Ahead of the real
  jars on a classpath, they break the kernel's desktop glue at compile
  time; G1.15 read that as "artifactory-only renderer". With the
  mil-sym jars first, all of `:shared` compiles. The app's classpath
  already ends with android-port.
- **15 — the kernel's 2525 providers fail silently on the public
  android-port.** Three things break, each silently:
  - The symbol tables open a raw resource through
    `JavaResourceManager`, which is `new Context()`: android-port's
    `getResources()` is null.
  - `BitmapMarshal` builds `android.graphics.Bitmap(BufferedImage)` by
    reflection, which the substitute lacks, and returns null.
  - `AtakMapView.getDefaultTextFormat()` dereferences android-port's
    null `Typeface.DEFAULT`.

  `mil2525cFromCotType` swallows the failures, so every type maps to
  its root. The oracle runs the providers on G2's Android runtime
  (`dev/g2/render/src/android`, which the app runs on), with the new
  `Bitmap` hooks, plus a test-only `Context` and `Resources` that open
  `:shared`'s `res/raw` (`dev/g3/test/oracle-android`). The app never
  calls the providers.

### G3.7b — markers on the map (2026-11-18, branch `g3/map-markers`)

#### What changed

- **`mactak.render.MapMarkers`**: the map's marker layer. It is an
  in-memory `FeatureSetDatabase2` under its own `FeatureLayer3`, which
  `WindowApp` adds after the data layers so markers draw on top.
  - Each marker is one feature, as 5.5's `GLMarkerFeature.toFeature`
    writes it: a point clamped to the ground, at its altitude (0 when
    unknown).
  - The point carries an `IconPointStyle` with the icon URI, tint, size
    and rotation.
  - The feature's name is the label.

  `EngineBridge.putMarker`, `removeMarker` and `markersReady` drive it.
  Markers sent before the map exists are dropped, as `panTo`'s calls
  are.
- **`MarkerIcons`** (`MacTAKComms`) picks the icon as
  `Icon2525cIconAdapter.adapt2525cMarkerIcon` does:
  - A team member draws its role's icon
    (`icons/roles/<role>[_human|_nogps].png`) tinted with
    `teamToColor`'s exact colour. A custom role draws `team.png`.
  - Anything else, and a team member shown as a symbol, draws its type's
    2525C symbol (G3.7a) as a `base64://` PNG, or else
    `unknown-type[-f|-n|-h|-u].png`.
  - Stale is `CotMarkerRefresher`'s tint: GRAY for a team member, DKGRAY
    otherwise.

  The contacts list's team dots now use the same exact colours.
- **The self marker** is `LocationMapComponent.refreshGpsIcon`'s icon:
  - `ic_self_tintable` tinted 0xff44b2dd under `ic_self_stroke_tintable`
    in white, flattened, 32 × 43, sent as `base64://`
    (`mactak.render.SelfIcon`, `EngineBridge.selfIconUri`).
  - It turns with the track's course, and has no label.
- **`MapMarkerSync`** (the app) works out the wanted markers once a
  second: every contact, and the self position. It sends the engine only
  what changed, and everything again when the map starts. The tick also
  catches contacts going stale, which publishes nothing.
- **5.5's icons** are copied from the pin into
  `dev/g2/render/resources/assets/icons` (136 KB): the role icons, the
  unknown-type and damaged icons, and the two self drawables.
  `render/env.sh` copies `resources/` into the classes, so
  `asset://icons/...` resolves through `ClasspathAssets` as 5.5's URIs
  are written.
- **G2's `android.util.Base64`** is real now (trap 16).
- **`RenderSmoke --marker LAT,LON,ICON[,AARRGGBB]`** (ICON is a URI or
  `self`). Markers count as content, so the render waits for their icons.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

- `dev/g2/render/test/markers.sh` PASS (CI's render job, `make
  test-render`):
  - A cyan team marker draws #00ffff over its point, and the self marker
    5.5's #44b2dd.
  - The ground between them stays black.
  - With no markers, the same checks fail.
- `MarkerIconsTests`: 5 tests PASS.
- `make app` PASS. In the app, the placed self position shows 5.5's
  self marker (owner looked, 2026-11-18).

#### Not yet (5.5 has them)

- **Labels:** 5.5's label manager puts the callsign under the marker.
  The engine draws a feature's name above it and to the right. A
  `LabelPointStyle` aligned below drew it over the icon.
- A custom role's abbreviation drawn on `team.png`.
- Heading arrows on moving contacts.
- The jumper icons. (The `readiness=false` damaged icons came with
  G3.7c.)

#### Traps

- **16 — android-port's `android.util.Base64` is a stub.** The engine's
  `base64://` icon loader (`GLBitmapLoader.Base64BitmapLoaderSpi`)
  decodes with it (`URL_SAFE | NO_WRAP`). Every such icon failed with
  "failed to handle URI base64://…", and the marker drew as a plain
  white dot. G2's runtime now has `android/util/Base64.java` on
  `java.util.Base64`, and the encoder must use the URL-safe alphabet.
  `markers.sh` fails on any "failed to handle URI" line.
- **17 — `dev/g2/.gitignore` ignores every `*.png`.** The icons in
  `dev/g2/render/resources` were never committed: the first CI run of
  #210 had no resources directory, and `env.sh`'s staleness `find`
  failed the first render step. The ignore file now makes an exception
  for `render/resources/**/*.png`.

### G3.7c — CoT markers on the map (2026-11-18, branch `g3/cot-markers`)

#### What changed

- **`CotMarkerStore`** (`MacTAKComms`) holds the CoT markers the client
  hears that aren't contacts. These are atoms (`a-…`) with no `<contact
  endpoint>`, which 5.5's marker importers put on the map.
  - A contact's SA under a marker's uid removes the marker, and a uid the
    contacts hold is never a marker. Its own uid is dropped.
  - Stale and removal are 5.5's, timed by this Mac's clock as contacts
    are: stale 1.5 × (stale − start) after it arrived, removed 5 minutes
    later (`expireEverything`, on by default).
  - A delete task (`t-x-d-d`, `CotDeleteImporter`) makes the marker stale
    now, or removes it with `<__forcedelete>`.
  - The label is the callsign, else the uid unless it is a UUID
    (`MarkerImporter`).
  - Each event's details replace the last one's. 5.5 keeps a detail an
    update leaves out; senders resend them all.

  `ServerConnections.markers` feeds it every CoT event, expires it with
  the contacts and clears it on stop. `MapMarkerSync` draws its markers;
  a contact wins a uid both hold.
- **`MarkerIcons.icon(_:stale:symbol:)`** follows 5.5's order for any
  marker (`MarkerTraits`), and contacts go through it too:
  1. `<usericon iconsetpath>` (`IconsMapAdapter`): `COT_MAPPING_SPOTMAP`
     draws an atom as `reference_point.png` in its affiliation's colour;
     a `base64://` path is the icon itself. Anything else (2525C, a user
     icon set) goes on to the 2525C adapter, 5.5's default mapping.
  2. `readiness=false`: the damaged icon for its affiliation.
  3. A team member: its role icon in its team colour (this replaces 2).
     Otherwise `<color argb>` (else `value`) tints the icon.
  4. Its type: `icon_filters.xml`, then its 2525C symbol, then the
     unknown-type icon, untinted.
- **`IconFilters`** is 5.5's `filters/icon_filters.xml`, all 63 entries
  in order. A type matches by prefix, and the last match wins, as
  `FiltersConfig.lookupFilter` does. A copy of 5.5's file sits in
  `dev/g3/test/icon-filters`, and a test holds the table to it.
- **Six more of 5.5's icons**: `ttl-icon[-f|-n|-u].png`, `green_flag.png`
  (the filters' atom entries) and `reference_point.png` (Spot Map). A test
  checks that every icon an atom can name ships.
- **`dev/g3/test/send-markers.py`** sends a typed set of markers to a
  copy's direct TCP port, one per rule, or a delete task.

#### Results (dev Mac, M5 Max, macOS 27.2.1)

- `CotMarkerStoreTests` 7, `MarkerIconsTests` 11, `ContactStoreTests` 6:
  PASS.
- `make app` PASS (the license gate included).
- **Hand check** (owner, 2026-11-18): one copy, its self position placed
  at the Ferry Building, `send-markers.py` to its port 4242. The row
  drew as 5.5 would:
  - friendly infantry, hostile armour, neutral ground and unknown air as
    2525C symbols
  - `a-f-G-E-S-t` as the filters' `ttl-icon-f`, not a symbol
  - `readiness=false` as the hostile damaged icon
  - `<color argb=-65536>` tinting the symbol red
  - the Spot Map mapping as a red dot
  - `a-u-Q` as the unknown-type icon
  - the 20-second marker dark grey once stale.

  Resending at a new latitude moved every marker in place. A delete task
  greyed one marker at once, and a forced one removed another.

#### Not yet (5.5 has them)

- User icon sets (`<usericon>` with a set's uuid): they fall through to
  2525C, as 5.5 does when the set isn't installed.
- 2525D/E markers (`__milsym`), with the type picker.
- 5.5's b-/u- point items (waypoints, SPIs, Spot Map points, CASEVAC):
  their importers, their filter icons, and the rule that a non-atom is
  removed as soon as it goes stale.
- Readiness for contacts: a non-team contact with `readiness=false`
  still draws its symbol.

#### Found during the hand check (not in this PR)

- **The wheel pans with a Logitech MX Master 3** (#211). Its smooth scrolling
  reports precise deltas, which `MetalView.scrollWheel` reads as a
  trackpad: the wheel pans instead of zooming, and there is no way to
  zoom out with it. Trackpad scrolls carry a gesture phase; a wheel's
  don't. Fixed: `ScrollSource` pans only scrolls with a phase or momentum
  phase and zooms the rest, a precise wheel delta taken as 10 points per
  line. The shell's scripted trackpad pans now set a phase
  (began/changed/ended), or they would zoom.
- **The map stopped once while the owner was zooming** (#212) (app launched
  with `open`, so no log). The UI stayed up; the engine's render thread
  was gone. Not seen again with the log on.
- **EGL failed at start (exit 3) once** (#213): `eglCreatePbufferSurface`
  returned `EGL_BAD_ATTRIBUTE` (0x3004) when the binary was started
  straight from a background shell, not through LaunchServices. Started
  with `open`, it drew.

#### Traps

- **18 — commo reads a TCP connection to its direct port as one
  message.** `send-markers.py` first sent ten events on one connection,
  and none arrived. It now opens one connection per event, as a TAK
  client sends to port 4242.

- **19 — the JVM's SIGTERM handler exits around the app's teardown**
  (#226). The JVM installs handlers for SIGTERM, SIGINT and SIGHUP, and
  they call `Runtime.exit` while the map is up. The process then exits
  without `WindowApp`'s teardown, and the engine's C++ statics destroy a
  Java-backed elevation source after the JVM is gone (G2 trap #73).
  Every MacTAK crash report from 2026-11-16 to 11-18 (six) was this, from
  a signal; ⌘Q was never affected. `SignalQuit` takes the three signals
  back once the JVM is up and quits through `NSApp.terminate`. Not
  `-Xrs`: it would also turn off SIGQUIT, which `jcmd` and `jstack` need.
  Calling `terminate` from the signal's main-queue block deadlocks:
  AppKit's quit loop runs inside that block, and
  `applicationShouldTerminate`'s `Task` needs the main queue. It goes
  through `RunLoop.main.perform`. A/B on the dev Mac (launch with `open`,
  wait 20 s, signal): before, SIGTERM leaves a crash report with
  `JVM_Halt` and `~ManagedElevationSource`; after, SIGTERM, SIGINT and
  SIGHUP each quit cleanly with no crash report.

- **20 — the feature renderer could draw a batch still mapped** (#228).
  `GLBatchGeometryFeatureDataStoreRenderer3`'s worker hands a batch over
  in `updateRenderableLists` under `monitor_`, its buffers still mapped
  and queued for `drawImpl` to unmap. `drawImpl` unmapped without the
  lock and took it only in the base class's draw, so a batch landing in
  between was drawn mapped: `GL_INVALID_OPERATION`, "An active buffer is
  mapped" on ANGLE (`glDrawArrays`, then `glDrawArraysInstanced`). It
  failed CI's basemap smoke once, at about 105 ms a frame; the dev Mac,
  at 23 ms, went 0 in 20. A diagnostic build with a 40 ms sleep after
  the unmap failed 5 runs in 8 with CI's exact errors; with the fix and
  the same sleep, 0 in 8. Fix:
  `../g1/patches/featurerenderer-unmap-under-monitor.patch` holds
  `monitor_` (recursive) from the unmap through the draw, and around
  patch 42's unmap and delete in `draw()`. The lock order is the
  worker's, `monitor_` then the discard mutex. In the app the engine
  clears GL errors, so this was a silently bad frame.
