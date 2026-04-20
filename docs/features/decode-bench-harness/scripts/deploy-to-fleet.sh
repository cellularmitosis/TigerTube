#!/bin/bash
# Build TigerTube once on BUILD_HOST (default: ibookg37, the fastest
# G3 in the fleet), then rsync the built Debug .app to every other
# fleet machine. Uses tiger-rsync.sh uniformly for all targets
# (Tiger and Leopard alike) per the plan's E6 assumption.
#
# Why ibookg37 (900 MHz G3):
#   - Fastest G3 available. Builds faster than other G3s.
#   - Building on a G3 guarantees the resulting ppc binary doesn't
#     inadvertently pick up G4/G5-only codegen.
#   - Running the G3-built binary on G4/G5 is itself a compatibility
#     test of CLAUDE.md's "single ppc binary, runtime-detected
#     AltiVec" assumption.
#
# Why a two-step deploy (build-host -> uranium -> each target):
#   tiger-rsync.sh runs locally on uranium and talks to one remote at
#   a time. Going host-to-host directly would bypass tiger-rsync.sh's
#   Tiger-compatibility flags.
#
# Usage:
#   ./deploy-to-fleet.sh                  # build Debug, deploy to all
#   CONFIG=Release ./deploy-to-fleet.sh   # build Release instead
#   BUILD_HOST=imacg52 ./deploy-to-fleet.sh  # build on G5 instead
#   FLEET="emac mdd" ./deploy-to-fleet.sh    # deploy to a subset
#
# Env vars:
#   BUILD_HOST   Host to build on.           (default: ibookg37)
#   CONFIG       Xcode configuration.         (default: Debug)
#   FLEET        Space-separated target list. (default: all but build host)
#   STAGE        Local staging dir on uranium. (default: /tmp/tigertube-fleet)

set -eu

BUILD_HOST="${BUILD_HOST:-ibookg37}"
CONFIG="${CONFIG:-Debug}"
STAGE="${STAGE:-/tmp/tigertube-fleet}"

# Default fleet: every fleet machine except the build host.
DEFAULT_FLEET="pmacg3 ibookg32 imacg3 ibookg37 ibookg3 pbookg42 emac mdd imacg52"
FLEET_ALL="${FLEET:-$DEFAULT_FLEET}"
FLEET=""
for HOST in $FLEET_ALL; do
    if [ "$HOST" != "$BUILD_HOST" ]; then
        FLEET="$FLEET $HOST"
    fi
done

TIGER_RSYNC="${TIGER_RSYNC:-$HOME/bin/tiger-rsync.sh}"

echo "=== build on $BUILD_HOST ($CONFIG) ==="
ssh "$BUILD_HOST" "cd tmp/TigerTube && xcodebuild -configuration $CONFIG" \
    | tail -n5

echo "=== stage $BUILD_HOST:build/$CONFIG/TigerTube.app -> $STAGE ==="
rm -rf "$STAGE"
mkdir -p "$STAGE"
"$TIGER_RSYNC" "$BUILD_HOST:tmp/TigerTube/build/$CONFIG/TigerTube.app/" \
               "$STAGE/TigerTube.app/"

for HOST in $FLEET; do
    echo "=== deploy $STAGE/TigerTube.app -> $HOST ==="
    # Ensure the target's build dir exists. run-bench.sh and the normal
    # dev loop expect ~/tmp/TigerTube/build/$CONFIG/TigerTube.app on
    # every host.
    ssh "$HOST" "mkdir -p tmp/TigerTube/build/$CONFIG"
    "$TIGER_RSYNC" "$STAGE/TigerTube.app/" \
                   "$HOST:tmp/TigerTube/build/$CONFIG/TigerTube.app/"
done

echo "=== done. deployed to:$FLEET ==="
