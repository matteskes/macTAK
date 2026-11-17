# G3 — the core client skeleton

G3 turns G2's map window into a TAK client: a contacts list, CoT markers
and routes on the map, GeoChat, server connections with certificates in
the macOS Keychain, a layer manager and coordinate tools. **Exit:** two
Mac clients on one TAK server see each other's markers and chat live
(`docs/roadmap.md` G3).

## State (G3.3 done — 2026-11-17): servers, identity and mesh

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
on `en0` saw each other with no server. Next: G3.4, SA: the CoT model,
contacts, reporting rate and self details (§Plan revision).

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
