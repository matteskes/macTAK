#!/usr/bin/env python3
"""
Stage macTAK's third-party license set (docs/license-audit.md, F1):

  stage-licenses.py DEST           notices + every license text + the source
                                  offer into DEST (an app bundle's
                                  Contents/Resources/licenses; app/bundle.sh
                                  calls this after stage-runtime.py)
  stage-licenses.py --notices FILE
                                  write only the notices markdown to FILE
                                  (regenerate and commit THIRD-PARTY-NOTICES.md
                                  after editing licenses/inventory.csv;
                                  supply-chain.yml diffs the committed copy)

Everything DEST gets is a pure function of licenses/ (inventory.csv, texts/,
engine-jars.txt) and LICENSE: no dates, no build paths, no run order — the
output is byte-stable, so CI can regenerate and diff it. The notices name
every component the bundle ships, its origin, its SPDX terms and its full
license text; dev/deps/check-licenses.py keeps the inventory honest.

Usage: stage-licenses.py DEST | --notices FILE   (exit 0 OK, 1 fail, 2 usage)
"""
import csv
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LICENSES = os.path.join(ROOT, "licenses")

SOURCE_OFFER = """# Corresponding source — GNU GPL-3.0, section 6

macTAK is licensed GPL-3.0 (see THIRD-PARTY-NOTICES.txt and licenses/).
The complete corresponding source for the object code this application
carries is published at:

    https://github.com/matteskes/macTAK

For the exact build you have, use the repository state at the commit or
release tag it names. The source tree contains, or pins, everything:

  - `src/` — the upstream ATAK-CIV pin the engine, commoncommo and the
    takkernel jars build from; macTAK's changes are exported as patches
    under `dev/g1/patches/` (applied by the build scripts, never in place)
  - `Brewfile` + `Brewfile.lock.json` — the exact Homebrew versions of
    every library shipped from Homebrew
  - `dev/deps/deps.lock` — the sha256-pinned tarballs of GDAL, PROJ and
    SpatiaLite (`dev/deps/build-deps.sh` builds them)
  - `dev/g1/fetch-curl.sh`, `dev/g1/fetch-ngtcp2.sh`,
    `dev/g1/fetch-microhttpd.sh` — the sha256-pinned sources statically
    linked into libcommoncommo.dylib
  - `dev/g2/fetch-angle.sh` — the ANGLE staging (its PROVENANCE.txt
    records the exact binaries and their sha256)
  - the engine jars' Maven coordinates — resolved by Gradle from
    `src/takkernel` (engine/build.gradle + gradle/versions.gradle); the
    shipped set is pinned by name in `licenses/engine-jars.txt`

`make app` builds this bundle from that state (README.md, CONTRIBUTING.md).
Questions or source requests: open an issue at the repository above.
"""


def load_inventory():
    with open(os.path.join(LICENSES, "inventory.csv"), newline="") as f:
        return list(csv.DictReader(f))


def notices_markdown(rows):
    out = [
        "# Third-party notices",
        "",
        "macTAK is licensed GPL-3.0 (`LICENSE`); this file lists every",
        "third-party component the built application carries, where each",
        "came from, and its license terms. It is generated from",
        "`licenses/inventory.csv` by `dev/deps/stage-licenses.py`; the set",
        "itself is guarded by `dev/deps/check-licenses.py`. Corresponding",
        "source: `SOURCE-OFFER.md` (GPL-3.0, section 6).",
        "",
    ]
    for r in sorted(rows, key=lambda r: r["component"].lower()):
        out += [
            "## %s — %s" % (r["component"], r["version"]),
            "",
            "- SPDX / terms: %s" % r["spdx"],
            "- Origin: %s" % r["origin_url"],
            "- Shipped as: %s" % r["shipped_as"],
        ]
        if r["notes"]:
            out.append("- Note: %s" % r["notes"])
        out.append("")
        with open(os.path.join(LICENSES, "texts", r["text"])) as t:
            out.append("```text")
            # rstrip each line: several harvested texts carry trailing
            # spaces, which markdownlint (MD009) rejects in the .md form
            out += [ln.rstrip() for ln in t.read().rstrip("\n").split("\n")]
            out.append("```")
        out.append("")
    return "\n".join(out) + "\n"


def main(argv):
    if not argv or argv[0] == "--notices" and len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    rows = load_inventory()
    texts = sorted({r["text"] for r in rows})
    for name in texts:   # fail loud on a missing text before writing anything
        if not os.path.isfile(os.path.join(LICENSES, "texts", name)):
            print("[licenses] FAIL: inventory names missing text %s" % name)
            return 1
    md = notices_markdown(rows)
    if argv[0] == "--notices":
        with open(argv[1], "w") as f:
            f.write(md)
        print("[licenses] notices: %d components, %d license texts -> %s"
              % (len(rows), len(texts), argv[1]))
        return 0
    dest = os.path.abspath(argv[0])
    os.makedirs(os.path.join(dest, "licenses"), exist_ok=True)
    with open(os.path.join(dest, "THIRD-PARTY-NOTICES.txt"), "w") as f:
        f.write(md)
    for name in texts:
        shutil.copyfile(os.path.join(LICENSES, "texts", name),
                        os.path.join(dest, "licenses", name))
    with open(os.path.join(dest, "SOURCE-OFFER.md"), "w") as f:
        f.write(SOURCE_OFFER)
    print("[licenses] %d components, %d license texts -> %s"
          % (len(rows), len(texts), dest))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
