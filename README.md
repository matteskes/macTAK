## What is TAK?

The Team Awareness Kit (TAK) is the geospatial situational-awareness stack used across public safety and defense: offline maps, team tracking over the **Cursor-on-Target (CoT)** protocol, and interop with servers like **FreeTAKServer**. ATAK-CIV is the US Government's open-source Android client; WinTAK is its closed-source Windows sibling. There is no native macOS TAK client today — that is the gap macTAK fills.

## Where it stands

G0–G3 are closed: the engine builds natively, talks CoT headless, renders the map in a native window at 60 fps, and `MacTAK.app`, a SwiftUI app around the engine's live map, works as a TAK client against real servers and on the local mesh, with ATAK 5.5's behaviour as the reference. The full plan is in [`docs/roadmap.md`](docs/roadmap.md); what shipped when is in [`CHANGELOG.md`](CHANGELOG.md).

| Gate | Status |
|---|---|
| **G0** — engine builds on macOS arm64 | ✅ Closed 2026-11-02 — `libtakengine.dylib` and the kernel jars build natively ([G0 spike](dev/spike/g0/NOTES.md)) |
| **G1** — headless engine + CoT round-trip | ✅ Closed 2026-11-04 — `atak-headless` opens GeoJSON/GPKG/KML/SHP layers, round-trips CoT with FreeTAKServer and OpenTAKServer over TCP and SSL through commoncommo, persists tracks, and connects from an ATAK data package |
| **G2** — map renders in a native macOS window | ✅ Closed 2026-11-19 — ANGLE-on-Metal (built from source at a pinned commit) in the engine's GLES slot; real imagery, vector and terrain in a Swift/AppKit window with the JVM in-process and Apple Maps gestures; the exit run passes 21 of 21 with no on-screen miss ([G2 notes](dev/g2/NOTES.md)) |
| **G3** — core client skeleton | ✅ Closed 2026-11-26 — two copies of the app enroll with OpenTAKServer into the Keychain, connect over TLS and see each other's contact, point on screen and chats (`make g3-exit`); G3.0–G3.11 built the client, see below ([G3 notes](dev/g3/NOTES.md)) |
| **G4–G6** — data/import parity, first deployable client, the parity ladder to full ATAK-CIV | ⚪ Planned |

## Features in the app today (G3)

- **Servers and identity** — TAK servers over TCP, TLS with client certificates, or QUIC; certificates in the macOS Keychain; ATAK data-package import; certificate enrollment by username and password with the device profile fetched; TAK Server Quick Connect. Every connection uses commo's OpenSSL 3.
- **Mesh networking** — no server needed: SA and chat on ATAK's multicast groups and direct TCP, on every network interface, on by default as in ATAK.
- **SA** — the self-SA goes out at ATAK 5.5's `ReportingRate` pace, from CoreLocation or a placed position; a Contacts sidebar lists everyone heard, stale-greyed on ATAK's timing; a My Details sheet sets callsign, team, role and the rest under ATAK's preference keys.
- **GeoChat** — All Chat Rooms, team, role, user-made group and one-to-one rooms, delivered and read receipts, history in SQLite, in a Messages-style Chat window.
- **Coordinates** — MGRS, UTM, DD, DM, DMS and ADDR, altitude in MSL (the engine's EGM96 grid) or HAE; a Units pane in Settings and a self readout over the map; address lookup through Apple Maps or an imported Nominatim geocoder.
- **Markers with MIL-STD-2525 symbols** — contacts, the self arrow and CoT markers drawn as ATAK 5.5 draws them, with missioncommand's 2525C (and 2525D/E) renderers.
- **Range and bearing** — the R&B Line tool with 5.5's numbers (magnetic north from the WMMHR-2025 model), lines that follow the markers they join, shared and received as 5.5's `u-rb-a` CoT.
- **Points** — drop 2525C's four affiliations and Spot Map dots with a click, named as 5.5 names them; a right-click menu and an inspector to rename, recolour, change affiliation, add remarks, look up the address, move (or drag), send and delete; sent as 5.5's marker CoT, field by field.
- **Routes** — draw a route with the Route tool (click a control point, ⌥-click a checkpoint), drag its points, and edit it from right-click menus and an inspector with 5.5's route details and leg distances; drawn in 5.5's line styles, named as 5.5 names them, shared and received as 5.5's `b-m-r` CoT.
- **The Overlay Manager** — a sidebar tree of the map's items by kind, built from 5.5's own overlay rules: search, sort by name or distance, Show All and Self-Authored; show or hide an item or a whole list, click to go to it, right-click for its actions, multi-select to delete.
- **Map items kept across launches** — points, routes, R&B lines and archived markers, shown or hidden, as 5.5's StateSaver keeps them.

The CoT model, coordinates, range and bearing and the 2525 mapping are Swift ports held to the kernel's own answers by golden tests (`make test-cot-golden`, `test-coord-golden`, `test-rab-golden`, `test-symbol-golden`).

## How the port works

- **The engine builds natively.** takkernel's C++ engine (`libtakengine.dylib`) and its Java modules build on macOS arm64 from a read-only pin of upstream ATAK-CIV 5.5.1.10; changes to upstream live as patch files, never in place.
- **The renderer is a substitution slot.** takkernel consumes OpenGL ES through an injectable provider, so macOS plugs in **ANGLE-on-Metal** — the same backend Chromium ships — rather than porting GL by hand. macTAK builds ANGLE from source and carries its own small patch set (`dev/g2/angle-patches/`).
- **The app layer is a Swift rewrite.** The SwiftUI/AppKit app boots the engine's JVM in-process and hosts the map in a `CAMetalLayer`; the client logic (CoT, SA, chat, coordinates, tools) is Swift, using ATAK 5.5 as the behavioural reference ([`docs/atak-feature-coverage.md`](docs/atak-feature-coverage.md)).
- **Comms are portable.** commoncommo is a C++ core, reached from Swift through a C shim (`CCommoShim`), alongside takproto (protobuf) and takcot (CoT schemas).
- **One TLS stack.** The bundle carries its own natives — macTAK's own minimal GDAL/PROJ/SpatiaLite build on OpenSSL 3 ([`dev/deps/README.md`](dev/deps/README.md)) — and every third-party component it ships is inventoried with its license.
- **Verification runs against real TAK.** A WinTAK golden VM ([Pathway A](docs/pathway-a.md)), FreeTAKServer and OpenTAKServer provide the interop baseline.

## Getting started

macOS 27 on Apple silicon, Homebrew, and JDK 21 (arm64). The full setup — including populating `src/` with the upstream pin — is in [`CONTRIBUTING.md`](CONTRIBUTING.md#setup).

```bash
brew bundle install       # every Homebrew dependency, pinned by Brewfile.lock.json
make hooks                # install the pre-commit gate
make build-angle          # kernel jars + engine with ANGLE in the GLES slot + commo
make app                  # build/MacTAK.app — open it to run the client
make test-app             # the Swift package's tests: comms over TCP, mutual TLS, QUIC, mesh
make help                 # every target, with what it checks
```

## Repository layout

| Path | Contents |
|---|---|
| `app/` | The macOS app: a Swift package (`MacTAK` SwiftUI app, `MacTAKCore`, `MacTAKCot`, `MacTAKComms`, the `CCommoShim`/`CJavaBoot`/`CMagnetic` C modules, `mactak-shell`), its resources and `bundle.sh` |
| `docs/` | Program documents: feasibility study, architecture, roadmap, CI/QA plan, Pathway A baseline, feature coverage, the 5.5 rebase study, the license audit |
| `dev/` | Development workspace: `dev/g1/` native engine build harness (recipe, patch set, headless client), `dev/g2/` renderer, ANGLE build and window shell, `dev/g3/` G3 notes and golden fixtures, `dev/deps/` macTAK's own GDAL/PROJ/SpatiaLite build and the license tooling, `dev/docs-site/` the docs site, `dev/spike/` gate-spike records (`g0` build recipe, `g55` the 5.5 rebase), `dev/reference/` CoT client test tools (WinTAK-derived captures are `.gitignore`d — GOTS artifacts never enter this repo) |
| `licenses/` | The record of every third-party component the app bundle carries: `inventory.csv` and each license text |
| `src/` | Read-only pinned sparse clone of upstream ATAK-CIV, `TAK-Product-Center/atak-civ` @ `9f6893d` (5.5.1.10) — populated locally, never committed |

## Project documents

All of these, plus the engineering notes under `dev/`, are also published as one browsable site,
with a sidebar, search and a table of contents on every page:
<https://matteskes.github.io/macTAK/>. It is built from these same files
on every merge to `main` (`dev/docs-site/`, `make docs-site`).

| Doc | Contents |
|---|---|
| [`docs/feasibility-report.md`](docs/feasibility-report.md) | Founding feasibility study: measured effort, decisive findings, risk — start here for the numbers behind every claim |
| [`docs/architecture.md`](docs/architecture.md) | Verified repo layout, LOC inventory, dependency graph, build/CI reality |
| [`docs/pathway-c.md`](docs/pathway-c.md) | Host strategy (JVM vs native Swift), renderer mapping, risk register, prior art |
| [`docs/roadmap.md`](docs/roadmap.md) | Gate-gated plan G0–G6 with exit criteria, status and fallback decision points |
| [`docs/ci-qa.md`](docs/ci-qa.md) | CI/QA plan: inherited test corpus, CI tiers, golden fixtures, runner strategy |
| [`docs/pathway-a.md`](docs/pathway-a.md) | WinTAK golden VM: build record, FreeTAKServer round-trip verification, gotchas |
| [`docs/atak-feature-coverage.md`](docs/atak-feature-coverage.md) | ATAK-CIV's feature set mapped to what macTAK supports today, and the app-layer decision (rewrite in Swift) |
| [`docs/rebase-study-5.5.md`](docs/rebase-study-5.5.md) | Measured cost of moving the upstream baseline from 4.6.0.5 to 5.5.1.10; the staged rebase plan |
| [`docs/license-audit.md`](docs/license-audit.md) | Full license audit of everything the app bundle redistributes: findings F1–F8 and the gates that keep the record current |
| [`licenses/README.md`](licenses/README.md) · [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) | The license inventory and its machinery; the generated third-party notices |
| [`dev/deps/README.md`](dev/deps/README.md) | Why and how macTAK builds its own GDAL, PROJ and libspatialite |
| [`dev/g1/NOTES.md`](dev/g1/NOTES.md) · [`dev/g2/NOTES.md`](dev/g2/NOTES.md) · [`dev/g3/NOTES.md`](dev/g3/NOTES.md) | Engineering notes per gate: how each milestone went — plans, decisions, traps, gate logs |
| [`dev/spike/g0/NOTES.md`](dev/spike/g0/NOTES.md) · [`dev/spike/g55/NOTES.md`](dev/spike/g55/NOTES.md) | The G0 build spike, and the move of the baseline from 4.6 to 5.5 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Contributor guide: setup, the gate ladder, where changes land (patches/shadows/shim), CI contract, house style |
| [`CHANGELOG.md`](CHANGELOG.md) | Release history by gate — 0.1.0 G0 engine builds, 0.2.0 G1 headless + CoT, 0.3.0 G2 map renders, 0.3.1 window surfaces + hardening, 0.3.2 the G2 exit run + G3.0 app skeleton, 0.3.3 G3.1–G3.3 servers, identity and mesh + the license audit; Unreleased: G2 closed, G3.4–G3.11 and G3's exit run (G3 closed) |

## Local gates

Run `make hooks` once per clone to install the git hooks (`core.hooksPath .githooks`). The pre-commit hook then checks every staged file: `shellcheck` + `bash -n` on `*.sh`, `markdownlint-cli2` on `*.md`, `actionlint` on `.github/workflows/*.yml`, and SHA256 verification of jars under `dev/g1/transplants/` and `dev/spike/g0/transplants/` against their `SHA256SUMS` manifests. Optional tools that are not installed are skipped with a visible message. `make lint` runs the same checks across the whole `dev/` tree, sweeping the repo's own docs but skipping the read-only `src/` pin — CI's docs job likewise lints only PR-changed `*.md`. The full table of gates, and which run in CI versus only on a dev Mac, is in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

GPL-3.0 — see [LICENSE](LICENSE). macTAK inherits the GNU GPL v3 obligation from upstream ATAK-CIV (`TAK-Product-Center/atak-civ`, formerly `deptofdefense/AndroidTacticalAssaultKit-CIV`). Third-party components the app bundle carries are listed, with their licenses, in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

This is an independent open-source project — not an official TAK product and not affiliated with the US Federal Government, the US Department of War, nor any other agent thereof.

(c) 2026 macTAK contributors.
