# Shipping Uberdoer: TestFlight (iPhone/iPad) and Developer ID (Mac)

## Why two channels

- **iPhone/iPad → TestFlight.** Standard path.
- **Mac → Developer ID (notarized), not TestFlight.** Mac TestFlight/App Store builds must be sandboxed. The
  sandbox blocks what makes the Mac app useful: clipping from other apps (Accessibility, Apple Events to
  Safari/Mail, synthetic ⌘C/L for Mimestream and Slack), the OmniFocus import (`osascript`), and the bundled
  MCP server reading the app's database. A notarized Developer ID build keeps all of that and installs without
  warnings.

## The one thing that must not be missed: iCloud environments

Xcode **Debug** builds use the CloudKit **Development** environment. Archived builds (TestFlight, App Store,
Developer ID) use **Production**. They are separate databases, so devices only see each other when they are on
the same environment.

Switching is safe: each device records which environment it last synced with; when that changes it re-uploads
its complete history to the new one (merging is idempotent, so nothing duplicates). Move all devices together:

1. Mac: `scripts/release-mac.sh` (or `scripts/install-mac.sh Release` for a local Production build). On first
   launch it uploads everything into Production.
2. iPhone/iPad: install the TestFlight build. They download from Production (the first-sync banner shows progress).

## One-time setup

1. **CloudKit schema → Production.** Open <https://icloud.developer.apple.com> → container
   `iCloud.com.romadinov.tasker` → *Schema* → *Deploy Schema Changes…* → Deploy to Production. Record types:
   `OpBatch` (`replica`, `first`, `last`, `count`, `payload` bytes, `asset`) and `Head` (`last`, `device`,
   `platform`, `updated`). Production rejects record types that weren't deployed, so do this before the first
   TestFlight install.
2. **App Store Connect app record.** <https://appstoreconnect.apple.com> → *Apps* → *+* → *New App*:
   platform iOS, bundle ID `com.romadinov.tasker`, SKU e.g. `tasker-ios`. The display name must be unique on the
   App Store ("Uberdoer" is likely taken); the name in App Store Connect can differ from the home-screen name.
3. **TestFlight testers.** App → *TestFlight* → *Internal Testing* → add yourself. Internal builds need no review.
4. **Mac notarization credentials** (for `release-mac.sh`):
   `xcrun notarytool store-credentials tasker-notary --apple-id <apple id> --team-id SZVSSCJQFN`
   (uses an app-specific password from <https://account.apple.com>).

## Each release

```sh
scripts/testflight.sh      # iPhone + iPad (+ share extension) → TestFlight
scripts/release-mac.sh     # Mac → build/release/Uberdoer.app, notarized
```

Build numbers are timestamps, so every upload is unique. Export compliance is pre-answered
(`ITSAppUsesNonExemptEncryption = NO`: only Apple's standard encryption via HTTPS/CloudKit).
