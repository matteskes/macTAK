## What is TAK?

The Team Awareness Kit (TAK) is the geospatial situational-awareness stack used across public safety and defense: offline maps, team tracking over the **Cursor-on-Target (CoT)** protocol, and interop with servers like **FreeTAKServer**. ATAK-CIV is the US Government's open-source Android client; WinTAK is its closed-source Windows sibling. There is no native macOS TAK client today — that is the gap macTAK fills.

## Target features

| Capability | Status |
|---|---|
| Offline map layers via the takkernel engine (GeoPackage, shapefile, …) | ✅ G1 M3 criterion met — `atak-headless --layer FILE` opens GeoJSON/GPKG/KML/SHP headless through the engine's native OGR provider and `FeatureDataStore2`; rendered layers land at G2 |
| CoT in/out via commoncommo, interoperating with FreeTAKServer | ✅ G1 criterion met (M2–M4, 2026-11-04): `atak-headless --connect HOST:PORT` on the commoncommo JNI stack; two-client round-trip verified against FreeTAKServer and OpenTAKServer over TCP and SSL; `--datapackage FILE` (2026-11-05) resolves the connection from an ATAK data package |
| Track persistence via the engine's tracking database | ✅ G1 M4 (2026-11-04): received CoT persists through the engine's `DatabaseImpl` JNI into a sqlite tracks DB (`--db`), hermetically in CI |
| Native macOS map rendering — ANGLE-on-Metal as the GLES provider | 🔵 In progress — G2 M1–M3.1 (through 2026-11-06): ANGLE (EGL 1.5 / ES 3.0 on Metal) occupies the engine's GLES slot; a GeoJSON vector layer (polygons, lines, labels) over an offline MBTiles basemap renders through the engine into an EGL pbuffer from the JVM with zero GL errors (`make build-angle && make test-render` → PNG). The window surface is proven (M3.0): `eglCreateWindowSurface` takes a live `CAMetalLayer` — `make smoke-window` draws, reads back and presents it (manual on a GUI Mac); M3.1 adds the window natives + dynamic-size context, exercised headlessly as a CI gate (`make test-render-window` — resize mid-run through the host's `drawableSize`). H2 (native/ANGLE) chosen over H1 (JOGL). Next: M3.2–M3.4 (Swift shell → loop/resize → gestures) and G2.4 real imagery |
| Core client subset and full ATAK-CIV parity | ⚪ Planned — G4–G6 |

## How the port works

- **The engine already builds natively.** `libtakengine.dylib` (9.6 MB Mach-O arm64, ~460 translation units) compiles and links on macOS, and all five kernel Java modules publish to mavenLocal on Zulu 8 arm64 — proven by the [G0 spike](dev/spike/g0/NOTES.md).
- **The renderer is a substitution slot.** takkernel consumes OpenGL ES through an injectable provider, so macOS plugs in **ANGLE-on-Metal** — the same backend Chromium ships — rather than porting GL by hand.
- **Comms are portable.** commoncommo is a C++ core with JNI and Objective-C bindings, alongside takproto (protobuf) and takcot (CoT schemas).
- **Verification runs against real TAK.** A WinTAK golden VM ([Pathway A](docs/pathway-a.md)) plus a Mac-side FreeTAKServer provide the interop baseline; a WinTAK↔FTS CoT round-trip has already been witnessed at the protocol layer.

## Repository layout

| Path | Contents |
|---|---|
| `docs/` | Program documents: feasibility study, architecture evidence, roadmap, CI/QA plan, Pathway A baseline |
| `dev/` | Development workspace: `dev/g1/` native engine build harness (recipe + patch set), `dev/spike/` gate-spike records (`dev/spike/g0/` = G0 build recipe, wrapper, patch catalog; `dev/spike/g55/` = the 5.5 rebase: ported patch series, build harness, record), `dev/reference/` test rig — CoT client tools (committed); WinTAK-derived captures (`.gitignore`d — GOTS artifacts never enter this repo) |
| `src/` | Read-only pinned sparse clone of upstream ATAK-CIV, `TAK-Product-Center/atak-civ` @ `9f6893d` (5.5.1.10; 4.6.0.5 @ `889eee2` until the 2026-11-11 re-pin) — changes to it are exported as patch files, never committed in place |

## Project documents

All of these, plus the engineering notes under `dev/` (the G1 and G2
records and the spike notes), are also published as one browsable site,
with a sidebar, search and a table of contents on every page:
<https://matteskes.github.io/macTAK/>. It is built from these same files
on every merge to `main` (`dev/docs-site/`, `make docs-site`).

| Doc | Contents |
|---|---|
| [`docs/feasibility-report.md`](docs/feasibility-report.md) | Founding feasibility study: measured effort, decisive findings, risk — start here for the numbers behind every claim |
| [`docs/architecture.md`](docs/architecture.md) | Verified repo layout, LOC inventory, dependency graph, build/CI reality |
| [`docs/pathway-c.md`](docs/pathway-c.md) | Host strategy (JVM vs native Swift), renderer mapping, risk register, prior art |
| [`docs/roadmap.md`](docs/roadmap.md) | Gate-gated plan G0–G6 with exit criteria and fallback decision points |
| [`docs/ci-qa.md`](docs/ci-qa.md) | CI/QA plan: inherited test corpus, CI tiers, golden fixtures, runner strategy |
| [`docs/pathway-a.md`](docs/pathway-a.md) | WinTAK golden VM: build record, FreeTAKServer round-trip verification, gotchas |
| [`docs/atak-feature-coverage.md`](docs/atak-feature-coverage.md) | ATAK-CIV's feature set mapped to what macTAK supports today, and the app-layer decision (rewrite in Swift) |
| [`docs/rebase-study-5.5.md`](docs/rebase-study-5.5.md) | Measured cost of moving the upstream baseline from 4.6.0.5 to 5.5.1.10; the staged rebase plan |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Contributor guide: setup, the gate ladder, where changes land (patches/shadows/shim), CI contract, house style |
| [`CHANGELOG.md`](CHANGELOG.md) | Release history by gate — 0.1.0 G0 engine builds, 0.2.0 G1 headless + CoT, 0.3.0 G2 map renders, 0.3.1 window surfaces + hardening |

## Local gates

Run `make hooks` once per clone to install the git hooks (`core.hooksPath .githooks`). The pre-commit hook then checks every staged file: `shellcheck` + `bash -n` on `*.sh`, `markdownlint-cli2` on `*.md`, `actionlint` on `.github/workflows/*.yml`, and SHA256 verification of jars under `dev/g1/transplants/` and `dev/spike/g0/transplants/` against their `SHA256SUMS` manifests. Optional tools that are not installed are skipped with a visible message. `make lint` runs the same checks across the whole `dev/` tree, sweeping the repo's own docs but skipping the read-only `src/` pin — CI's docs job likewise lints only PR-changed `*.md`.

## License

GPL-3.0 — see [LICENSE](LICENSE). macTAK inherits the GNU GPL v3 obligation from upstream `deptofdefense/AndroidTacticalAssaultKit-CIV`.

This is an independent open-source project — not an official TAK product and not affiliated with the US Federal Government, the US Department of War, nor any other agent thereof.

(c) 2026 macTAK contributors.
