#!/usr/bin/env bash
#
# Pulls the tinygltf tarball the engine build needs from the 5.5 tree's Git
# LFS (src/depends holds LFS pointers), retrying when GitHub's LFS server
# fails. On 2026-11-25 its batch endpoint for the upstream repo answered
# HTTP 503 and "couldn't respond to your request in time" on every engine
# job of two CI runs; git-lfs gives up on the first such answer. This
# tries up to 5 times, waiting 15, 30, 60 and 120 seconds between tries.
#
# usage: dev/lfs-pull-tinygltf.sh   (from the repo root; src/ checked out)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARBALL="depends/tinygltf-2.4.1-mod.tar.gz"
TRIES=5

log() { printf '[lfs-pull] %s\n' "$*"; }

wait=15
for try in $(seq 1 "$TRIES"); do
  if git -C "$ROOT/src" lfs pull --include="$TARBALL"; then
    log "pulled $TARBALL (try $try)"
    exit 0
  fi
  if (( try < TRIES )); then
    log "try $try of $TRIES failed; again in ${wait}s"
    sleep "$wait"
    wait=$((wait * 2))
  fi
done
log "FATAL: $TARBALL not pulled after $TRIES tries" >&2
exit 1
