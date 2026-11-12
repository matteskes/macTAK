#!/usr/bin/env bash
#
# The docs site (`make docs-site`): the repo's Markdown as a browsable site,
# with a sidebar of every document and a table of contents on every page.
# stage.py copies the pages into build/stage at their repo paths (links to
# non-pages point at GitHub); MkDocs builds build/site in strict mode, so a
# broken link or anchor fails the build. CI builds it on every PR that
# touches docs and publishes it to GitHub Pages from main
# (.github/workflows/docs-site.yml).
#
# MkDocs and Material install into a venv from the hash-pinned
# requirements-docs.txt (--require-hashes); the venv is rebuilt whenever
# that file changes.
#
# usage: dev/docs-site/build.sh [serve]   (serve: preview on 127.0.0.1:8000;
#        it serves the staged copy, so re-run after editing a page)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/docs-site
ROOT="$(cd "$HERE/../.." && pwd)"
VENV="$HERE/build/venv"
REQUIREMENTS="$HERE/requirements-docs.txt"

log() { printf '[docs-site] %s\n' "$*"; }

if ! cmp -s "$REQUIREMENTS" "$VENV/requirements-docs.txt" 2>/dev/null; then
  log "MkDocs venv (--require-hashes) → $VENV"
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check --require-hashes -r "$REQUIREMENTS"
  cp "$REQUIREMENTS" "$VENV/requirements-docs.txt"
fi

python3 "$HERE/stage.py" "$ROOT" "$HERE/build/stage"

# Material prints a banner about its 2027 end of life on every build
export NO_MKDOCS_2_WARNING=1
cd "$HERE"
if [[ "${1:-}" == serve ]]; then
  "$VENV/bin/mkdocs" serve --dev-addr 127.0.0.1:8000
else
  "$VENV/bin/mkdocs" build
  log "built $HERE/build/site (open build/site/index.html)"
fi
