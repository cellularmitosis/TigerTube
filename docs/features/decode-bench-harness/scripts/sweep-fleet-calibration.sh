#!/bin/bash
# Research questions (Phase B — shallow probe across the fleet):
#
#   Q1. Does sustained Mpx/s scale linearly with clock frequency
#       within a CPU generation? (If yes, auto-calibration needs
#       no runtime benchmark — just sysctl hw.cpufrequency and a
#       per-generation constant.)
#   Q2. Does AltiVec (G4+) move the per-MHz constant?
#   Q3. Does Leopard behave like Tiger at matched generation/clock?
#   Q4. Does the second core on mdd contribute beyond a single-core
#       G4 at the same clock?
#
# Runs a stripped-down sweep on every machine in the fleet. Each
# machine gets 8 bench points (4 geometries × 2 sources). Results
# append to results/sweep-fleet-calibration-<host>.log for later
# per-machine analysis.
#
# Order: extremes first (pmacg3 = slowest G3, imacg52 = fastest G5),
# then middle G3s, then G4s and mdd. If the extremes fit H4, the
# middle data should fit the curve cleanly; if not, middle data
# pinpoints where the non-linearity lives.
#
# Total wall-clock: ~100s per machine × 9 machines ≈ 15 minutes.
#
# Override the host list via FLEET env var (space-separated).

set -u

cd "$(dirname "$0")"
mkdir -p ../results

PROXY="${PROXY:-http://uranium.local:5002}"
DUR="${DUR:-10}"

FLEET="${FLEET:-pmacg3 imacg52 ibookg32 ibookg3 ibookg37 imacg3 emac pbookg42 mdd}"

for HOST in $FLEET; do
    LOG=../results/sweep-fleet-calibration-${HOST}.log
    echo "# sweep-fleet-calibration $HOST at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
    echo "=== machine: $HOST ==="

    for HW in "240x180" "320x240" "480x360" "640x480"; do
        W=${HW%x*}
        H=${HW#*x}
        for SRC in testsrc2 mandelbrot; do
            # Mandelbrot caps at -t 180 due to filter cache limits; our
            # DUR is well under that, but keep the note explicit in case
            # someone bumps DUR without reading the plan.
            URL="$PROXY/bench?source=$SRC&w=$W&h=$H&fps=30&dur=$DUR&rc=q&qv=4"
            RESULT=$(BENCH_HOST=$HOST ./run-bench.sh "$URL" "$DUR")
            echo "$RESULT" | tee -a "$LOG"
        done
    done
done
