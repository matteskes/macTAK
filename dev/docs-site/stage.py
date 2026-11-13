#!/usr/bin/env python3
"""Stage the repo's Markdown for the docs site (dev/docs-site/build.sh).

Copies every page the site shows (PAGES) into STAGE at its repo path, so
the relative links between documents keep working unchanged. A relative
link to anything that is not a staged page (a script, a directory, a
source file) is rewritten to the file on GitHub at REF, because the site
holds only the Markdown. Links inside code (fenced blocks and inline code
spans) are left alone.

A line that starts with `#` and no space (wrapped text such as "#48, see
below") is a heading to Python-Markdown but plain text to GitHub, which
needs the space; it would nest every later section under a bogus heading
and drop them from the page's table of contents. stage.py escapes that
`#`, so the site reads such lines as GitHub does.

usage: stage.py REPO_ROOT STAGE [REF]   (REF defaults to main)
"""
import re
import shutil
import sys
from pathlib import Path, PurePosixPath

GITHUB = "https://github.com/matteskes/macTAK"

# Every page on the site; mkdocs.yml's nav lists the same set. README.md at
# the root is the home page (MkDocs serves README.md as a folder's index).
PAGES = [
    "README.md",
    "CONTRIBUTING.md",
    "CHANGELOG.md",
    "docs/roadmap.md",
    "docs/architecture.md",
    "docs/feasibility-report.md",
    "docs/pathway-a.md",
    "docs/pathway-c.md",
    "docs/atak-feature-coverage.md",
    "docs/rebase-study-5.5.md",
    "docs/ci-qa.md",
    "dev/g1/NOTES.md",
    "dev/g2/NOTES.md",
    "dev/g3/NOTES.md",
    "dev/spike/g0/NOTES.md",
    "dev/spike/g55/NOTES.md",
    "dev/g1/tools/README.md",
    "dev/spike/g0/transplants/README.md",
]

# [text](target) and [text](target "title"); reference definitions [x]: target
INLINE_LINK = re.compile(r"(\]\()([^)\s]+)((?:\s+\"[^\"]*\")?\))")
REFERENCE_DEF = re.compile(r"^(\s*\[[^\]]+\]:\s*)(\S+)(.*)$")
FENCE = re.compile(r"^\s*(```|~~~)")
# "#" + a non-space at a line start: not a heading on GitHub (see above)
SPACELESS_HASH = re.compile(r"^(\s*)#(?=[^\s#])")


def is_relative(target):
    return not re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I) and not target.startswith(("#", "/"))


def rewrite_target(target, page, root, ref):
    """A relative target that is not a staged page becomes its GitHub URL."""
    if not is_relative(target):
        return target
    path, _, anchor = target.partition("#")
    resolved = PurePosixPath(page).parent / path
    parts = []
    for part in resolved.parts:
        if part == "..":
            if parts:
                parts.pop()
        elif part != ".":
            parts.append(part)
    repo_path = "/".join(parts)
    if repo_path in PAGES:
        return target
    on_disk = root / repo_path
    if not on_disk.exists():
        return target  # left for the strict build to report
    kind = "tree" if on_disk.is_dir() else "blob"
    url = f"{GITHUB}/{kind}/{ref}/{repo_path}"
    return f"{url}#{anchor}" if anchor else url


def rewrite_outside_code(line, page, root, ref):
    """Rewrite link targets in the parts of a line outside inline code spans."""
    segments = re.split(r"(`+[^`]*`+)", line)
    for i, segment in enumerate(segments):
        if segment.startswith("`"):
            continue
        segments[i] = INLINE_LINK.sub(
            lambda m: m.group(1) + rewrite_target(m.group(2), page, root, ref) + m.group(3),
            segment)
    return "".join(segments)


def stage_page(page, root, stage, ref):
    lines = (root / page).read_text(encoding="utf-8").splitlines(keepends=True)
    in_fence = False
    out = []
    for line in lines:
        if FENCE.match(line):
            in_fence = not in_fence
            out.append(line)
            continue
        if in_fence:
            out.append(line)
            continue
        ref_def = REFERENCE_DEF.match(line)
        if ref_def:
            line = ref_def.group(1) + rewrite_target(ref_def.group(2), page, root, ref) + ref_def.group(3) + "\n"
        else:
            line = rewrite_outside_code(SPACELESS_HASH.sub(r"\1\\#", line), page, root, ref)
        out.append(line)
    target = stage / page
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("".join(out), encoding="utf-8")


def main(argv):
    if len(argv) not in (3, 4):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    root, stage = Path(argv[1]).resolve(), Path(argv[2]).resolve()
    ref = argv[3] if len(argv) == 4 else "main"
    missing = [p for p in PAGES if not (root / p).is_file()]
    if missing:
        print("stage.py: pages missing from the repo: " + ", ".join(missing), file=sys.stderr)
        return 1
    if stage.exists():
        shutil.rmtree(stage)
    for page in PAGES:
        stage_page(page, root, stage, ref)
    print(f"stage.py: {len(PAGES)} pages staged in {stage}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
