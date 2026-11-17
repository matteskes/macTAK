# G3 — the core client skeleton

G3 turns G2's map window into a TAK client: a contacts list, CoT markers
and routes on the map, GeoChat, server connections with certificates in
the macOS Keychain, a layer manager and coordinate tools. **Exit:** two
Mac clients on one TAK server see each other's markers and chat live
(`docs/roadmap.md` G3).

## State (G3.2c — 2026-11-17): certificate enrollment, the device profile

`app/` is a Swift package. Its SwiftUI app, `MacTAK`, opens a window with
a sidebar (placeholders for contacts and chat) and the engine's live map
(`make app`; G3.0). Swift talks to TAK servers too: `CommoClient`, an
actor in `MacTAKComms`, drives commo's C++ API through `CCommoShim`
(G3.1). Every build links commo, and two clients see each other over
TCP, over TLS with client certificates and over QUIC (G3.2a). An ATAK
data package's servers and certificates import into a keychain (G3.2b).
Since G3.2c a client can enroll for its certificate by username and
password, through commo, and fetch its device profile through the
shim's curl; two enrolled clients see each other over mutual TLS
(`make test-app`, in CI's shell job). The app doesn't connect to
anything yet. Next: G3.2d, the app's servers pane (§G3.2, the plan).

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
   `CotMapComponent`). Still to check: what macOS's local-network
   permission asks of a multicast client.
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
| **c** | `g3/enrollment` | certificate enrollment through commo; the device profile; a fake enrollment server |
| d | `g3/servers-pane` | the app's servers pane: add, import, enroll, connect |

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
  self-contained `MacTAK.app` could read neither. G3.2d stages it.

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
  indents its XML would crash the app. The fix is a commo patch (skip
  non-element children), in G1's patch series; not done here.
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
