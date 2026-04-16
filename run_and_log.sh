#!/bin/sh
#
# Launch TigerTube.app with stderr captured to ~/tmp/tigertube.log.
# Intended to be run from /Users/macuser/tmp/TigerTube/ on imacg3.
#
set -e
APP="./build/Debug/TigerTube.app/Contents/MacOS/TigerTube"
LOG="$HOME/tmp/tigertube.log"
mkdir -p "$HOME/tmp"

# Quit any existing instance: graceful AppleScript first, then SIGTERM
# backstop if it's still alive after a brief grace period.
osascript -e 'tell application "TigerTube" to quit' 2>/dev/null || true
sleep 0.3
killall TigerTube 2>/dev/null || true
sleep 0.2

exec "$APP" > "$LOG" 2>&1 &
echo "launched pid=$! -- log: $LOG"
