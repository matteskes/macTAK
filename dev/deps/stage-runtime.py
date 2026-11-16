#!/usr/bin/env python3
"""
Stage a self-contained native runtime (issue #152): copy ROOT dylibs and
every library they load outside /usr/lib and /System (Homebrew's, dev/deps'
own GDAL/PROJ/libspatialite, ANGLE) into one flat DEST directory, and make
each relocatable:

  - its install name becomes @rpath/<name>;
  - every reference to another staged library becomes @rpath/<name>;
  - its only rpath is @loader_path, so the set finds itself wherever DEST
    goes (an app's Contents/Frameworks, a test directory);
  - install_name_tool breaks the signature, so each is ad-hoc re-signed.

DEST/RUNTIME-MANIFEST.txt records each staged file's source and SHA-256.
The resolver is check-closure.py's, so staging and checking walk the same
graph. Check the result with check-bundle.py.

Usage: stage-runtime.py DEST ROOT_DYLIB...   (exit 0 OK, 1 failure, 2 usage)
"""
import hashlib
import importlib.util
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("check_closure", os.path.join(HERE, "check-closure.py"))
closure = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(closure)


def system(path):
    return path.startswith("/usr/lib/") or path.startswith("/System/")


def install_name(path):
    out = subprocess.run(["otool", "-D", path], capture_output=True, text=True).stdout.splitlines()
    return out[1].strip() if len(out) > 1 else None


def walk(roots):
    """{real file: {referenced name: real file it resolves to}} over the closure."""
    graph, stack = {}, [(os.path.realpath(r), []) for r in roots]
    while stack:
        path, inherited = stack.pop()
        if path in graph or system(path):
            continue
        deps, rpaths = closure.load_commands(path)
        here = os.path.dirname(path)
        rpath_stack = [rp.replace("@loader_path", here) for rp in rpaths] + inherited
        graph[path] = {}
        for name in deps:
            dep = closure.resolve(name, path, rpath_stack)
            if system(dep):
                continue
            graph[path][name] = dep
            stack.append((dep, rpath_stack))
    return graph


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("%s: %s" % (" ".join(cmd), (r.stderr or r.stdout).strip()))


def origin(path):
    m = re.match(r"/opt/homebrew/Cellar/([^/]+)/([^/]+)/", path)
    return "homebrew %s %s" % (m.group(1), m.group(2)) if m else path


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    dest, roots = os.path.abspath(argv[0]), argv[1:]
    graph = walk(roots)

    # one staged name per file: its install name's basename (what the others
    # link it by), or its own for a root with none
    staged = {}
    for path in graph:
        ident = install_name(path)
        staged[path] = os.path.basename(ident) if ident else os.path.basename(path)
    names = {}
    for path, name in staged.items():
        if name in names and names[name] != path:
            print("[stage] FAIL: two libraries stage as %s: %s and %s" % (name, names[name], path))
            return 1
        names[name] = path

    os.makedirs(dest, exist_ok=True)
    manifest = []
    for path, name in sorted(staged.items(), key=lambda kv: kv[1]):
        out = os.path.join(dest, name)
        if os.path.lexists(out):
            os.remove(out)
        shutil.copyfile(path, out)
        os.chmod(out, 0o755)
        _, rpaths = closure.load_commands(out)
        cmd = ["install_name_tool", "-id", "@rpath/" + name]
        for ref, dep in graph[path].items():
            cmd += ["-change", ref, "@rpath/" + staged[dep]]
        for rp in dict.fromkeys(rpaths):
            cmd += ["-delete_rpath", rp]
        cmd.append(out)
        run(cmd)
        run(["install_name_tool", "-add_rpath", "@loader_path", out])
        run(["codesign", "--force", "--sign", "-", out])
        with open(out, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        manifest.append("%-44s %s  %s" % (name, digest, origin(path)))

    with open(os.path.join(dest, "RUNTIME-MANIFEST.txt"), "w") as f:
        f.write("# staged by dev/deps/stage-runtime.py: name, sha256 (after relinking), source\n")
        f.write("\n".join(manifest) + "\n")
    homebrew = sorted({m.split()[3] for m in manifest if " homebrew " in m})
    print("[stage] %d libraries in %s (%d Homebrew packages: %s)"
          % (len(manifest), dest, len(homebrew), " ".join(homebrew)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (RuntimeError, FileNotFoundError) as e:
        print("[stage] FAIL: %s" % e)
        sys.exit(1)
