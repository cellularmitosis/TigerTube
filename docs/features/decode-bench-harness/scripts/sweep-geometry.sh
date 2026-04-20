#!/bin/bash
# Research question: where does the raw pixel-throughput ceiling sit
# on a G3 / G5 for an "easy" source, isolated from content variance?
#
# Fixes: source=testsrc2, rc=q, qv=4, noise off.
# Sweeps: W×H at multiple fps values.
#
# Captures results to results/sweep-geometry.log (appended).

set -u

cd "$(dirname "$0")"
mkdir -p ../results
LOG=../results/sweep-geometry.log
echo "# sweep-geometry at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"

PROXY="${PROXY:-http://uranium.local:5002}"
DUR="${DUR:-10}"

for HW in "240x180" "320x240" "400x300" "480x360" "640x480" "800x600"; do
    W=${HW%x*}
    H=${HW#*x}
    for FPS in 24 30 60; do
        URL="$PROXY/bench?source=testsrc2&w=$W&h=$H&fps=$FPS&dur=$DUR&rc=q&qv=4"
        RESULT=$(./run-bench.sh "$URL" "$DUR")
        echo "$RESULT" | tee -a "$LOG"
    done
done
