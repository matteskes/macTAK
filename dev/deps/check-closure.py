#!/usr/bin/env python3
"""
Guard: walk every library the built engine, JNI glue, commo and GDAL Java
bindings load (their whole dependency closure, resolving @rpath,
@loader_path and @executable_path as dyld does) and fail when the process
would load:

  - OpenSSL 4 (libssl.4 / libcrypto.4): macTAK's one TLS stack is OpenSSL 3;
  - Homebrew's curl or libpq, which link OpenSSL 4;
  - Homebrew's GDAL, PROJ or libspatialite: dev/deps builds those;
  - a second copy of libgdal or libproj (two instances in one process).

PR B of the bundling plan adds GnuTLS and Apple's libcurl to the list once
commo's libmicrohttpd and the engine's curl users move to OpenSSL 3.

Usage: check-closure.py ROOT_DYLIB...   (exit 0 PASS, 1 FAIL, 2 usage)
"""
import os
import re
import subprocess
import sys

FORBIDDEN = [
    (re.compile(r"/libssl\.4(\.|$)|/libcrypto\.4(\.|$)|/openssl@4/"), "OpenSSL 4"),
    (re.compile(r"/opt/homebrew/(opt|Cellar)/curl/"), "Homebrew's curl (links OpenSSL 4)"),
    (re.compile(r"/libpq\.\d"), "libpq (links OpenSSL 4)"),
    (re.compile(r"/opt/homebrew/(opt|Cellar)/(gdal|proj|libspatialite)/"),
     "Homebrew's GDAL/PROJ/libspatialite (dev/deps builds these)"),
]
SINGLE = {"libgdal": re.compile(r"/libgdal\.\d"), "libproj": re.compile(r"/libproj\.\d")}


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


def resolve(name, loader, rpath_stack):
    """The file dyld would load for `name` from `loader`, or None (a system lib in the shared cache)."""
    here = os.path.dirname(loader)

    def expand(p):
        return p.replace("@loader_path", here).replace("@executable_path", here)

    if name.startswith("@rpath/"):
        for rp in rpath_stack:
            candidate = os.path.join(expand(rp), name[len("@rpath/"):])
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        raise FileNotFoundError("%s: no rpath of %s resolves %s (rpaths: %s)" % (loader, loader, name, rpath_stack))
    path = expand(name)
    if os.path.exists(path):
        return os.path.realpath(path)
    if path.startswith("/usr/lib/") or path.startswith("/System/"):
        return path   # in the dyld shared cache: no file, but still loaded
    raise FileNotFoundError("%s links %s, which doesn't exist" % (loader, name))


def main(roots):
    if not roots:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    seen, failures = {}, []
    stack = [(os.path.realpath(r), []) for r in roots]
    while stack:
        path, inherited = stack.pop()
        if path in seen:
            continue
        seen[path] = True
        if path.startswith("/usr/lib/") or path.startswith("/System/"):
            continue
        deps, rpaths = load_commands(path)
        # an image's own LC_RPATHs come before the ones its loaders passed down
        here = os.path.dirname(path)
        rpath_stack = [rp.replace("@loader_path", here) for rp in rpaths] + inherited
        for name in deps:
            try:
                dep = resolve(name, path, rpath_stack)
            except FileNotFoundError as e:
                failures.append(str(e))
                continue
            for pattern, why in FORBIDDEN:
                if pattern.search(dep) or pattern.search(name):
                    failures.append("%s loads %s: %s" % (os.path.basename(path), dep, why))
            stack.append((dep, rpath_stack))
    for lib, pattern in SINGLE.items():
        copies = sorted(p for p in seen if pattern.search(p))
        if len(copies) > 1:
            failures.append("%d copies of %s in one process: %s" % (len(copies), lib, ", ".join(copies)))
    homebrew = sorted({m.group(1) for p in seen for m in [re.match(r"/opt/homebrew/Cellar/([^/]+)/", p)] if m})
    if failures:
        print("[closure] FAIL:")
        for f in sorted(set(failures)):
            print("    " + f)
        return 1
    print("[closure] PASS: %d libraries; no OpenSSL 4, Homebrew curl/libpq or Homebrew GDAL/PROJ; "
          "one libgdal, one libproj" % len(seen))
    print("[closure]   Homebrew packages still loaded (%d): %s" % (len(homebrew), " ".join(homebrew)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
