# CI & QA Infrastructure Plan (GitHub)

Companion to `feasibility-report.md` (verdict), `architecture.md` (evidence), `pathway-c.md` (design/risks), `roadmap.md` (gates). Everything factual is pinned to clone `src/` @ `889eee2` (v4.6.0.5). Decided before G0 so that Tier 1 exists the day the port repo does.

## 1. What CI must prove

The port's correctness contract has three axes; each needs a different vehicle:

| Contract | Question | Vehicle |
|---|---|---|
| Engine parity | Does the C++/JVM engine behave identically on macOS arm64? | Native C++ engine tests + JVM tests on every push |
| Protocol parity | Do we speak CoT/takproto/takcot like ATAK/WinTAK do? | Golden-fixture replay (PR) + live FreeTAKServer round-trip (nightly) |
| UX parity | Does the client behave like ATAK-CIV/WinTAK? | Render goldens, perf budgets, per-rung parity checklists |

**Anchor fact:** upstream's own workflows (`../src/.github/workflows/assemble-sdk.yml`, `release-sdk.yml` @ `889eee2`) are **build-only** — `ubuntu-latest` + OpenJDK 8 container, Android SDK/NDK r12b, CMake 3.14.7, Conan 1.59, git-lfs; they assemble the SDK APK and upload it, running **zero tests**. Our CI exceeds upstream at the first commit.

## 2. Inherited test corpus (verified @ `889eee2`)

61 test files, two kinds:

- **Native C++ engine tests** — `takkernel/engine/src/test/cpp/`: `TakEngineTests.cpp`, `TaskingTests.cpp`, `URIOfflineCacheTests.cpp` plus a resources/logging harness. Platform-neutral by construction: they build wherever CMake does, i.e. directly on the macOS engine build. This is the R1 canary (pathway-c.md §5) — the first thing G0's CI job runs.
- **JVM unit tests** — `takkernel/shared/src/test` and `takkernel/port/src/test` (JUnit 4.12 per `gradle/versions.gradle`; AssertJ in `shared/build.gradle`): `gov.tak.platform.*` — contacts, widget config, marshal, binding, util. The `port` module is the platform-abstraction layer — exactly where macOS-port behavior tests accumulate.

Caveat: upstream runs no tests and the corpus is modest — the harness (§6) matters more than usual, because we cannot lean on upstream test culture.

## 3. Runner strategy & licensing constraints

| Constraint | Consequence |
|---|---|
| Port repo stays public (GPL-3.0, R6: publishing is the plan) | GitHub-hosted `macos-14` (arm64) runners are free for public repos — no 10× macOS-minute tax |
| WinTAK is closed GOTS | Never on hosted CI — self-hosted only (§5); never committed, never cached |
| TAK Server requires a registered download | Self-hosted env only; FreeTAKServer (open) stands in for per-push/nightly runs |
| MrSID & other restricted distfiles | Never uploaded to hosted caches; stub raster drivers per the G0 plan |
| Real imagery / CoT captures can be sensitive | All baselines **synthetic** — generated map packages, canned CoT; nothing operationally real in the repo |

## 4. CI tiers

| Tier | Trigger | Jobs | Runner | Lands |
|---|---|---|---|---|
| **0 — docs** | PR/push | markdownlint; lychee link-check (tak.gov allowlisted — fetches blocked) | ubuntu hosted | now |
| **1 — PR gate** | every push, <15 min target | `jvm-tests` (macos-14 **+** ubuntu-24.04 matrix; Gradle cache); `native-engine` (CMake `elseif(APPLE)` build **and run** the C++ tests; sccache); `lint` (clang-format/swiftlint) | hosted | with G0 |
| **2 — nightly** | schedule + `workflow_dispatch` | `engine-integration` (headless engine ↔ FreeTAKServer container — the G1 exit criteria, automated); `render-goldens` (offscreen ANGLE/EGL → PNG → thresholded pixel-diff; refreshed via `/update-goldens` label); `perf-budgets` (frame-time harness, 7-day rolling baseline, fail only >20% regression); `pathway-a-baseline` (weekly, self-hosted WinTAK capture) | hosted + self-hosted | with G1/G2 |
| **3 — release** | tag | xcodebuild archive → `notarytool` (App Store Connect API key in secrets) → staple → GH Release; GPL compliance job (source archive + license manifest attached to every artifact) | hosted | with G5 |

Branch protection: Tier 1 statuses required to merge. During the spike itself `native-engine` is expected red — and that red is R1's scored signal, not an accident.

## 5. Self-hosted pattern — VMPal golden VMs

The dev Mac also hosts the CI jobs that licensing forces there. VMPal's CI model maps onto GitHub Actions directly:

- **Golden VMs**, prepared once, kept shut down: a Windows VM with WinTAK installed (VMPal signs clones in automatically with its kept password), optionally an Ubuntu VM for FTS soak tests. Each job **clones** the golden (copy-on-write disk share — cheap), runs in the clone, deletes the clone. **First golden exists (2026-11-01):** `wintak-baseline` — Windows 11 24H2 ARM64 + WinTAK-CIV 5.8.0.149, Direct3D 12 off (WinTAK exits silently with it on), snapshot `golden-wintak`; build record and gotchas in `pathway-a.md`. **Extended 2026-11-02:** stacked snapshot `golden-wintak-fts` (id `2588E027-5008-4289-8249-385638E9E80F`) bakes the FreeTAKServer connection into WinTAK's `Config.xml`, so a resumed clone auto-connects. The FTS side is Mac-side, not in the VM: VMPal Containers runs `vigsecdrone/freetakserver:latest` (`network: host`), and VMPal publishes container ports on `127.0.0.1` only — the weekly `pathway-a-baseline` job's wiring is two `../dev/reference/tools/cot-proxy.py` instances bridging the Mac's LAN address into localhost (`pathway-a.md` §FTS round-trip).
- **Runner:** GitHub's self-hosted runner as the user's LaunchAgent, labeled `runs-on: [self-hosted, macOS, ARM64]`; job steps shell out to `vmpal run "Golden WinTAK" --copy-in .:src --copy-out out:./out -- …`; the command's exit status is the job status; upload `out/` with `if: always()`.
- **Limits:** at most two macOS VMs concurrently on one Mac (memory/CPUs permitting); keep the Mac from sleeping.
- **Policy:** self-hosted jobs never gate PRs — a dev Mac must not block merges. Nightly/weekly/manual dispatch only.

## 6. QA harness beyond CI

1. **Golden CoT fixtures** — capture one real ATAK↔FTS session, convert to replayable fixtures; every comms change re-validates deterministically in PR CI with no live server needed. Vehicle proven 2026-11-02: a witnessed WinTAK↔FTS CoT session was captured at the protocol layer (`pathway-a.md` §FTS round-trip) with the committed `../dev/reference/tools/` (`cot-listen.py`, `inject-marker.py`); fixture conversion builds on this.
2. **Render goldens** — synthetic scenes only (§3); thresholded pixel-diff; goldens stored in LFS; refreshed **only** via the `/update-goldens` label workflow so drift is deliberate.
3. **Perf budgets** — reference-scene frame-time distribution vs a 7-day rolling baseline; fail only on >20% regression. CI must not be noise.
4. **Parity checklists** — every G6 rung gets a parity spec: automated where possible (protocol fixtures, behavior scripts), manual screenshot comparison vs the Pathway A baseline (WinTAK VM) where not.
5. **Flaky policy** — JUnit XML → test reporter on every run; retry-once; flake twice → quarantine label **with a fix issue**. Quarantine without a ticket is how suites rot.

## 7. Phasing (gate-mapped)

- **Now:** Tier 0 on this research repo.
- **G0:** scaffold Tier 1 in the port repo + a `workflow_dispatch` `g0-spike.yml` — a failed run is still R1 signal.
- **G1:** `engine-integration` + golden CoT fixtures.
- **G2:** `render-goldens` + `perf-budgets` (goldens come from whichever host wins H1/H2).
- **G5:** release pipeline + GPL compliance job.
- **G6:** parity automation grows rung by rung.

## 8. Deliberate non-goals (early)

- **No Android emulator in hosted CI** initially — the flakiest thing in mobile CI; JVM-level parity tests first; revisit when the Android oracle suite is formalized (G3+).
- **No TAK Server / device farm in hosted CI** — licensing (§3).
- **No self-hosted runner gating PRs** — bounded blast radius when the dev Mac sleeps.

## 9. Manual dispatch surface

`ci.yml` and `docs.yml` support `workflow_dispatch` so PRs whose paths filters skip a workflow (docs-only PRs skip CI; PRs with no docs changes skip Docs) can fill the required checks. Dispatch runs are maintainer-initiated and not attacker-triggerable, but are unaudited by the paths rules — treat any dispatch run on an unreviewed ref as unverified.
