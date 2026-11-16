#!/usr/bin/env python3
"""
The Homebrew pins (issue #151): every Homebrew package macTAK builds with or
ships must be the version Brewfile.lock.json records, and a mismatch fails
the build, clearly, before it starts.

The version that counts is the one the formula's opt link points to
(/opt/homebrew/opt/NAME -> Cellar/NAME/VERSION): that is the copy the builds
link, by its opt path, and the one dev/deps/stage-runtime.py ships.

Usage:
  brew-pins.py [NAME...]            check NAME..., or every Brewfile package
  brew-pins.py --closure ROOT...    check every Homebrew package the dylibs
                                    ROOT... load at run time, and that each
                                    is in the Brewfile: a new transitive
                                    dependency can't arrive unpinned
  brew-pins.py --manifest FILE      check a RUNTIME-MANIFEST.txt
                                    (stage-runtime.py): what a bundle ships
  brew-pins.py --print              the lock for what's installed now
  brew-pins.py --write              ... written to Brewfile.lock.json

MACTAK_BREW_PINS=warn reports a mismatch without failing, for a deliberate
upgrade: install, test, then --write and commit the lock (CONTRIBUTING.md).

Exit: 0 pinned, 1 mismatch, 2 usage.
"""
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BREWFILE = os.path.join(ROOT, "Brewfile")
LOCK = os.path.join(ROOT, "Brewfile.lock.json")
PREFIX = os.environ.get("HOMEBREW_PREFIX", "/opt/homebrew")


def brewfile_packages():
    with open(BREWFILE) as f:
        return re.findall(r'^brew\s+"([^"]+)"', f.read(), re.M)


def lock_entries():
    with open(LOCK) as f:
        return json.load(f)["entries"]


def installed_version(name):
    """The version /opt/homebrew/opt/NAME points to, or None."""
    opt = os.path.join(PREFIX, "opt", name)
    if not os.path.exists(opt):
        return None
    return os.path.basename(os.path.realpath(opt))


def closure_packages(roots):
    spec = importlib.util.spec_from_file_location("stage_runtime", os.path.join(HERE, "stage-runtime.py"))
    stage = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(stage)
    found = {}
    for path in stage.walk(roots):
        m = re.match(r"%s/Cellar/([^/]+)/([^/]+)/" % re.escape(PREFIX), path)
        if m:
            found[m.group(1)] = m.group(2)
    return found


def manifest_packages(manifest):
    found = {}
    with open(manifest) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 5 and parts[2] == "homebrew":
                found[parts[3]] = parts[4]
    return found


def report(problems, what):
    if not problems:
        print("[brew-pins] PASS: %s match Brewfile.lock.json" % what)
        return 0
    warn = os.environ.get("MACTAK_BREW_PINS") == "warn"
    print("[brew-pins] %s: %d of %s %s Brewfile.lock.json:" % (
        "WARN" if warn else "FAIL", len(problems), what, "doesn't match" if len(problems) == 1 else "don't match"))
    for p in problems:
        print("    " + p)
    print("  To build with the pinned versions: brew bundle install (Brewfile), or install them.")
    print("  To move the pins on purpose: upgrade, run the test suites, then")
    print("    python3 dev/deps/brew-pins.py --write   and commit Brewfile.lock.json")
    print("  (MACTAK_BREW_PINS=warn builds anyway, for that upgrade.)")
    return 0 if warn else 1


def check(versions_by_name, what):
    """versions_by_name: name -> version found (None: not installed)."""
    lock = lock_entries()
    listed = set(brewfile_packages())
    problems = []
    for name, version in sorted(versions_by_name.items()):
        pinned = lock.get(name)
        if name not in listed or pinned is None:
            problems.append("%s %s is loaded but isn't in the Brewfile and its lock" % (name, version))
        elif version is None:
            problems.append("%s isn't installed (pinned %s)" % (name, pinned))
        elif version != pinned:
            problems.append("%s is %s, pinned %s" % (name, version, pinned))
    return report(problems, what)


def current_lock():
    entries = {}
    for name in sorted(brewfile_packages()):
        version = installed_version(name)
        if version is None:
            raise SystemExit("[brew-pins] %s isn't installed: brew bundle install, then --write" % name)
        entries[name] = version
    return json.dumps({"entries": entries}, indent=2) + "\n"


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    if argv[:1] == ["--print"]:
        sys.stdout.write(current_lock())
        return 0
    if argv[:1] == ["--write"]:
        with open(LOCK, "w") as f:
            f.write(current_lock())
        print("[brew-pins] wrote %s" % LOCK)
        return 0
    if argv[:1] == ["--closure"]:
        if len(argv) < 2:
            print(__doc__.strip(), file=sys.stderr)
            return 2
        found = closure_packages(argv[1:])
        return check(found, "the %d Homebrew packages these libraries load" % len(found))
    if argv[:1] == ["--manifest"]:
        if len(argv) != 2:
            print(__doc__.strip(), file=sys.stderr)
            return 2
        found = manifest_packages(argv[1])
        return check(found, "the %d Homebrew packages the bundle ships" % len(found))
    if any(a.startswith("-") for a in argv):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    names = argv or brewfile_packages()
    return check({n: installed_version(n) for n in names}, "%d Homebrew packages" % len(names))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
