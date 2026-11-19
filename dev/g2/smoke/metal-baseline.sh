#!/usr/bin/env bash
#
# Trap #77, step 1: run the bare Metal baseline (metal-baseline.swift) N
# times and count the runs that drop a frame, to set against the exit run's
# rate of about one run in 10–20. Opens a window for about 12 s per run.
#
#   bash dev/g2/smoke/metal-baseline.sh [RUNS [TAG [BASELINE OPTIONS...]]]
#     RUNS default 30; TAG names the output folder (default "default");
#     e.g. `metal-baseline.sh 20 settle15 --settle 15 --seconds 11`
#
# Per-run CSVs and summaries go to dev/g2/build/metal-baseline/.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS="${1:-30}"
TAG="${2:-default}"
shift $(( $# > 2 ? 2 : $# ))
OUT="$HERE/../build/metal-baseline/$TAG"
mkdir -p "$OUT"

swiftc -O "$HERE/metal-baseline.swift" -o "$OUT/metal-baseline"

dropRuns=0
missRuns=0
for i in $(seq 1 "$RUNS"); do
  "$OUT/metal-baseline" --csv "$OUT/run-$i.csv" "$@" > "$OUT/run-$i.txt"
  line="$(head -1 "$OUT/run-$i.txt")"
  printf 'run %2d: %s\n' "$i" "${line#metal-baseline: }"
  grep -q 'dropped frame' "$OUT/run-$i.txt" && dropRuns=$((dropRuns + 1))
  grep -q 'on-screen miss' "$OUT/run-$i.txt" && missRuns=$((missRuns + 1))
  sed -n '2,$p' "$OUT/run-$i.txt" | sed 's/^/        /'
done
echo "metal-baseline [$TAG $*]: $RUNS runs; $dropRuns with a dropped frame (our cadence), $missRuns with an on-screen miss"
