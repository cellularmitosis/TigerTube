#!/bin/bash
# Research question: how much does content type alone move sustained
# Mpx/s at fixed geometry and fixed rate-control?
#
# Fixes: W×H×fps and rc=q, qv=4.
# Sweeps: source across a curated subset of lavfi generators.
#
# If results are within ~5-10% of each other, content complexity is
# not a dominant factor and plain testsrc2 is a sufficient benchmark
# for the real auto-calibrate feature. If they spread wider, we need
# a composite benchmark.
#
# Captures results to results/sweep-content.log (appended).

set -u

cd "$(dirname "$0")"
mkdir -p ../results
LOG=../results/sweep-content.log
echo "# sweep-content at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"

PROXY="${PROXY:-http://uranium.local:5002}"
DUR="${DUR:-10}"
W="${W:-480}"
H="${H:-360}"
FPS="${FPS:-30}"

for SRC in testsrc2 mandelbrot life cellauto gradients smptebars; do
    URL="$PROXY/bench?source=$SRC&w=$W&h=$H&fps=$FPS&dur=$DUR&rc=q&qv=4"
    RESULT=$(./run-bench.sh "$URL" "$DUR")
    echo "$RESULT" | tee -a "$LOG"
done

# Also: plain color (lowest complexity) with and without noise, to
# bracket the per-coefficient work range.
for NOISE in "" "3" "10"; do
    NOISE_Q=""
    if [ -n "$NOISE" ]; then
        NOISE_Q="&noise=$NOISE"
    fi
    URL="$PROXY/bench?source=color&w=$W&h=$H&fps=$FPS&dur=$DUR&rc=q&qv=4$NOISE_Q"
    RESULT=$(./run-bench.sh "$URL" "$DUR")
    echo "$RESULT" | tee -a "$LOG"
done
