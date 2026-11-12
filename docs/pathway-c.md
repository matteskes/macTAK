# Pathway C Deep Dive: Native macOS Port of ATAK-CIV

Companion to `feasibility-report.md` (verdict/effort) and `roadmap.md` (plan). Everything factual is pinned to clone `src/` @ `889eee2` (v4.6.0.5) or to the prior ecosystem research summarized in §Prior art.

## 1. What "native macOS port" decomposes into

| Layer | ATAK-CIV today | macOS-native strategy |
|---|---|---|
| Renderer | GL ES 2/3 contexts created Android-side; engine C++ is context-agnostic (measured: 7 `#include <GLES>` files in engine cpp; **0 EGL refs outside Android sources**) | **ANGLE on Metal** supplies EGL 1.5 + ES 3 in the engine's existing `GLES-stub` link slot; context injected by host |
| Map engine | `takkernel/engine`: 186,804 LOC platform-neutral Java + 451,170 C++ + 5,424 LOC Android-only Java + 1,443 LOC desktop-Java (`jre`: JOGL) | Build as-is on macOS (branch exists); consume via JVM host (proven: TAKX) or wrap C++ API for Swift |
| Comms | commoncommo 44,828 C++ (JNI + **ObjC** + win32 bindings + `commoncommo.xcodeproj`), takproto protobufs, takcot XSD schemas | Native: ObjC bindings from Swift, or JNI in-process; transport validated on Apple by MIT Swift `TAKTracker` |
| App/UI | 492,324 LOC Android (`src/common` is 453 LOC — no usable shared-UI layer) | **Rewrite** in AppKit/SwiftUI against engine APIs — this is the project's center of mass |
| Platform services | Android permissions, services, `libunwindstack-ndk` crash stack, `jnicrash` | macOS equivalents: Keychain, `NWPathMonitor`/services, PL crash reporter; unwind stack dropped |
| Plugins | `pluginsdk.zip` → APK-bound Android artifacts | **No path** — document as out of scope; offer native extension API instead |

## 2. Host architecture — the central design decision

**H1 — JVM host (TAKX-style):** Run takkernel's `java` target on a macOS JVM; UI = Swing + JOGL (`engine/src/jre` proves the pattern; `EngineLibrary` loads `jawt`, present on macOS JVMs).
*Pros:* shortest path to a working map (weeks after G0), engine semantics untouched, single process. *Cons:* ships a JVM; Swing/JOGL UX is not macOS-native; AppKit/AWT threading constraints; fails the "true native" bar for UI fidelity.

**H2 — Native host (recommended target):** Swift/AppKit shell; engine behind a thin C-API wrapper (or JNI in a helper process); render via ANGLE-Metal EGL surface handed to the engine.
*Pros:* true native fidelity — the goal of Pathway C; Keychain/Notifications/Shortcuts integrate naturally. *Cons:* ABI/threading work at the boundary; engine's Java-facing conveniences (track DB, layers API surface) need deliberate exposure.

**Recommended: H1 as a G1–G2 scaffolding phase, converge to H2 by G3.** A hybrid fallback (headless engine process + native UI over IPC + shared texture) resolves any AppKit-vs-JNI threading conflict at G2.

## 3. Renderer: ANGLE-on-Metal substitution mechanics

- `MacOSSources.cmake` defines the contract: `TE_GLES_VERSION=3`, links `GLESv2` from a `GLES-stub` lib-dir slot. ANGLE provides `libGLESv2.dylib` + `libEGL.dylib` on macOS with a Metal backend (ES 2/3.0, EGL 1.5) — the same stack Chromium ships on macOS, i.e., production-hardened.
- Engine-side surface creation happens in host code, not the engine core (measured). The JNI/JOGL hosts are the reference for what a macOS host must supply: display, config, context, surface swap.
- Known watch-items: ANGLE's EGL surfaceless/context-robustness extensions vs what `GLMapView`/`GLGlobe` assume; iOS-style `EAGL` assumptions live only in the Android set (12 files), which we discard.

## 4. Build-system archaeology (what G0 actually fights)

The Android build pins (NDK r12b, CMake 3.14.7, Java 8, Conan 1.59, `SQLITE_HAS_CODEC` SEE-style hooks) constrain **the Android target**, not macOS: for macOS we pick a modern Xcode toolchain and only fight the *source* age — 2016-era C++ under current clang (warning floors, removed extensions), GDAL **2.4.4-mod** autoconf build on arm64, MrSID distfile gaps in `macos-64.mk` (stub raster drivers), Conan 1.x EOL (prefer Homebrew/vcpkg mapping), and `takRepoMavenUrl/ConanUrl` credential expectations in takkernel's Gradle (the public CI shows the all-from-source alternative path).

License: **GPL-3.0** propagates to any port of this tree; plan publication at first external release (G5), legal review at kickoff.

## 5. Risk register

| # | Risk | L×I | Signal / Mitigation |
|---|---|---|---|
| R1 | Engine C++ won't build cleanly on arm64 (source/toolchain age) | M×H | G0 spike is dedicated to this; fallback Rosetta-x86_64; re-score if >3 wk |
| R2 | ANGLE contract mismatch vs `GLES-stub` expectations | L×M | G2 early integration test; JOGL/H1 fallback |
| R3 | `gdal-2.4.4-mod` arm64 build pain | M×M | Modern GDAL behind engine `raster`/`db` SPIs |
| R4 | AppKit ↔ JVM/JNI threading conflicts | M×M | Hybrid split-process architecture (G2 decision) |
| R5 | takkernel Gradle expects TAK artifact-repo creds | M×L | All-from-source path proven by public CI |
| R6 | GPL-3.0 obligations constrain distribution | M×M | Publish plan at G0; org sign-off before any internal-only fork temptation |
| R7 | Engine drift: upstream resumed — public 5.5 source at `TAK-Product-Center/atak-civ` (2026-11-11) | H×M | Keep the port a thin fork (no engine edits where host-side possible); rebase in stages per [rebase-study-5.5.md](rebase-study-5.5.md). **Re-pinned to 5.5.1.10 on 2026-11-11**; the next bump follows the same pattern (CONTRIBUTING.md, "Moving the upstream baseline") |
| R8 | Feature-comparison pressure vs WinTAK/TAKX (closed, GOTS) | H×M | Manage expectations via parity-ladder rungs (roadmap G6); never promise parity dates |
| R9 | Plugin ecosystem loss vs Android ATAK | H×L | Native extension API; explicit scope statement |
| R10 | Comms path choice (JNI vs ObjC bindings) rework | L×L | Decide at G1; both bind the same C++ core |

## 6. Prior art (from ecosystem research, verified before clone)

- **No macOS-native TAK client exists** — official or community (GitHub API + Wikipedia verification; tak.gov/DDG fetches blocked); no Linux desktop client either, so the only reference UX for comparison is WinTAK (Windows) or ATAK itself (Android) — the Pathway A baseline below. Pathway C would be the first.
- **WinTAK** — Windows-only, closed GOTS (the TAKX/knowledge that takkernel's `java` target serves a desktop client is in-tree corroboration: takkernel README names TAKX explicitly).
- **FreeTAKServer** (Python, server), **WebTAK/FTS-UI** (browser), **pytak** (Python CoT lib), **thebentern/Tak.Client** (C# console) — servers/libraries, not native clients.
- **flighttactics/TAKTracker** (MIT, Swift) — an iPhone CoT *tracker* with no map client; the one salvageable artifact: working CoT-over-SSL reference using Apple networking/location APIs. G1 cross-reference.
- **kentnf/iTAK** — plant-genomics red herring; no public iTAK source (iTAK itself is Android, closed).
- Real-world macOS TAK usage today = **Pathway A**: WinTAK under Parallels or ATAK in an Android emulator — the contrast baseline and the fidelity reference for parity rungs (baseline captured 2026-11-01: `pathway-a.md`).

## 7. Bottom line

The clone **upgraded** the feasibility story relative to pre-clone research: the engine's macOS and desktop scaffolding is not folklore — it is in the tree (CMake `elseif(APPLE)`, `macos-64.mk`, jre/JOGL host, commo Xcode project). The risk concentrates exactly where pre-clone research predicted — the 492K-LOC Android app layer — and is bounded by architecture (context-agnostic renderer, platform-neutral engine core, portable Apple-first comms). The open unknowns are all **compile-and-run questions** answerable by the G0 spike, not research questions.
