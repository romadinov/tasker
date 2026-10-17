#!/bin/bash
# Builds a Developer ID-signed, notarized Mac app (iCloud Production) into build/release/Tasker.app.
# Mac TestFlight/App Store require the App Sandbox, which would break the clipper (Accessibility,
# Apple Events, synthetic ⌘C/L), global capture from other apps and the OmniFocus import — so the
# Mac app ships via Developer ID instead.
# One-time: xcrun notarytool store-credentials tasker-notary --apple-id <you> --team-id SZVSSCJQFN
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
xcodegen generate >/dev/null
rm -rf build/archive-mac build/release
xcodebuild -project Tasker.xcodeproj -scheme TaskerMac -configuration Release \
  -archivePath build/archive-mac/Tasker.xcarchive -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" archive | grep -E "error:|ARCHIVE" || true
xcodebuild -exportArchive -archivePath build/archive-mac/Tasker.xcarchive \
  -exportOptionsPlist scripts/export/DeveloperID.plist -exportPath build/release -allowProvisioningUpdates | grep -E "error:|EXPORT" || true
ditto -c -k --keepParent build/release/Tasker.app build/release/Tasker.zip
xcrun notarytool submit build/release/Tasker.zip --keychain-profile tasker-notary --wait
xcrun stapler staple build/release/Tasker.app
echo "Notarized: build/release/Tasker.app — install with: ditto build/release/Tasker.app /Applications/Tasker.app"
