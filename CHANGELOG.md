# Changelog

All notable changes to macTAK. Versions follow the roadmap gates
([docs/roadmap.md](docs/roadmap.md)): each completed gate bumps the minor
version — 0.1.0 G0, 0.2.0 G1, 0.3.0 G2 — and dates are the merge dates.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- `make smoke-window` (M3.0): the G2 window-surface gate — an NSWindow
  with a live `CAMetalLayer` becomes an ANGLE EGL window surface
  (`eglCreateWindowSurface`, Metal platform), draws a GL ES 3.0
  triangle, reads back centre/corner pixels into an exact-size P6 PPM
  artifact, and presents for 3 s (~30 fps). CI compiles it
  (`--compile-only`); the live run is manual on a GUI Mac. It fails
  instead of lying: unwritable/empty artifact (#39), nil Metal device
  exits 2 (#42), judging before EGL teardown so FAILs report live
  diagnostics (#38), 0 presented frames is a FAIL regardless of cause
  (#40 — decided strictest over log-only and hybrid options), unknown
  flags get a usage line (#37), and the present loop logs its measured
  duration (#41).

- `atak-headless --datapackage FILE` resolves an ATAK data package instead of
  hand-feeding flags: CoT host:port from `preference.pref`'s `cot_streams`,
  the callsign, and the PKCS#12 pair extracted to a temp dir — explicit
  flags still win, `MACTAK_CERT_PASS` overrides the package's password, and
  failures exit 2. Pure-JDK importer hardened against XXE, Zip-Slip and
  oversize entries (#31: 16 MiB for `preference.pref`, 64 MiB per PKCS#12,
  refused with the byte count); the address line takes a bracketed IPv6
  literal (stored unbracketed), range-checks the port to 1–65535 on the
  package and `--connect` paths alike, matches the proto token exactly
  (`ssl`/`tls`/`tcp` — `dtls` is refused, not mislabeled ssl), and refuses
  a client/truststore pair sharing one basename (#32); the canary
  (`test/datapackage.sh`) runs in the `jvm-tests` CI job, which now also
  compile-gates `HeadlessCLI.java` itself (#29 — CI previously never
  type-checked the launcher).

### Fixed

- The `--datapackage` cert temp dir is deleted on every exit, not just on
  the success path — a failed run no longer leaks extracted PKCS#12s in
  `$TMPDIR` (#27); the selftest cleans its `dpselftest-*` dirs too (#30).
- The canary's openssl recipe runs on bare macOS LibreSSL
  (`/usr/bin/openssl`), so the fixture builds without Homebrew OpenSSL (#28).
- Engine patch `megatexture-sharetile-comma-operator.patch`:
  `GLMegaTexture::shareTile` wrote `other,shareWith = this;` — the comma
  operator set `this->shareWith = this`, so every share after the first
  returned `TE_IllegalState`. `shareTile` has no callers at the pin
  (front/back swaps use `transferTile`), so G2.4 was never gated on it.

## [0.3.0] - 2026-11-05 — G2: map renders (ANGLE on Metal)

### Added

- ANGLE (EGL 1.5 / ES 3.0 on Metal) occupies the engine's GLES slot: the
  engine renders from the JVM into an EGL pbuffer with zero GL errors
  (#17), gated by a pure-C canary (`smoke/egl-triangle.c`) that exercises
  Metal-platform → pbuffer → draw → readback independent of the engine.
- First map content: a GeoJSON `FeatureLayer` (polygons, lines, labels)
  renders through the engine on ANGLE (#18).
- Offline basemap: an MBTiles raster fixture (generated offline by the
  `gdal` CLI) renders under the vector layer (#18).
- Render smoke harness with PNG artifacts; `make build-angle` and
  `make test-render` gate it locally and in CI (#17, #18).
- `gen-gles-shim.py` emits a full-coverage GLES no-op stub
  (`mactak_gles_stub.c`), so stub-mode CI builds link again (#18);
  `make gen-gles-shim` + a CI drift gate keep the generated artifacts
  honest (#22).

### Changed

- The render smoke waits for content pixels — it polls the GL readback
  and keeps rendering until content appears (capped at 5× settle /
  min 15 s) instead of trusting a fixed wall-clock floor (#23).
- GLES shim cache evicts programs on `glDeleteProgram`, and debug paths
  get `FindClass` null-checks; `MACTAK_GL_DEBUG=2` dumps the Java stack
  next to the native backtrace (#22).
- The layer canary reports on every CI run (#17).

### Fixed

- `GLMegaTexture::release()/clear()` erase-while-iterating SIGSEGV under
  CI (#17).
- The ANGLE staging download retries release-CDN 504s: a mid-transfer
  drop (curl 56) is outside curl's default transient set, so
  `fetch-angle.sh` downloads with
  `--retry 5 --retry-delay 5 --retry-all-errors --retry-max-time 600`
  (#23).

## [0.2.0] - 2026-11-04 — G1: headless engine + CoT round-trip

### Added

- Deterministic native engine build plus a C++ test canary (G1.0), with
  the working tree consolidated under `dev/`.
- In-process engine load from a Zulu 8 arm64 JVM via JNI glue and a load
  smoke (#1).
- `atak-headless --connect HOST:PORT`: commoncommo stack headless; CoT
  round-trip verified against FreeTAKServer and OpenTAKServer
  (two clients, marker + presence relayed both ways) (#3).
- `atak-headless --layer FILE`: GeoJSON/GPKG/KML/SHP open through the
  native OGR provider into `PersistentDataSourceFeatureDataStore2` and
  read back — the offline-layer criterion, with a four-format canary in
  CI (#4).
- Track persistence: one JVM loads engine + comms together; received CoT
  persists through the engine's `DatabaseImpl` JNI into a sqlite tracks
  DB (`--db`), and the latest fix per uid prints on exit — witnessed on
  OpenTAKServer over TCP and SSL (certs from an ATAK data package) and
  hermetically in CI (#15).
- `fake-cot-server`: a CoT relay for local testing (buffers partial
  lines, relays bytes verbatim, relays client lines to other clients).
- Local dev gates: pre-commit hook chain (shellcheck, markdownlint,
  actionlint, jar SHA256 manifests) plus a Makefile (#5).
- Supply-chain automation: dependabot, Brewfile lock + osv-scanner job
  (#5).

### CI

- Tier 0/1 on GitHub Actions: docs lint, native-engine PR gate, JVM
  tests, shell/workflow lint (landed 2026-11-02; runners pinned to
  `macos-26`).
- CoT round-trip wired into CI — a run with empty artifacts fails
  (exit 4); `fake-cot-server` covers the hermetic leg (#5).
- Every PR reports — docs-only changes run no-op lint guards instead of
  leaving checks pending (#12, #14).

## [0.1.0] - 2026-11-02 — G0: engine builds on macOS arm64

### Added

- Founding feasibility report set (ATAK-CIV 4.6.0.5 evidence) and the
  program documents: architecture, Pathway C host strategy, gate-gated
  roadmap, CI/QA plan.
- Pathway A baseline: a WinTAK golden VM with a verified FreeTAKServer
  round-trip — the reference behavior for the port.
- `libtakengine.dylib` compiles and links on macOS arm64 (~460
  translation units), all five takkernel Java modules publish to
  mavenLocal on Zulu 8, and a `dlopen` smoke passes.
- CI Tier 0 seed: docs lint + shell/workflow lint.

### Changed

- Licensed under GPL-3; LAN IPs scrubbed from evidence; renamed macTAK.
