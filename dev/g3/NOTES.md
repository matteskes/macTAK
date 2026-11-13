# G3 — the core client skeleton

G3 turns G2's map window into a TAK client: a contacts list, CoT markers
and routes on the map, GeoChat, server connections with certificates in
the macOS Keychain, a layer manager and coordinate tools. **Exit:** two
Mac clients on one TAK server see each other's markers and chat live
(`docs/roadmap.md` G3).

## State (G3.0 — 2026-11-13): the app skeleton, and EngineBridge v0

`app/` is a Swift package. Its SwiftUI app, `MacTAK`, opens a window with
a sidebar (placeholders for contacts and chat) and the engine's map,
live and interactive: `make app` builds `build/MacTAK.app`, which opens
on the G2 exit run's NAIP imagery, 3DEP terrain and the landmarks when
`make exit-run` has fetched them. The G2 test harness, `mactak-shell`, is
now a product of the same package on the shared library `MacTAKCore`,
with its flags, log lines and exit codes unchanged; `make test-shell`
and `make exit-run` drive it as before. Swift reaches the engine only
through `mactak.engine.EngineBridge`, which replaces the 22 positional
arguments of `WindowApp.start` with a `MapConfig`. Next: G3.1, commo from
Swift.

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
| G3.1 | commo from Swift: a C++ listener shim, a `CommoClient` actor | two clients through `fake-cot-server.py` see each other (CI) |
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
