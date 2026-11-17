#!/usr/bin/env python3
"""
Guard (license audit, docs/license-audit.md): nothing ships silently
unlicensed.

No argument — what the repo declares must be inventoried (supply-chain.yml
runs this on every PR):

  - every "loaded at run time" formula in the Brewfile,
  - every pinned tarball in dev/deps/deps.lock,
  - commo's statically linked trio (curl, ngtcp2, libmicrohttpd —
    dev/g1/build-commo.sh), ANGLE (dev/g2/fetch-angle.sh) and GDAL's Java
    bindings (dev/g2/fetch-gdal-java.sh),
  - every jar named in licenses/engine-jars.txt;
  - every row's license text exists under licenses/texts, no orphan
    texts, ids unique.

--bundle DIR — what a built application bundle actually contains must
match the inventory: every RUNTIME-MANIFEST.txt source (a Homebrew
formula, or a dev/ artifact by filename prefix) maps to a row, the jars
in Resources/engine/java equal licenses/engine-jars.txt exactly, and
Contents/Resources/licenses carries the notices, every text and the
source offer (app/bundle.sh stages them). RUNTIME-MANIFEST versions are
already pinned against Brewfile.lock.json by dev/deps/brew-pins.py.

Usage: check-licenses.py [--bundle DIR]   (exit 0 PASS, 1 FAIL, 2 usage)
"""
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LICENSES = os.path.join(ROOT, "licenses")
COLS = ("id", "component", "version", "spdx", "origin_url",
        "shipped_as", "artifacts", "jars", "text", "notes")
# rows whose presence the build scripts guarantee structurally, so the
# inventory cannot forget them (docs/license-audit.md)
STRUCTURAL_IDS = ("g1:curl", "g1:ngtcp2", "g1:microhttpd", "dist:angle",
                  "deps:gdal-java")


def brewfile_runtime_formulas():
    formulas, inside = [], False
    for line in open(os.path.join(ROOT, "Brewfile")):
        if line.startswith("# --- loaded at run time"):
            inside = True
        elif line.startswith("# --- build and test only"):
            inside = False
        elif inside and line.startswith("brew "):
            formulas.append(line.split('"')[1])
    return formulas


def deps_lock_names():
    names = []
    for line in open(os.path.join(ROOT, "dev", "deps", "deps.lock")):
        if line.strip() and not line.startswith("#"):
            names.append(line.split()[0])
    return names


def check_repo(rows, failures):
    ids = [r["id"] for r in rows]
    dup = sorted({i for i in ids if ids.count(i) > 1})
    if dup:
        failures.append("duplicate ids: %s" % " ".join(dup))
    jars, texts = set(), set()
    for r in rows:
        for col in ("component", "version", "spdx", "origin_url", "text"):
            if not r[col].strip():
                failures.append("%s: empty %s" % (r["id"], col))
        path = os.path.join(LICENSES, "texts", r["text"])
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            failures.append("%s: license text missing or empty: %s" % (r["id"], r["text"]))
        jars.update(j for j in r["jars"].split(";") if j)
        texts.add(r["text"])
    orphans = sorted(set(os.listdir(os.path.join(LICENSES, "texts"))) - texts)
    if orphans:
        failures.append("orphan texts (no inventory row): %s" % " ".join(orphans))
    jar_list = [l.strip() for l in
                open(os.path.join(LICENSES, "engine-jars.txt")) if l.strip()]
    if jar_list != sorted(set(jar_list)):
        failures.append("engine-jars.txt is not sorted-unique")
    listed = set(jar_list)
    if listed - jars:
        failures.append("jars listed but not inventoried: %s"
                        % " ".join(sorted(listed - jars)))
    for formula in brewfile_runtime_formulas():
        if "homebrew:" + formula not in ids:
            failures.append("Brewfile runtime formula not inventoried: %s" % formula)
    for name in deps_lock_names():
        if "deps:" + name not in ids:
            failures.append("deps.lock tarball not inventoried: %s" % name)
    for rid in STRUCTURAL_IDS:
        if rid not in ids:
            failures.append("missing structural row: %s" % rid)
    return jars, listed


def check_bundle(bundle, rows, jars, listed, failures):
    manifest = os.path.join(bundle, "Contents", "Resources", "engine",
                            "RUNTIME-MANIFEST.txt")
    prefixes = sorted(((p, r["id"]) for r in rows
                       for p in r["artifacts"].split(";") if p),
                      key=lambda kv: -len(kv[0]))
    ids = {r["id"] for r in rows}
    files = 0
    for line in open(manifest):
        if line.startswith("#"):
            continue
        files += 1
        parts = line.split()
        name, source = parts[0], " ".join(parts[2:])
        if source.startswith("homebrew "):
            rid = "homebrew:" + source.split()[1]
            if rid not in ids:
                failures.append("bundle ships uninventoried Homebrew library: %s" % rid)
        else:
            hit = [i for p, i in prefixes if name.startswith(p)]
            if not hit:
                failures.append("bundle dylib maps to no inventory row: %s" % name)
    java_dir = os.path.join(bundle, "Contents", "Resources", "engine", "java")
    bundled = {n for n in os.listdir(java_dir) if n.endswith(".jar")}
    if bundled - listed:
        failures.append("bundle jar absent from engine-jars.txt: %s"
                        % " ".join(sorted(bundled - listed)))
    if listed - bundled:
        failures.append("engine-jars.txt names jars the bundle lacks: %s"
                        % " ".join(sorted(listed - bundled)))
    staged = os.path.join(bundle, "Contents", "Resources", "licenses")
    if not os.path.isfile(os.path.join(staged, "THIRD-PARTY-NOTICES.txt")):
        failures.append("staged licenses missing: THIRD-PARTY-NOTICES.txt")
    if not os.path.isfile(os.path.join(staged, "SOURCE-OFFER.md")):
        failures.append("staged licenses missing: SOURCE-OFFER.md")
    for name in sorted({r["text"] for r in rows}):
        if not os.path.isfile(os.path.join(staged, "licenses", name)):
            failures.append("staged licenses missing: licenses/%s" % name)
    return files


def main(argv):
    bundle = None
    if len(argv) == 2 and argv[0] == "--bundle":
        bundle = argv[1]
    elif argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(os.path.join(LICENSES, "inventory.csv"), newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        if header != list(COLS):
            print("[licenses] FAIL: inventory columns are %s" % ",".join(header))
            return 1
        rows = [dict(zip(COLS, r)) for r in reader]
    failures = []
    jars, listed = check_repo(rows, failures)
    files = 0
    if bundle:
        if not os.path.isdir(bundle):
            print("[licenses] FAIL: no such bundle: %s" % bundle)
            return 1
        files = check_bundle(bundle, rows, jars, listed, failures)
    if failures:
        print("[licenses] FAIL:")
        for f in failures:
            print("    " + f)
        return 1
    where = (" (+ bundle: %d manifest libraries, %d jars)"
             % (files, len(listed))) if bundle else ""
    print("[licenses] PASS: %d components, %d license texts, %d jars%s"
          % (len(rows), len({r["text"] for r in rows}), len(listed), where))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
