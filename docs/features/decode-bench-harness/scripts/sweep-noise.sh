#!/bin/bash
# Research question: how does noise amplitude (which indirectly drives
# emitted bitrate at fixed -q:v) affect sustained Mpx/s?
#
# Fixes: source=testsrc2, rc=q, qv=4, W×H×fps.
# Sweeps: noise amplitude from 0 (disabled) through 20.
#
# This is the direct variant of sweep-bitrate.sh — instead of forcing
# CBR at a target bitrate, we let the encoder produce whatever bitrate
# the noisy input warrants at constant quality. Compare these results
# against sweep-bitrate.sh to see whether "natural" encoder-driven
# bitrate variation has the same effect as forced CBR variation.
#
# Captures results to results/sweep-noise.log (appended).

set -u

cd "$(dirname "$0")"
mkdir -p ../results
LOG=../results/sweep-noise.log
echo "# sweep-noise at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"

PROXY="${PROXY:-http://uranium.local:5002}"
DUR="${DUR:-10}"
W="${W:-480}"
H="${H:-360}"
FPS="${FPS:-30}"

for NOISE in 0 1 2 3 5 10 20; do
    NOISE_Q=""
    if [ "$NOISE" != "0" ]; then
        NOISE_Q="&noise=$NOISE"
    fi
    URL="$PROXY/bench?source=testsrc2&w=$W&h=$H&fps=$FPS&dur=$DUR&rc=q&qv=4$NOISE_Q"
    RESULT=$(./run-bench.sh "$URL" "$DUR")
    echo "$RESULT" | tee -a "$LOG"
done
