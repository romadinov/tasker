#!/bin/bash
# Builds the Mac app and installs it to /Applications (the copy you use day to day).
# Running from /Applications means later builds in ./build can't disturb the running app.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"   # Debug = iCloud Development environment (same as Xcode-run iOS builds)
xcodegen generate >/dev/null
# Always optimised: the Debug configuration only selects the iCloud Development environment here; an
# unoptimised build made every edit and click noticeably slower (snapshot rebuild ~5x).
xcodebuild -project Tasker.xcodeproj -scheme TaskerMac -configuration "$CONFIG" -derivedDataPath build -allowProvisioningUpdates \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule build | grep -E "error:|BUILD" || true
pkill -x Uberdoer 2>/dev/null || true
for old in Tasker Throughline; do pkill -x "$old" 2>/dev/null || true; rm -rf "/Applications/$old.app"; done  # former names
sleep 1
rm -rf /Applications/Uberdoer.app
ditto "build/Build/Products/$CONFIG/Uberdoer.app" /Applications/Uberdoer.app
open /Applications/Uberdoer.app
echo "Installed /Applications/Uberdoer.app ($CONFIG)"
