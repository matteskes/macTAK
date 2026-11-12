#!/usr/bin/env bash
#
# Fail when a script under dev/ that sets pipefail pipes into a grep that
# stops reading early (`grep -q`, `--quiet`, `-m N`, `--max-count`). grep
# exits on the first match, the writer upstream takes SIGPIPE (exit 141),
# and pipefail reports the pipeline as failed: a match reads as "no match".
# It bit three times before this check existed: G1 trap 2 and G2 trap 8
# (`strings | grep -m1`), and g55 trap 3 (`git log | grep -q`).
# Capture the output first, then grep it (dev/g2/render/env.sh does).
#
# Used by `make lint` and CI's lint job.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# a single | (not ||), then grep with -q/-m among its flags
EARLY_EXIT_GREP='(^|[^|])\|[[:space:]]*grep[[:space:]]+(-[^[:space:]]*[[:space:]]+)*(-[A-Za-z]*[qm]|--quiet|--max-count)'

bad=0
while IFS= read -r script; do
  grep -Eq '^[[:space:]]*set[[:space:]].*pipefail' "$script" || continue
  hits="$(grep -nE "$EARLY_EXIT_GREP" "$script" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [[ -n "$hits" ]] || continue
  while IFS= read -r hit; do
    echo "[check-pipefail-grep] FAIL $script:${hit%%:*}: pipes into an early-exit grep under pipefail" >&2
  done <<<"$hits"
  bad=1
done < <(git ls-files 'dev/*.sh' 'dev/**/*.sh' dev/g1/headless/atak-headless)

if [[ "$bad" -ne 0 ]]; then
  exit 1
fi
echo "[check-pipefail-grep] OK: no early-exit grep at the end of a pipe under pipefail"
