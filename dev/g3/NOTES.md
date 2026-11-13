# G3 — the core client skeleton

G3 turns G2's map window into a TAK client: a contacts list, CoT markers
and routes on the map, GeoChat, server connections with certificates in
the macOS Keychain, a layer manager and coordinate tools. **Exit:** two
Mac clients on one TAK server see each other's markers and chat live
(`docs/roadmap.md` G3).

## State (G3.1 — 2026-11-13): commo from Swift

`app/` is a Swift package. Its SwiftUI app, `MacTAK`, opens a window with
a sidebar (placeholders for contacts and chat) and the engine's live map
(`make app`; G3.0). Swift now talks to TAK servers too: `CommoClient`, an
actor in `MacTAKComms`, drives commo's C++ API through `CCommoShim`, and
two clients through `fake-cot-server.py` see each other's contact, marker
and presence (`make test-app-comms`, in CI's comms job). The app doesn't
connect to anything yet: that comes with the CoT model and contacts in
G3.2. Next: G3.2, the CoT model, contacts and markers on the map.

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
| G3.2 | the CoT model in Swift, contacts, markers on the map | CoT parse tests; markers' pixels where expected (CI) |
| G3.3 | GeoChat: All Chat Rooms and one-to-one | a chat leg in the comms test |
| G3.4 | servers and the Keychain: `.p12` and data-package import, TLS | a TLS leg against a TLS fake server, in a throwaway keychain |
| G3.5 | routes, and dropping, editing and deleting points | a route render; a dropped point reaches the other client |
| G3.6 | the layer manager and coordinate tools (DD, DMS, MGRS) | per feature |
| Exit | `make g3-exit`: two app instances, TLS, FTS and OTS | each sees the other's contact, marker (on screen) and chat |

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
- **`make test-app-comms`** stages commo (`app/stage-commo.sh`) and runs
  the package's build and tests with `MACTAK_COMMO_LIB` set. CI runs it in
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
- **3 — commo is built for the build machine's macOS.** The linker warns
  that the package targets macOS 14 but commo was built for 27.2:
  `build-commo.sh` sets no deployment target, so commo may use newer APIs
  than the app claims to need. That's harmless on the build machine and
  matters only when the app runs on an older macOS: G5's self-contained
  bundle has to build commo (and the engine) for the app's minimum.
