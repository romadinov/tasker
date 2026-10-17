# Tasker

An OmniFocus-style task manager for Mac, iPhone and iPad whose sync is built so it can't get stuck.

## Why sync keeps working

- **Every edit is an immutable operation** with a unique id (device replica + counter) and a hybrid logical clock timestamp. State is a last-writer-wins register per field; tags on a task are one register per tag, so tags added on two devices both survive.
- **Merging is a set union.** Applying ops is idempotent and order-independent, so late, duplicated or out-of-order delivery gives the same result. The randomized tests in `ConvergenceTests` check this across three replicas.
- **No server-side conflicts.** In CloudKit each device only *creates* immutable batch records (`OpBatch`) and never edits shared ones.
- **Gaps are detected.** Each device publishes a `Head` record saying how many of its ops are uploaded. If another device announces changes this one doesn't have for more than 3 minutes, a full re-fetch runs automatically (at most every 30 minutes). Sync → *Repair Sync* does the same on demand.
- **The cloud can be rebuilt.** If the iCloud zone is deleted or the account changes, the device re-uploads the complete history it holds.
- **Escape hatches:** daily local backups (`Backups/` next to the database), and *Export / Merge Database File* for transfer by AirDrop with no iCloud at all.
- Concurrent moves that would form a cycle are broken the same way on every device. Children added under an item deleted elsewhere land in the Inbox instead of disappearing.

## Layout

| Path | What |
|---|---|
| `Packages/TaskerCore` | CRDT, SQLite store, snapshot/availability, perspective engine (OmniFocus rule dialect), repeats (RRULE), quick-entry parser, OmniFocus importer, CloudKit sync |
| `App/Shared` | SwiftUI app shared by macOS and iOS/iPadOS |
| `App/macOS` | Global hotkeys, Quick Entry panel, Clipper, Services menu, settings, OmniFocus import UI |
| `App/iOS` | App delegate (push and background refresh) |
| `ShareExtension` | iOS share sheet capture, which writes to the shared database and uploads immediately |

## Build

```sh
brew install xcodegen      # once
xcodegen generate
open Tasker.xcodeproj      # run TaskerMac or TaskerIOS
cd Packages/TaskerCore && swift test
```

One-time signing setup: Xcode → Settings → Accounts → add your Apple ID (team `SZVSSCJQFN`). The first signed build registers the bundle ids, the `iCloud.com.romadinov.tasker` container and the `group.com.romadinov.tasker` app group.

### CloudKit environment (important)

Builds run from Xcode use the CloudKit **Development** environment. TestFlight/App Store/Developer ID builds use **Production**. Devices in different environments never see each other's data. Before shipping a non-Xcode build, open the CloudKit Console → *Deploy Schema Changes* (record types `OpBatch`, `Head`), and make sure every device runs a build from the same environment.

## Import from OmniFocus

Mac app → Settings → Import → *Read from OmniFocus*. This runs an Omni Automation script inside OmniFocus, so ids, hierarchy, repeat rules, review intervals and custom perspective rules come across exactly. Re-importing refreshes items instead of duplicating them. The data then syncs to your other devices.

`scripts/omnifocus-export.sh out.json` produces the same export from the command line.

## Shortcuts

| | |
|---|---|
| ⌃⌥Space | Quick Entry from any app (configurable) |
| ⌃⌥⌘Space | Clip from the front app: browser page, Mail message link, or selected text (configurable) |
| Services → Send to Tasker | Selected text from any app |
| ⌘N / ⇧⌘N / ⌥⇧⌘N | New action / project / folder |
| ↩ | Edit title (↩ again adds the next sibling) |
| ⌘K | Complete |
| ⇧⌘L | Flag |
| ⌘] / ⌘[ | Indent / outdent |
| ⌃⌘↑ / ⌃⌘↓ | Move up / down |
| ⇧⌘M | Move to… |
| ⌘1–⌘6 | Inbox, Projects, Tags, Forecast, Flagged, Review (⌘7–9: first perspectives) |

Quick-entry shorthand: `#tag ::project ! due:fri defer:tomorrow plan:+3d ~30m`

## MCP server (macOS)

`Tasker.app/Contents/MacOS/tasker-mcp` is a stdio MCP server (dual-era: 2026-07-28 per-request `_meta` and legacy `initialize`). It opens the app's database with its own replica id, so its edits are ordinary CRDT ops: the app merges them immediately and syncs them via iCloud. Setup snippets are in Settings → MCP.

```sh
claude mcp add --scope user tasker -- "/Applications/Tasker.app/Contents/MacOS/tasker-mcp"
```

Tools: `list_perspectives`, `get_perspective_items`, `search_tasks`, `get_task`, `list_projects`, `list_tags`, `create_task`, `update_task`, `complete_task`, `drop_task`, `create_project`, `mark_reviewed`. Set `TASKER_DB=/path/to/copy.sqlite` to point it at a test database.
