#!/bin/bash
# Builds the Mac app and installs it to /Applications (the copy you use day to day).
# Running from /Applications means later builds in ./build can't disturb the running app.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"   # Debug = iCloud Development environment (same as Xcode-run iOS builds)
xcodegen generate >/dev/null
xcodebuild -project Tasker.xcodeproj -scheme TaskerMac -configuration "$CONFIG" -derivedDataPath build -allowProvisioningUpdates build | grep -E "error:|BUILD" || true
pkill -x Throughline 2>/dev/null || true
pkill -x Tasker 2>/dev/null || true          # the app's former name
rm -rf /Applications/Tasker.app
sleep 1
rm -rf /Applications/Throughline.app
ditto "build/Build/Products/$CONFIG/Throughline.app" /Applications/Throughline.app
open /Applications/Throughline.app
echo "Installed /Applications/Throughline.app ($CONFIG)"
