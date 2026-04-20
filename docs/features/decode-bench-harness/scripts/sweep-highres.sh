#!/bin/bash
# One-off extended grid for G4+ class machines — Phase B didn't push
# these hard enough to find their ceilings. Geometry-only sweep at
# 30 fps, testsrc2, qv=4.
set -u
cd "$(dirname "$0")"
mkdir -p ../results
LOG=../results/sweep-highres.log
echo "# sweep-highres at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
PROXY="${PROXY:-http://uranium.local:5002}"
DUR=10
for HOST in pbookg42 emac mdd imacg52; do
    echo "=== machine: $HOST ==="
    for HW in "800x600" "960x720" "1280x720" "1280x960" "1600x1200"; do
        W=${HW%x*}; H=${HW#*x}
        URL="$PROXY/bench?source=testsrc2&w=$W&h=$H&fps=30&dur=$DUR&rc=q&qv=4"
        RESULT=$(BENCH_HOST=$HOST ./run-bench.sh "$URL" $DUR)
        echo "$RESULT" | tee -a "$LOG"
    done
done
