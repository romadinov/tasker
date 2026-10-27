#!/bin/bash
# Builds a Developer ID-signed, notarized Mac app (iCloud Production) into build/release/Uberdoer.app.
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
  -archivePath build/archive-mac/Uberdoer.xcarchive -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" archive | grep -E "error:|ARCHIVE" || true
xcodebuild -exportArchive -archivePath build/archive-mac/Uberdoer.xcarchive \
  -exportOptionsPlist scripts/export/DeveloperID.plist -exportPath build/release -allowProvisioningUpdates | grep -E "error:|EXPORT" || true
ditto -c -k --keepParent build/release/Uberdoer.app build/release/Uberdoer.zip
xcrun notarytool submit build/release/Uberdoer.zip --keychain-profile tasker-notary --wait
xcrun stapler staple build/release/Uberdoer.app
# Re-zip so the download carries the stapled ticket (Gatekeeper accepts it offline).
rm build/release/Uberdoer.zip && ditto -c -k --keepParent build/release/Uberdoer.app build/release/Uberdoer.zip
echo "Notarized: build/release/Uberdoer.app (zip: build/release/Uberdoer.zip)"
echo "Publish: git tag vX.Y.Z && git push origin vX.Y.Z && gh release create vX.Y.Z build/release/Uberdoer.zip --verify-tag"
