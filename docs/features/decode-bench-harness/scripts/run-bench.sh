#!/bin/bash
# Research question: none — this is the helper that every sweep calls.
#
# Runs one bench against imacg3. Takes a bench URL and an optional
# duration (seconds). SSHes to imacg3, launches TigerTube in bench
# mode, captures the single BENCH: line from stderr.
#
# Usage:
#   run-bench.sh <bench-url> [duration-seconds]
#
# Example:
#   run-bench.sh 'http://uranium.local:5002/bench?source=testsrc2&w=320&h=240&fps=30&dur=10&rc=q&qv=4' 10
#
# Assumes:
#   - TigerTube Debug build is up-to-date on imacg3 at ~/tmp/TigerTube/
#   - Proxy is running on uranium and advertised on the LAN
#
# Prints the BENCH: line to stdout, prefixed with the URL for
# provenance. Exit code is 0 if a BENCH: line was captured, 1 if not.

set -u

URL="${1:?bench URL required as first arg}"
DUR="${2:-10}"

HOST="${BENCH_HOST:-imacg3}"
BIN="${BENCH_BIN:-\$HOME/tmp/TigerTube/build/Debug/TigerTube.app/Contents/MacOS/TigerTube}"

# Kill any running instance, then run the bench foregrounded and grep stderr.
# Single-quote the URL for the remote shell so & stays literal.
LINE=$(ssh "$HOST" "killall TigerTube 2>/dev/null; sleep 0.3; \
    $BIN --bench-url='$URL' --bench-duration=$DUR 2>&1 | grep '^BENCH:'" \
    | head -n1)

if [ -z "$LINE" ]; then
    echo "URL: $URL  FAILED (no BENCH: line)"
    exit 1
fi

echo "URL: $URL  $LINE"
