#!/usr/bin/env python3
"""
Guard (issue #152): every Mach-O file under DIR (an app bundle, or a
directory stage-runtime.py filled) loads only what DIR carries or macOS
provides, so it runs on a Mac that never built macTAK.

Fails when a Mach-O file:
  - links a library by an absolute path outside /usr/lib and /System;
  - has an absolute rpath (it could find a library on this Mac only);
  - names an @rpath, @loader_path or @executable_path library that its own
    rpaths don't resolve to a file inside DIR. Each file is checked with its
    own rpaths alone: the engine libraries are dlopen'ed by the JVM, and get
    no help from an executable's.

Usage: check-bundle.py DIR   (exit 0 PASS, 1 FAIL, 2 usage)
"""
import os
import subprocess
import sys

THIN_MAGIC = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"}
FAT_MAGIC = b"\xca\xfe\xba\xbe"
# A Java class file starts with the same 0xCAFEBABE as a fat Mach-O; the next
# four bytes tell them apart: a fat file's architecture count is small, a
# class file's version (minor, major) is at least 45.
MAX_FAT_ARCHS = 30


def is_macho(path):
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError:
        return False
    if head[:4] in THIN_MAGIC:
        return True
    return head[:4] == FAT_MAGIC and 0 < int.from_bytes(head[4:8], "big") < MAX_FAT_ARCHS


def load_commands(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    deps, rpaths, cmd = [], [], None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("cmd "):
            cmd = line.split()[1]
        elif line.startswith("name ") and cmd in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB"):
            deps.append(line.split()[1])
        elif line.startswith("path ") and cmd == "LC_RPATH":
            rpaths.append(line.split()[1])
    return deps, rpaths


def system(p):
    return p.startswith("/usr/lib/") or p.startswith("/System/")


def main(argv):
    if len(argv) != 1 or not os.path.isdir(argv[0]):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    top = os.path.realpath(argv[0])
    files = []
    for dirpath, _, names in os.walk(top):
        for n in names:
            p = os.path.join(dirpath, n)
            if not os.path.islink(p) and is_macho(p):
                files.append(p)
    failures = []
    for path in files:
        rel = os.path.relpath(path, top)
        here = os.path.dirname(path)
        deps, rpaths = load_commands(path)
        for rp in rpaths:
            if not rp.startswith(("@loader_path", "@executable_path")):
                failures.append("%s: absolute rpath %s" % (rel, rp))
        expanded = [rp.replace("@loader_path", here) for rp in rpaths if rp.startswith("@loader_path")]
        for name in deps:
            if system(name):
                continue
            if name.startswith("/"):
                failures.append("%s: links %s by an absolute path" % (rel, name))
                continue
            if name.startswith("@rpath/"):
                candidates = [os.path.join(rp, name[len("@rpath/"):]) for rp in expanded]
            elif name.startswith("@loader_path/"):
                candidates = [os.path.join(here, name[len("@loader_path/"):])]
            else:
                continue   # @executable_path: the executable's, checked where it is one
            found = [os.path.realpath(c) for c in candidates if os.path.exists(c)]
            if not found:
                failures.append("%s: %s resolves to nothing (rpaths %s)" % (rel, name, rpaths or "none"))
            elif not found[0].startswith(top + os.sep):
                failures.append("%s: %s resolves outside %s, to %s" % (rel, name, top, found[0]))
    if failures:
        print("[bundle] FAIL:")
        for f in failures:
            print("    " + f)
        return 1
    print("[bundle] PASS: %d Mach-O files in %s load only what it carries and macOS provides"
          % (len(files), top))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
