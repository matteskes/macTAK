# The license set

`licenses/` is the record of every third-party component a macTAK app
bundle carries, and the machinery that keeps that record honest. It came
out of the full audit ([../docs/license-audit.md](../docs/license-audit.md),
findings F1–F8); the rules are a Non-negotiable in
[../CONTRIBUTING.md](../CONTRIBUTING.md).

| File | What it is |
|---|---|
| `inventory.csv` | One row per component: id, version, SPDX terms, origin, what ships where (`artifacts` = dylib filename prefixes, `jars` = exact jar names), the license text file, and notes (license elections, caveats) |
| `texts/` | The license texts the inventory names. Harvested verbatim from the exact artifacts macTAK ships where one exists (Homebrew keg `LICENSE`/`COPYING` files, the pinned tarballs of GDAL/PROJ/SpatiaLite/curl/ngtcp2/microhttpd, the ANGLE repository); a few are canonical texts (Apache-2.0, MIT, the SQLite blessing) or are taken from the project's own distribution (ANTLR 2's `SOFTWARE RIGHTS`, the Bouncy Castle and JSON.org license pages, libxml2's `Copyright` file) |
| `engine-jars.txt` | The snapshot of the engine's jar set (`Resources/engine/java/*.jar`). A jar set change is a deliberate edit here, after its inventory row exists |
| `../THIRD-PARTY-NOTICES.md` | Generated: never edit by hand |

## Where texts came from

Per-file provenance for the non-obvious ones:

- `gdal-license.txt` — `gdal-3.13.3.tar.gz` `LICENSE.TXT` (deps.lock pin);
  covers every driver license bundled in GDAL
- `proj-copying.txt`, `libspatialite-copying.txt` — the deps.lock-pinned
  tarballs' own files
- `curl-copying.txt`, `ngtcp2-copying.txt`, `microhttpd-copying.txt` —
  the sources `dev/g1/fetch-*.sh` build commo's static stack from
- `angle-license.txt` — ANGLE's repository `LICENSE`
  (`dev/g2/angle-dist/PROVENANCE.txt` records the staged binaries)
- `antlr-license.txt` — the ANTLR 2.7.7 distribution's `README.txt`
  license section (the jar carries no license file)
- `pcre2-license.txt` — PCRE2's LICENCE (Homebrew ships only a pointer
  file), canonical text
- `jogamp-license.txt` — JogAmp's per-source-file BSD-3 terms (JogAmp's
  own repository is bot-walled; the pom on Maven Central names the BSD
  license)
- `kxml2-license.txt` — the kXML 2 project license; the pom's note about
  the public-domain `org.xmlpull.v1` classes is appended below the terms
- `jsvg-license.txt` — JSVG's own `META-INF/LICENSE` from `jsvg-1.6.1.jar`
  (`mit.txt` carries the Checker Framework's copyright line)

## The tools

- `../dev/deps/stage-licenses.py` — builds `THIRD-PARTY-NOTICES.md`
  (`--notices FILE`) or stages the whole set into a bundle
  (`DEST` → `THIRD-PARTY-NOTICES.txt`, `licenses/`, `SOURCE-OFFER.md`).
  Called from `app/bundle.sh` before codesign; output is byte-stable
- `../dev/deps/check-licenses.py` — the gate. No arguments: the repo's
  declared dependencies (Brewfile runtime formulas, deps.lock, commo's
  static trio, ANGLE, the jar list) must be inventoried. `--bundle APP`:
  the built bundle's manifest and jars must map to rows, and the staged
  license set must be present. CI's `supply-chain.yml` license-gate job
  runs the repo mode and diffs the committed notices

## Adding or changing a component

1. Add the row (or bump the version) in `inventory.csv`; put any new
   license text in `texts/` — verbatim from the artifact you ship.
2. If the jar set changed, update `engine-jars.txt` to match.
3. `python3 -I dev/deps/stage-licenses.py --notices THIRD-PARTY-NOTICES.md`
   and commit the result.
4. `python3 -I dev/deps/check-licenses.py` must pass (CI runs it; the
   app build runs the `--bundle` mode).
