#!/bin/bash
# Builds the Mac app and installs it to /Applications (the copy you use day to day).
# Running from /Applications means later builds in ./build can't disturb the running app.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"   # Debug = iCloud Development environment (same as Xcode-run iOS builds)
xcodegen generate >/dev/null
xcodebuild -project Tasker.xcodeproj -scheme TaskerMac -configuration "$CONFIG" -derivedDataPath build -allowProvisioningUpdates build | grep -E "error:|BUILD" || true
pkill -x Tasker 2>/dev/null || true
sleep 1
rm -rf /Applications/Tasker.app
ditto "build/Build/Products/$CONFIG/Tasker.app" /Applications/Tasker.app
open /Applications/Tasker.app
echo "Installed /Applications/Tasker.app ($CONFIG)"
