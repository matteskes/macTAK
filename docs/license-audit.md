# License audit

**Date:** 2026-11-16 · **Auditor:** macTAK maintainers · **Status:**
complete; one item open (F2)

macTAK is GPL-3.0 (inherited from upstream ATAK-CIV), and the app bundle
it builds (`app/bundle.sh`) redistributes 134 native libraries and 50
jars from dozens of upstreams. This audit enumerated every one, resolved
its license against ground truth (the artifacts themselves, Homebrew's
SPDX metadata, the projects' own files — never guesswork), recorded the
set in [`licenses/inventory.csv`](../licenses/inventory.csv), and put
machinery in place so the record cannot silently rot. Findings F1–F8 from
the audit plan are dispositioned below.

## Method and evidence

- **The shipped set**: `build/MacTAK.app` exactly as `app/bundle.sh`
  stages it — `Contents/Frameworks` (134 dylibs, inventoried by
  `Resources/engine/RUNTIME-MANIFEST.txt`, which names each file's
  source and SHA-256), `Resources/engine/java` (50 jars), and the
  GDAL/PROJ data directories.
- **Homebrew formulas**: `brew info --json=v2` for all 22
  "loaded at run time" formulas of the Brewfile (SPDX expressions,
  straight from Homebrew). Versions cross-checked against
  `Brewfile.lock.json` (the pin gate, `dev/deps/brew-pins.py`, already
  enforces those at build time).
- **License texts**: harvested verbatim from what macTAK actually ships
  where possible — the Homebrew kegs' own `LICENSE`/`COPYING` files, the
  `deps.lock`-pinned GDAL/PROJ/SpatiaLite tarballs, commo's
  `fetch-*.sh` sources, the ANGLE repository; per-file provenance is in
  [`licenses/README.md`](../licenses/README.md).
- **Jars**: resolved by name → Maven coordinates (visible in
  `src/takkernel`'s `engine/build.gradle` and `gradle/versions.gradle`)
  → each project's pom/license page. The jars carry no embedded license
  files (checked: no `META-INF/LICENSE*` in any of them), so the pom
  metadata plus the project's own text is the trail. `antlr-2.7.7.jar`'s
  terms come from the 2.7.7 distribution's `README.txt`.
- **History and hygiene** (F5–F7): `git log --all --diff-filter=A`
  over jar/dylib/WinTAK/GOTS name patterns, and the committed transplant
  set (`dev/g1/transplants`).

## The shipped set

| Category | Rows | Components |
|---|---|---|
| Homebrew runtime formulas | 22 | abseil (96 dylibs), protobuf (3), openssl@3 (2), geos (2), libkml (3), webp (2), and 16 singles: assimp, freexl, gettext, glib, jpeg-turbo, librttopo, libtiff, libxml2, mdbtools, minizip, openjpeg, pcre2, sqlite, uriparser, xz, zstd |
| macTAK's own builds | 5 | GDAL 3.13.3, PROJ 9.9.0, SpatiaLite 5.1.0 (deps.lock pins), GDAL's Java bindings, the takkernel engine natives |
| Staged third-party | 2 | ANGLE (libEGL/libGLESv2 from Electron 43.8.3 at the audit; built from source at `chromium/8078` since 2026-11-19, #139/#220), commoncommo (upstream, GPL-3.0) |
| Static in commo | 3 | curl 8.23.0, ngtcp2 1.26.0, libmicrohttpd 1.0.10 |
| Build-only | 1 | OpenJDK 8 JNI headers (`dev/g1/jdk-include`; never ships) |
| Engine jars | 21 | 19 Maven groups (45 jars) + takkernel jars + android-port (both built from `src/`, GPL-3.0) |

License families across the shipped rows: the GPL-3.0 work itself
(engine, commo, jars built from `src/`); GPL-2.0-or-later riding to
GPL-3.0 (mdbtools, librttopo); LGPL-2.1-or-later dynamic links (geos,
glib, gettext's libintl); the tri-licensed freexl and SpatiaLite (GPL
option elected); libmicrohttpd static (below); permissive everything
else (MIT, BSD-2/3, Apache-2.0, Zlib, 0BSD, IJG, curl, blessing, JSON).

## License elections

Where a component offers a choice, macTAK's pick is recorded in the
inventory's `notes` column:

- **freexl, SpatiaLite** (MPL-1.1 OR GPL-2.0-or-later OR
  LGPL-2.1-or-later): the GPL-2.0-or-later option — they sit inside the
  GPL-3.0 family either way, and no MPL notice machinery is owed.
- **zstd** (BSD-3 OR GPL-2.0-only): the BSD-3-Clause option.
- **xz**: only `liblzma` (0BSD) ships; the GPL-2.0 xz CLI does not.
- **gettext**: only `libintl`, the LGPL-2.1-or-later parts.
- **mdbtools, librttopo**: **GPL-2.0-or-later, not LGPL** — this audit
  corrected the earlier assumption. They cannot ride as LGPL sidecars;
  they are GPL-family code distributed under GPL-3.0 via their "or
  later" clause. Recorded as such (rows cite gpl-2.0.txt).
- **libmicrohttpd** (static in commo): LGPL-2.1-or-later, with the eCos
  option also available to this HTTPS-free build. As LGPL-2.1+ it can be
  upgraded to LGPL-3.0, whose conversion clause permits distribution of
  the combined work under GPL-3.0; the license text ships and the pinned
  tarball plus `dev/g1/fetch-microhttpd.sh` are the corresponding source
  for relinking. **Review note:** this is the one static-LGPL spot in
  the product; if stricter practice is wanted, switch to a dynamic link
  or publish commo's object files. No action required for the current
  distribution.

## Obligations and how they are met

| Obligation | How |
|---|---|
| GPL-3.0 §§4–6 for the app and the GPL-family libraries | Source at the repository (tag per release); `SOURCE-OFFER.md` in the bundle says where, naming `src/` (the upstream pin), `dev/g1/patches/`, `Brewfile.lock.json`, `deps.lock`, the `fetch-*.sh` pins and `licenses/engine-jars.txt` |
| Notice retention (every permissive license) | Every text ships in the bundle (`Contents/Resources/licenses/`), composed into `THIRD-PARTY-NOTICES.txt` |
| LGPL §4 for the dynamic LGPL links (geos, glib, libintl) | Shipped as separate dylibs under their own terms; texts included |
| ANTLR 2's credit request | Satisfied by the notice file naming ANTLR |

## Findings

### F1 — No license texts shipped: FIXED

Before this audit, `build/MacTAK.app` carried no third-party notices or
texts, yet redistributed ~35 independently-licensed components: a notice
violation for every permissive license, and no GPL §6 source story.
`app/bundle.sh` now stages notices, all texts and the source offer via
`dev/deps/stage-licenses.py` before codesign, and
`check-licenses.py --bundle` fails the build if the staged set is not
exactly the inventory's.

### F2 — org.json carries the JSON License: OPEN

`json-20220924.jar` is a **direct** dependency of the upstream engine
(`src/takkernel` `engine/build.gradle`: `api("org.json:json:…")`) — not a
transitive accident. The JSON License (MIT + "The Software shall be used
for Good, not Evil") is not considered free by the FSF or OSI, and a
field-of-use restriction is not a permission GPL-3.0 can incorporate, so
the jar cannot be part of the GPL-3.0 combined work the way the rest of
the classpath is. Context: upstream ATAK-CIV itself ships org.json (on
Android it is the platform's), so macTAK inherited this, and the
macTAK-authored code remains cleanly GPL-3.0. Mitigation now in place:
the jar is inventoried under its actual license, the text ships, and
this finding is the tracked remediation. Options, in preference order:
(a) substitute an API-compatible free fork of Android's org.json (e.g.
`com.vaadin.external.google:android-json`) at kernel-jar build time — a
build-side substitution, no `src/` edit needed; (b) replace it upstream;
(c) accept documented co-existence as mere aggregation. Until one lands,
F2 stays open.

### F3 — ANGLE/Electron provenance: VERIFIED, text now shipped

ANGLE is not built from source: `dev/g2/fetch-angle.sh` stages
`libEGL.dylib`/`libGLESv2.dylib` out of VS Code's Electron (43.8.3 /
Chrome 150.0.7871.250), recording exact sources, versions and SHA-256s
in `angle-dist/PROVENANCE.txt`. The audit verified the provenance file
against the staged binaries and added ANGLE's BSD-3-Clause text (from
the ANGLE repository) to the shipped set. Electron's own terms
(MIT-licensed) do not attach: only the ANGLE libraries ship.

### F4 — JDK JNI headers: VERIFIED, notice added

`dev/g1/jdk-include/jni.h`/`jni_md.h` (pinned so the native build has a
fixed JNI ABI) each carry the Oracle header marking them GPL-2.0 with
the Classpath Exception 1.1 — properly marked, but the directory carried
no standalone notice. `dev/g1/jdk-include/README.md` now states the
terms and provenance; the inventory records it as build-only. Nothing
from the JDK ships in the bundle.

### F5 — Benign old jars in history: NO ACTION

`git log --all --diff-filter=A` over binary names shows the only jars
ever committed were under `dev/g1/transplants/` and `dev/spike/g0/`:
early `takkernel-*-0.59.1` and `android-port-3.1.0` transplants plus
`slf4j-api`/`slf4j-simple`, all later removed except
`slf4j-simple-1.7.30.jar`. Distribution obligations attach to what ships
today, not to history; the jars were never mis-licensed (all GPL-3.0 or
MIT). No action.

### F6 — GOTS hygiene: VERIFIED CLEAN

No file matching WinTAK/GOTS patterns was ever added to the repository
(same `git log --all` sweep); `dev/reference/` stays gitignored. Clean.

### F7 — No 4.6-tree proprietary transplants: VERIFIED CLEAN

The only committed jar today is `dev/g1/transplants/
slf4j-simple-1.7.30.jar`, listed in `SHA256SUMS` and verified by
`dev/check-transplants.sh` (pre-commit, `make check-transplants`, CI
lint). The old 4.6-tree transplant jars are gone; everything else builds
from the pinned GPL-3.0 `src/`. Clean.

### F8 — Test/docs-only dependencies: CONFIRMED out of scope

The Brewfile's "build and test only" formulas (cmake, ninja, pkgconf,
swig, googletest, nlohmann-json, the network tests' gdal CLI) and the
kernel's `testImplementation` jars (junit, j3d-geom) never enter the
bundle — they are absent from `RUNTIME-MANIFEST.txt` and
`engine-jars.txt`, which the gate now enforces going forward.

## The gate

`dev/deps/check-licenses.py` runs in two modes:

- **repo mode** (no arguments; `supply-chain.yml`'s license-gate job on
  every PR): the inventory must cover the Brewfile's runtime formulas,
  `deps.lock`'s tarballs, commo's static trio, ANGLE, GDAL's Java
  bindings and every name in `engine-jars.txt`; texts must exist with no
  orphans; ids unique. The same job regenerates `THIRD-PARTY-NOTICES.md`
  and fails on drift, so notices can never lag the inventory.
- **bundle mode** (`--bundle APP`; inside every `app/bundle.sh` run):
  every `RUNTIME-MANIFEST.txt` source and every staged jar must map to a
  row, the jar set must equal `engine-jars.txt`, and the staged license
  folder must be complete.

Refreshing the jar snapshot after a kernel dependency change: update
`licenses/engine-jars.txt` from `Resources/engine/java` (jar names
sorted), add or bump the inventory rows, then regenerate the notices
(`dev/deps/stage-licenses.py --notices THIRD-PARTY-NOTICES.md`).
