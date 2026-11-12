#!/usr/bin/env python3
"""Sort macTAK's engine patch series against a newer upstream tree.

Written for spike 1 (4.6 → 5.5); kept for the next upstream bump. Applies
dev/g1/patches to a copy of the new engine in the order
dev/g1/build-native.sh uses (gdal-drift-*.patch first, then the rest,
sorted), stacked, and sorts each patch:

  clean      applies at --fuzz=0; copied unchanged to OUT_DIR
  refreshed  applies with fuzz and/or --ignore-whitespace, and every hunk,
             context included, reads the same as at the pin (whitespace
             aside); regenerated so the copy in OUT_DIR applies at --fuzz=0
             (build-native.sh's rule)
  review     applies with fuzz but some hunk's context changed, so patch(1)
             may have put it in the wrong place; rolled back, nothing written
  upstream   applies in reverse at --fuzz=0: the change is already upstream
  failed     does not apply; nothing written

`review` and `failed` patches are ported by hand into OUT_DIR. Why the
context check exists: at --fuzz=3 a 3-line-context hunk matches with no
context at all, and an addition-only hunk lands wherever its old line
number points (seen on GdalLibrary.java, where it split an if/else chain).
Fuzz is safe only when the regenerated hunk shows the original context.

The regenerated diffs keep the a/tmp/takeng-src/... prefix, so they apply
with the same `patch -p3 -d <engine>` line.

usage: refresh-patches.py ENGINE_MAIN OUT_DIR
       ENGINE_MAIN     takkernel/engine/src/main of the new checkout
       OUT_DIR         where clean and refreshed patches are written
exit:  0 when the run completes (review and failed are results, not
       errors); 2 on usage errors
"""
import difflib
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[3]
_PATCHES = sorted((REPO / "dev/g1/patches").glob("*.patch"))
SERIES = ([p for p in _PATCHES if p.name.startswith("gdal-drift-")]
          + [p for p in _PATCHES if not p.name.startswith("gdal-drift-")])
PREFIX = "tmp/takeng-src/"          # a/<PREFIX>cpp/... in the series
MAX_FUZZ = 3                        # placement is checked, not trusted
STATUSES = ("clean", "refreshed", "review", "upstream", "failed")


def patch(engine, patch_file, *flags):
    """Run patch(1) against engine; True when it applies."""
    with open(patch_file, "rb") as data:
        result = subprocess.run(
            ["patch", "--forward", "--silent", "--no-backup-if-mismatch",
             "-p3", "-d", str(engine), *flags],
            stdin=data, capture_output=True)
    return result.returncode == 0


def targets(patch_text):
    """Engine-relative paths the patch writes ('+++ b/tmp/takeng-src/cpp/x')."""
    paths = []
    for line in patch_text.splitlines():
        if line.startswith("+++ "):
            path = line[4:].split("\t")[0].strip()
            paths.append(path.split(PREFIX, 1)[1] if PREFIX in path else path)
    return paths


def hunk_bodies(patch_text):
    """Hunk lines without headers, line numbers, blank lines or whitespace
    differences (a blank line moving across a hunk edge is regrouping)."""
    body = []
    for line in patch_text.splitlines():
        if line.startswith(("--- ", "+++ ", "@@", "diff ", "index ")):
            continue
        if line[1:].strip():
            body.append(line[:1] + " ".join(line[1:].split()))
    return body


def regenerate(engine, paths, before):
    """A unified diff from the saved `before` copies to the current files."""
    chunks = []
    for rel in paths:
        old = before.get(rel, "").splitlines(keepends=True)
        new_path = engine / rel
        new = new_path.read_text(errors="replace").splitlines(keepends=True) \
            if new_path.exists() else []
        chunks.extend(difflib.unified_diff(
            old, new, fromfile="a/" + PREFIX + rel, tofile="b/" + PREFIX + rel))
    return "".join(chunks)


def restore(engine, paths, before):
    for rel in paths:
        if rel in before:
            (engine / rel).write_text(before[rel])
        else:
            (engine / rel).unlink(missing_ok=True)


def sort_patch(engine, patch_file, out_dir):
    """Apply one patch of the stack (or not) and return its status."""
    if patch(engine, patch_file, "--dry-run", "--fuzz=0"):
        patch(engine, patch_file, "--fuzz=0")
        shutil.copy(patch_file, out_dir / patch_file.name)
        return "clean"
    if patch(engine, patch_file, "--dry-run", "--reverse", "--fuzz=0"):
        return "upstream"
    text = patch_file.read_text(errors="replace")
    paths = targets(text)
    for fuzz in range(0, MAX_FUZZ + 1):
        flags = ("--ignore-whitespace", f"--fuzz={fuzz}")
        if not patch(engine, patch_file, "--dry-run", *flags):
            continue
        before = {rel: (engine / rel).read_text(errors="replace")
                  for rel in paths if (engine / rel).exists()}
        patch(engine, patch_file, *flags)
        fresh = regenerate(engine, paths, before)
        if hunk_bodies(fresh) == hunk_bodies(text):
            (out_dir / patch_file.name).write_text(fresh)
            return "refreshed"
        restore(engine, paths, before)
        return "review"
    return "failed"


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    engine_src, out_dir = pathlib.Path(argv[0]), pathlib.Path(argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)

    results = []
    with tempfile.TemporaryDirectory() as tmp:
        engine = pathlib.Path(tmp) / "engine"
        shutil.copytree(engine_src, engine, symlinks=True)
        for patch_file in SERIES:
            results.append((sort_patch(engine, patch_file, out_dir),
                            patch_file.name))

    for status in STATUSES:
        names = [n for s, n in results if s == status]
        print(f"[refresh] {status:9} {len(names):2}  " + " ".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
