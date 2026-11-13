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
| [dev/spike/g55/NOTES.md](dev/spike/g55/NOTES.md) | How the baseline moved from 4.6 to 5.5: the patch port, each step, traps, and where every piece now lives |
| [dev/g1/NOTES.md](dev/g1/NOTES.md) · [dev/g2/NOTES.md](dev/g2/NOTES.md) | Engineering notes: how each milestone actually went — traps, gate logs, guards |

## Setup

macOS arm64; Homebrew for the native dependency sets:

```bash
brew bundle install              # Brewfile = the union of every workflow's brew installs
make hooks                       # install the pre-commit gate (core.hooksPath .githooks)
```

- **JDK 21 (arm64)** for all JVM work: every JVM macTAK starts (canaries,
  `atak-headless`, the render harness, `jni-tests`, the shell's in-process
  `JNI_CreateJavaVM`), the `javac` for macTAK's own Java (`--release 21`)
  and the takkernel Gradle build (8.13). `brew install --cask zulu@21`;
  any JDK 21 arm64 works. `dev/jdk.sh` finds it and checks its version;
  `MACTAK_JDK21_HOME` picks a specific one.
- **`src/` is populated by you, never committed** (gitignored): the
  read-only upstream pin is `TAK-Product-Center/atak-civ` @
  `9f6893dd657feacc35ec5de03dad721c2e44170e` (5.5.1.10), a sparse checkout
  plus one Git LFS file — the same paths CI's engine jobs check out:

  ```bash
  git clone --filter=blob:none --no-checkout https://github.com/TAK-Product-Center/atak-civ src
  git -C src sparse-checkout set takkernel commoncommo takcot takproto khronos \
      takengine/thirdparty/tinygltfloader depends
  GIT_LFS_SKIP_SMUDGE=1 git -C src checkout 9f6893dd657feacc35ec5de03dad721c2e44170e
  git -C src lfs pull --include=depends/tinygltf-2.4.1-mod.tar.gz
  ```

  CI's ref and this pin are kept in sync (`ci.yml`, `cot-roundtrip.yml`).
  The 4.6 baseline (`deptofdefense/AndroidTacticalAssaultKit-CIV` @
  `889eee2`) ended at the re-pin; `dev/spike/g55/NOTES.md` records the move.

First build is the long one (~470 translation units): `make build` (kernel
jars from `src/`, engine, comms), then `make angle` (stages the SHA256-pinned
ANGLE pair, writes `PROVENANCE.txt`, runs the pbuffer smoke) and
`make build-angle` (rebuilds with `MACTAK_GLES=angle`).

## The gate ladder

Every milestone lands through `make` targets that fail loudly on the ways a
test can lie: sentinel pixels in readbacks, a 0-byte artifact, stale
post-teardown GL errors, a frame count that lies about elapsed time. If a
gate passes, the artifact was really produced this run.

| Target | What it proves | Runs where |
|---|---|---|
| `make build` | the kernel jars build from `src/`; engine + comms compile and link; the engine C++ tests, JNI tests and load canaries pass | CI + local |
| `make test-kernel` | takkernel's own `:port` and `:shared` unit tests on Gradle 8.13, minus what needs the TAK artifactory (`dev/g1/kernel/kernel-tests.gradle`) | CI (JVM job) + local |
| `make test-roundtrip` | CoT in/out, hermetically: two headless clients vs `dev/g1/headless/fake-cot-server.py` (no external TAK server) | CI (on `dev/g1/**` changes) + local |
| `make test-jni` | the wave-5/6 JNI guards and the Java-backed `IOProviderFactory` proxy on a real desktop JVM: guards 7 pins (neutral bailouts, clean `JNI_OnLoad` failure) + kernel 6 pins (real files through the proxy) | CI (native job) + local; skips (exit 0) when no JDK 21 is installed |
| `make test-quic` | commo streams over QUIC (ngtcp2's `ossl` backend) to a hash-pinned aioquic stand-in, refuses a clientAuth-only impostor certificate, and logs a failed handshake's cause (`ECONNREFUSED` from a closed port) | CI (comms job) + local |
| `make test-gdal-network` | opening a hostile layer file (an OGR VRT or GML that names a URL) makes no network request: stock `ogrinfo` fetches as the control, the engine's import path must not | CI (native-engine job) and local; needs an engine build |
| `make test-render` | a GeoJSON layer over MBTiles renders through the engine into an EGL pbuffer, zero GL errors, every `asset:` icon resolved, PNG artifact; a GeoTIFF draws through GDAL with the right colour over known ground points; GeoTIFF and DTED elevation read back the right heights and draw as terrain; the gesture canary lands every Apple Maps gesture where it belongs on screen | CI + local |
| `make test-render-resize` / `test-render-window` | the window surface survives mid-run `drawableSize` changes | CI + local |
| `make check-gen-gles-shim` | committed GLES shim matches its generator's output | CI + local |
| `make build-shell` | the Swift/C shell compiles | CI + local |
| `make docs-site` | the docs site builds in MkDocs strict mode: every link and anchor between the documents resolves | CI (`docs-site.yml`) + local |
| `make exit-run` | G2's exit run: real imagery, vector and terrain in the shell's window under a 10 s gesture tour; zero dropped frames, no GL error (through ANGLE's debug output); fps, GPU time, GC pauses, memory and cold start reported | **dev Mac only** — a GUI session, and the network once to fetch the real data |
| `make test-app` | the Swift package at `app/` builds every product, and `swift test` passes | CI (shell job) and local |
| `make test-app-comms` | the package with its comms targets, built against `dev/g1/build-commo.sh`'s commo; two `CommoClient`s through `fake-cot-server.py` see each other | CI (comms job) and local; needs a built commo and `src/` |
| `make app` | builds `build/MacTAK.app`, the SwiftUI app around the map; open it to check by hand | **dev Mac only**: the bundle carries this Mac's engine build |
| `make smoke-window` / `make test-shell` | a real window opens and presents frames; `test-shell`'s live leg keeps it rendering through a scripted pan and resize (Retina, frame times logged), and its gestures leg drives the camera with real input events through AppKit | **dev Mac only** — needs a GUI session; CI runners have no WindowServer, so CI compiles the shell but the last mile of every window milestone is a local gate |

Run the affected gates before pushing; CI will re-run the ones it can.

## Non-negotiables

- **License:** the repo inherits GPL-3.0 from upstream ATAK-CIV
  (`TAK-Product-Center/atak-civ`, formerly
  `deptofdefense/AndroidTacticalAssaultKit-CIV`); contributions are licensed
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
  job on every PR), and an unlisted jar fails it. The takkernel jars are
  not committed: CI and `make build` build them from the pinned `src/`.
  External downloads are SHA256-pinned: ANGLE (`dev/g2/fetch-angle.sh`,
  which writes `PROVENANCE.txt`), ngtcp2 (`dev/g1/fetch-ngtcp2.sh`) and
  aioquic with its dependencies (`--require-hashes`,
  `dev/g1/headless/test/requirements-quic.txt`), and MkDocs for the docs
  site (`--require-hashes`, `dev/docs-site/requirements-docs.txt`).

## Where changes land

| You're changing | It goes in | Enforced by |
|---|---|---|
| Engine C++ behavior | `dev/g1/patches/*.patch` — one focused patch per fix, with the why in comments at the patch site | patches are the only path; `build-native.sh` applies them at `--fuzz=0` and fails on any hunk that does not |
| Engine Java classes (render path) | a Java hunk in `dev/g1/patches/*.patch`, nothing else: `dev/g2/render/env.sh` regenerates the shadowed class from `src/` + the hunk on each compile | the hunk must apply at `--fuzz=0` or the render build fails; there is no committed copy to drift |
| A newer upstream baseline | the record `dev/spike/g55/NOTES.md` describes; `dev/spike/g55/refresh-patches.py` sorts `dev/g1/patches` against the new tree | the full gate ladder on the new tree |
| The GLES shim (`android.opengl.GLES20/30` + JNI forwarder) | the generator `dev/g2/gen-gles-shim.py`, then `make gen-gles-shim` and commit the output | `check-gen-gles-shim` fails on hand-edited output ("a miss is loud, not silent") |
| The Swift app and the G2 harness (G3) | `app/` (a Swift package: `CJavaBoot`, `MacTAKCore`, `mactak-shell`, `MacTAK`, and with commo `CCommoShim` and `MacTAKComms`); the Java side Swift calls is `dev/g2/render/src/mactak/engine/` | `make test-app` (CI): every product builds, and drift tests keep the JNI boundary in step; `make test-app-comms` (CI) for the comms targets |
| Render harness and headless tools | `dev/g2/shell/` (scripts and gates), `dev/g2/render/`, `dev/g1/headless/` | `shellcheck -x` + `bash -n` via hook and `make lint` |
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
| `ci.yml` | push / pull_request on `main` | the gate ladder above — native engine, ANGLE render + GLES-shim drift gate, shell compile, comms stack + QUIC, JVM tests (kernel jars, JNI-header drift, `test-kernel`, canaries), lint |
| `cot-roundtrip.yml` | PRs / pushes touching `dev/g1/**` | hermetic CoT round-trip gate |
| `docs.yml` | **every PR targeting `main`** (unconditionally, so the required check always reports) | markdownlint + lychee link check on changed `*.md` |
| `docs-site.yml` | PRs / pushes touching `*.md` or `dev/docs-site/` | builds the docs site (strict); on `main`, deploys it to GitHub Pages |
| `supply-chain.yml` | Brewfile or any workflow changes | the Brewfile equals every workflow's brew installs; `brew bundle check` against the committed `Brewfile.lock.json`; osv-scanner |
| `ots-profile-drift.yml` | nightly; PRs touching the checker or its fixture | the pinned OpenTAKServer cert profiles still match upstream (not a PR gate) |

Two consequences worth knowing before your first PR:

- `ci.yml`'s required checks exist only for PRs **targeting `main`**. When
  you stack a branch on an unmerged branch (base isn't `main` yet), validate
  mid-flight with the workflow's `workflow_dispatch` on your branch tip; the
  design and its rationale are recorded in `dev/g2/NOTES.md` ("Gates and
  provenance").
- The link check resolves relative links between docs — keep them working
  when you move files.

## Moving the upstream baseline

The baseline moved from 4.6 (`889eee2`) to 5.5.1.10 (`9f6893d`) on
2026-11-11, in stages, through a spike under `dev/spike/g55/` that ran
beside the 4.6 build until the re-pin
([docs/rebase-study-5.5.md](docs/rebase-study-5.5.md),
[dev/spike/g55/NOTES.md](dev/spike/g55/NOTES.md)). A later bump follows
that pattern: `refresh-patches.py` sorts `dev/g1/patches` against the new
tree, the work runs beside the shipping build until a re-pin, a G1/G2
script is reused through an opt-in `MACTAK_*` override rather than a copy
(unset, nothing changes; documented in the script's header), jars build
in CI from the pinned commit, and the spike keeps its own NOTES and trap
lineage until the re-pin.

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
