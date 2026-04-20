#!/bin/bash
# Research question: how much does bitrate alone — the per-coefficient
# decode work — move sustained Mpx/s at fixed geometry and fixed source?
#
# Fixes: source=testsrc2, W×H×fps.
# Sweeps: rc=cbr with bv from 500k up to 16M.
#
# If sustained Mpx/s drops significantly at high bitrate even with the
# same pixel count, bitrate is a meaningful factor and the real
# auto-calibrate feature needs a bits-per-pixel-aware benchmark input.
# If not, pixel count alone is the dominant factor.
#
# Captures results to results/sweep-bitrate.log (appended).

set -u

cd "$(dirname "$0")"
mkdir -p ../results
LOG=../results/sweep-bitrate.log
echo "# sweep-bitrate at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"

PROXY="${PROXY:-http://uranium.local:5002}"
DUR="${DUR:-10}"
W="${W:-480}"
H="${H:-360}"
FPS="${FPS:-30}"

for BV in 500k 1M 2M 4M 8M 16M; do
    URL="$PROXY/bench?source=testsrc2&w=$W&h=$H&fps=$FPS&dur=$DUR&rc=cbr&bv=$BV"
    RESULT=$(./run-bench.sh "$URL" "$DUR")
    echo "$RESULT" | tee -a "$LOG"
done
