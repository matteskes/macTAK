# Contributing to macTAK

macTAK ports the TAK geospatial stack (the takkernel engine + commoncommo
comms) to native macOS — see [README.md](README.md) for what that means and
where the port stands. Work is organized as gates (G0–G6) containing
milestones (M-numbers), per [docs/roadmap.md](docs/roadmap.md); a milestone
isn't done until its exit criteria run as `make` targets and pass. This guide
covers setup, where changes land, the CI contract, and the house style that
keeps this repo's documentation honest.

## Reading order

Read these before the first PR — each one is short and everything later
assumes them:

| Doc | Why |
|---|---|
| [README.md](README.md) | What macTAK is, feature status mapped to gate criteria, repo layout |
| [docs/feasibility-report.md](docs/feasibility-report.md) | The measured numbers behind the port strategy |
| [docs/architecture.md](docs/architecture.md) | Verified upstream layout, LOC inventory, dependency graph |
| [docs/pathway-c.md](docs/pathway-c.md) | Host strategy (JVM vs native Swift), renderer mapping, risk register |
| [docs/roadmap.md](docs/roadmap.md) | The gate-gated plan with exit criteria and fallback decision points |
| [docs/ci-qa.md](docs/ci-qa.md) | CI tiers, runner strategy, as-landed state |
| [docs/atak-feature-coverage.md](docs/atak-feature-coverage.md) | ATAK's feature set mapped to what macTAK supports today |
| [docs/rebase-study-5.5.md](docs/rebase-study-5.5.md) | Measured cost of moving the upstream baseline from 4.6 to 5.5 |
| [dev/g1/NOTES.md](dev/g1/NOTES.md) · [dev/g2/NOTES.md](dev/g2/NOTES.md) | Engineering notes: how each milestone actually went — traps, gate logs, guards |

## Setup

macOS arm64; Homebrew for the native dependency sets:

```bash
brew bundle install              # Brewfile = the union of every workflow's brew installs
make hooks                       # install the pre-commit gate (core.hooksPath .githooks)
```

- **Zulu 8 (arm64)** on `PATH` for all JVM work — the engine modules publish
  to mavenLocal and `JNI_CreateJavaVM` boots it in-process for the shell.
  CI pins its own copy; any Zulu 8 arm64 build works locally.
- **`src/` is populated by you, never committed** (gitignored): the read-only
  upstream pin is `deptofdefense/AndroidTacticalAssaultKit-CIV` @
  `889eee292c43d3d2eafdd1f2fbf378ad5cd89ecc` (v4.6.0.5, recursive submodules).
  Clone it, check out that commit, `submodule update --init --recursive` into
  `./src` — this mirrors CI's checkout step exactly. CI's ref and this pin
  are kept in sync via `docs/ci-qa.md`.

First build is the long one (~460 translation units): `make build` (engine +
comms), then `make angle` (stages the SHA256-pinned ANGLE pair, writes
`PROVENANCE.txt`, runs the pbuffer smoke) and `make build-angle` (rebuilds
with `MACTAK_GLES=angle`).

## The gate ladder

Every milestone lands through `make` targets that fail loudly on the ways a
test can lie: sentinel pixels in readbacks, a 0-byte artifact, stale
post-teardown GL errors, a frame count that lies about elapsed time. If a
gate passes, the artifact was really produced this run.

| Target | What it proves | Runs where |
|---|---|---|
| `make build` | engine + comms compile and link | CI + local |
| `make test-roundtrip` | CoT in/out, hermetically: two headless clients vs `dev/g1/headless/fake-cot-server.py` (no external TAK server) | CI (on `dev/g1/**` changes) + local |
| `make test-jni` | the wave-5/6 JNI guards and the Java-backed `IOProviderFactory` proxy on a real desktop JVM: guards 7 pins (neutral bailouts, clean `JNI_OnLoad` failure) + kernel 6 pins (real files through the proxy) | CI (native job, Zulu 8) + local; skips (exit 0) when no JDK 8 is installed |
| `make test-render` | a GeoJSON layer over MBTiles renders through the engine into an EGL pbuffer, zero GL errors, PNG artifact | CI + local |
| `make test-render-resize` / `test-render-window` | the window surface survives mid-run `drawableSize` changes | CI + local |
| `make check-gen-gles-shim` | committed GLES shim matches its generator's output | CI + local |
| `make check-engine-shadows` | every Java shadow equals upstream + its patch, byte for byte | CI + local (needs `src/`) |
| `make build-shell` | the Swift/C shell compiles | CI + local |
| `make smoke-window` / `make test-shell` | a real window opens and presents frames | **dev Mac only** — needs a GUI session; CI runners have no WindowServer, so CI compiles the shell but the last mile of every window milestone is a local gate |

Run the affected gates before pushing; CI will re-run the ones it can.

## Non-negotiables

- **License:** the repo inherits GPL-3.0 from upstream
  `deptofdefense/AndroidTacticalAssaultKit-CIV`; contributions are licensed
  GPL-3.0. macTAK is an independent open-source project — not an official TAK
  product and not affiliated with the US Government.
- **`src/` is read-only, always.** Engine changes are exported as patch files
  under `dev/g1/patches/` (applied with `patch -p3` into the engine work tree
  by the build scripts) — never edited in place, never committed there.
- **GOTS artifacts never enter the repo.** WinTAK-derived captures and any
  government-off-the-shelf material stay gitignored (e.g. under
  `dev/reference/`).
- **Binaries carry proof.** Jars are committed only under `transplants/` with
  a `SHA256SUMS` manifest that lists every jar; `dev/check-transplants.sh`
  verifies them (pre-commit hook, `make check-transplants`, and CI's lint
  job on every PR), and an unlisted jar fails it. External
  downloads (ANGLE) are SHA256-pinned in `dev/g2/fetch-angle.sh`, which
  writes `PROVENANCE.txt`.

## Where changes land

| You're changing | It goes in | Enforced by |
|---|---|---|
| Engine C++ behavior | `dev/g1/patches/*.patch` — one focused patch per fix, with the why in comments at the patch site | patches are the only path; `check-engine-shadows` re-applies them |
| Engine Java classes (render path) | `dev/g2/render/engine-shadows/<class>` + its `.patch` twin under `dev/g1/patches/` | `check-engine-shadows`: shadow must equal upstream + patch, byte for byte |
| The GLES shim (`android.opengl.GLES20/30` + JNI forwarder) | the generator `dev/g2/gen-gles-shim.py`, then `make gen-gles-shim` and commit the output | `check-gen-gles-shim` fails on hand-edited output ("a miss is loud, not silent") |
| Native host (Swift/C), render harness, headless tools | `dev/g2/shell/`, `dev/g2/render/`, `dev/g1/headless/` | `shellcheck -x` + `bash -n` via hook and `make lint` |
| Docs | the doc itself + `CHANGELOG.md` under **Unreleased** | `docs.yml` (markdownlint + link check) |

## Branches, commits, pull requests

- **Branches** `<area>/<kebab-topic>` — e.g. `g2/m32-shell`,
  `g1/wave5-jni-bridge-hygiene`, `docs/release-0.3.1`, `chore/lint-exclude-src`.
- **Commit subjects** `<area>: <topic> — <summary>` (imperative), areas
  matching top-level layout — e.g. `g2: m3.2 — the Swift/AppKit shell boots
  the JVM and hosts the window`, `docs: cut 0.3.1 — window surfaces (M3.0–M3.1)`.
- **PRs target `main`.** Merges are merge commits (history keeps PR shape),
  and the branch is deleted after merge.
- **CHANGELOG.md** accumulates under **Unreleased** per PR — Keep a Changelog
  1.1.0 format, entries citing trap numbers and patch filenames. Versions
  bump at gate completions (0.1.0 G0 → 0.2.0 G1 → 0.3.0 G2, patch releases
  for hardening waves) and release cuts happen in a follow-up `docs:` PR that
  also adds the roadmap's dated milestone paragraph.
- **[docs/roadmap.md](docs/roadmap.md)** gets a dated paragraph once a
  milestone merges; only the newest milestone carries the shrunk "remains"
  list — older milestones fold theirs forward.

## What CI runs, and when

| Workflow | Triggers | Jobs |
|---|---|---|
| `ci.yml` | push / pull_request on `main` | the gate ladder above — native engine, ANGLE render + drift gates, shell compile, comms stack, JVM tests, lint |
| `cot-roundtrip.yml` | PRs / pushes touching `dev/g1/**` | hermetic CoT round-trip gate |
| `docs.yml` | **every PR targeting `main`** (unconditionally, so the required check always reports) | markdownlint + lychee link check on changed `*.md` |
| `supply-chain.yml` | Brewfile changes | `brew bundle check` against the committed `Brewfile.lock.json` |

Two consequences worth knowing before your first PR:

- `ci.yml`'s required checks exist only for PRs **targeting `main`**. When
  you stack a branch on an unmerged branch (base isn't `main` yet), validate
  mid-flight with the workflow's `workflow_dispatch` on your branch tip; the
  design and its rationale are recorded in `dev/g2/NOTES.md` ("Gates and
  provenance").
- The link check resolves relative links between docs — keep them working
  when you move files.

## House style — NOTES, traps, CHANGELOG

The documentation culture is the repo's main asset; PRs extend it:

- Each gate lineage keeps a dated `NOTES.md` with State-first sections
  (newest milestone at top) and gate results that **quote the real log
  lines** — a claim without an artifact behind it doesn't land.
- **Traps** live in "Traps found on the way (do not rediscover these)"
  tables; numbering **continues within the lineage** (G2's tables pick up
  where earlier G2 sections left off). Each entry states what bit you **and
  what now guards it** — a trap without a guard isn't closed. If it turns
  out benign, it moves to the known-benign noise list, kept separate from
  failure signatures and struck through when actually fixed.
- Debug prints and scratch diagnostics don't survive to merge — they're
  trimmed in their own follow-up PR (the shell's `shouldTerminate` poll
  print, G2 M3.2) or never committed.
- `CHANGELOG.md` stays honest: dates are merge dates, every entry says which
  patch or trap it corresponds to.

## License

GPL-3.0 — see [LICENSE](LICENSE). By contributing you agree your
contributions are licensed under the same license inherited from upstream
ATAK-CIV.
