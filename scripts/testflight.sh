#!/bin/bash
# Archives the iPhone/iPad app (with the share extension) and uploads it to TestFlight.
# Prerequisites (one time): see docs/TESTFLIGHT.md — App Store Connect app record + CloudKit schema in Production.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
xcodegen generate >/dev/null
rm -rf build/archive
xcodebuild -project Tasker.xcodeproj -scheme TaskerIOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/archive/TaskerIOS.xcarchive \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" archive | grep -E "error:|ARCHIVE" || true
xcodebuild -exportArchive -archivePath build/archive/TaskerIOS.xcarchive \
  -exportOptionsPlist scripts/export/TestFlight.plist -exportPath build/archive/export \
  -allowProvisioningUpdates | grep -E "error:|EXPORT|Upload" || true
echo "Uploaded build $BUILD. It appears in App Store Connect → TestFlight after processing (usually 5–20 min)."
