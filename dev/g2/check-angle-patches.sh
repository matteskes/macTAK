#!/usr/bin/env bash
#
# Check that every patch in dev/g2/angle-patches/ still applies to the ANGLE
# commit dev/g2/build-angle.sh pins (issue #139: CI verifies the source
# build). Cheap: a shallow, blobless fetch of that one commit and a sparse
# checkout of only the files the patches touch, then `git apply --check`.
# Building ANGLE in CI is a G5 item.
#
#   bash dev/g2/check-angle-patches.sh      # `make check-angle-patches`
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # <repo>/dev/g2
PATCHES="$HERE/angle-patches"
ANGLE_URL="https://chromium.googlesource.com/angle/angle"

log() { printf '[check-angle-patches] %s\n' "$*"; }

# The pin lives in build-angle.sh, as its MACTAK_ANGLE_REV default.
rev="$(sed -nE 's/^ANGLE_REV="\$\{MACTAK_ANGLE_REV:-([0-9a-f]{40})\}"$/\1/p' "$HERE/build-angle.sh")"
[[ "$rev" =~ ^[0-9a-f]{40}$ ]] || { echo "FATAL: no pinned ANGLE_REV in build-angle.sh" >&2; exit 1; }

shopt -s nullglob
patches=("$PATCHES"/*.patch)
[[ ${#patches[@]} -gt 0 ]] || { log "no patches in ${PATCHES#"$HERE/"}"; exit 0; }

# The files the patches touch, from their `diff --git a/X b/X` headers
paths=()
while IFS= read -r p; do paths+=("$p"); done < <(
  sed -nE 's|^diff --git a/([^ ]+) b/.*|\1|p' "${patches[@]}" | sort -u)
[[ ${#paths[@]} -gt 0 ]] || { echo "FATAL: no diff headers in the patches" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/angle-patches.XXXXXX")"
trap 'rm -rf "$work"' EXIT
git -C "$work" init --quiet
git -C "$work" remote add origin "$ANGLE_URL"
log "fetching ANGLE @ ${rev:0:12} (${#paths[@]} file(s))"
git -C "$work" fetch --quiet --depth 1 --filter=blob:none origin "$rev"
git -C "$work" sparse-checkout set --no-cone "${paths[@]}"
git -C "$work" checkout --quiet --detach FETCH_HEAD

# In name order, as build-angle.sh applies them: each on top of the last.
for p in "${patches[@]}"; do
  git -C "$work" apply --check --whitespace=nowarn "$p" \
    || { echo "FATAL: $(basename "$p") no longer applies at ${rev:0:12}" >&2; exit 1; }
  git -C "$work" apply --whitespace=nowarn "$p"
  log "ok: $(basename "$p")"
done
log "all ${#patches[@]} patch(es) apply at $rev"
