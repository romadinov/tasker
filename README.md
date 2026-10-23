# Uberdoer

> Not affiliated with or endorsed by The Omni Group. OmniFocus is a trademark of The Omni Group; it is mentioned
> only to describe Uberdoer's import feature.

A GTD-style task manager for Mac, iPhone and iPad, with OmniFocus import, and sync built so it can't get stuck.

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

## Install on your Mac

```sh
brew install xcodegen          # once
scripts/install-mac.sh         # builds and installs /Applications/Uberdoer.app (iCloud Development)
```

Always run the copy in /Applications: rebuilding in `./build` replaces files under a running app and macOS
will kill it. For TestFlight (iPhone/iPad) and notarized Mac releases see [docs/TESTFLIGHT.md](docs/TESTFLIGHT.md).

## Use Uberdoer from Claude (MCP server + skill)

1. **Connect the MCP server** (also shown, with a Copy button, in Uberdoer → Settings → MCP):
   ```sh
   claude mcp add --scope user uberdoer -- /Applications/Uberdoer.app/Contents/MacOS/uberdoer-mcp
   ```
   Claude Desktop: add to `~/Library/Application Support/Claude/claude_desktop_config.json`
   ```json
   { "mcpServers": { "uberdoer": { "command": "/Applications/Uberdoer.app/Contents/MacOS/uberdoer-mcp" } } }
   ```
2. **Install the skill** — teaches Claude the Uberdoer workflows (capture, Inbox processing, plan today,
   weekly review) and safety rules (confirm before completing/dropping or bulk edits):
   ```sh
   mkdir -p ~/.claude/skills/tasker
   cp skills/tasker/SKILL.md ~/.claude/skills/tasker/
   ```
   Claude Desktop / claude.ai: zip the `skills/tasker` folder and upload it under Settings → Capabilities → Skills.
3. Try: "what's on my plate today?", "process my inbox", "add: call Anna tomorrow #phone",
   "do my weekly review".

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
| Services → Send to Uberdoer | Selected text from any app |
| ⌘N / ⇧⌘N / ⌥⇧⌘N | New action / project / folder |
| ↩ | New action below the selected row, in edit mode (↩ while editing adds the next one) |
| Double-click | Edit an item's name (actions, projects, folders, tags) |
| Space | Complete (in the list) |
| F / ⇧⌘L | Flag |
| ⌘K | Clean Up |
| ⌃⌥⇧Space | Quick Clip (saves straight to the Inbox) |
| ⌃⌥V | Voice Entry: Quick Entry that starts listening; Return saves to the Inbox (configurable) |
| ⌘D in Quick Entry | Dictate (mic button; its menu picks the language) |
| ⌘] / ⌘[ | Indent / outdent (actions, projects into folders, folders, tags) |
| ⇧⌘] / ⇧⌘[ | Add Inside (new subtask) / Add Outside |
| ⌃⌘↑ ↓ ← → | Move up / down / left / right (works on a multi-selection) |
| ⌥⌘G / ⌥⌘U | Group into an action group or folder / Ungroup |
| Organize → Sort Once | Sort a project's, folder's or tag's children (or the selected rows) by title, status or a date |
| ⇧⌘M | Move to… |
| ⌘1–⌘7 | Inbox, Projects, Tags, Forecast, Flagged, Nearby, Review (⌘8–9: first perspectives) |
| ⌃⌘B | Board (Kanban): columns are stages you define (Edit Stages…); drag cards between them |
| ⌃⌘P | Start a pomodoro on the selected action (also right-click → Start Pomodoro); timer in the menu bar and above every view, optional ticking |
| ⌥⌘[ / ⌥⌘] | Back / Forward |
| ⇧⌘F | Focus |
| ⌥⌘I / ⌃⌘S | Inspector / Sidebar |
| Return / Tab in row fields | Project → Tags → Flag |

Quick-entry shorthand: `#tag ::project ! due:fri defer:tomorrow plan:+3d ~30m`

## MCP server (macOS)

`Uberdoer.app/Contents/MacOS/uberdoer-mcp` is a stdio MCP server (dual-era: 2026-07-28 per-request `_meta` and legacy `initialize`). It opens the app's database with its own replica id, so its edits are ordinary CRDT ops: the app merges them immediately and syncs them via iCloud. Setup snippets are in Settings → MCP.

```sh
claude mcp add --scope user uberdoer -- "/Applications/Uberdoer.app/Contents/MacOS/uberdoer-mcp"
```

Tools: `list_perspectives`, `get_perspective_items`, `search_tasks`, `get_task`, `list_projects`, `list_tags`, `create_task`, `update_task`, `complete_task`, `drop_task`, `create_project`, `mark_reviewed`. Set `TASKER_DB=/path/to/copy.sqlite` to point it at a test database.

## Sending items from other apps (`uberdoer://add`)

Mac, iPhone and iPad register the `tasker` URL scheme:

```
uberdoer://add?title=<text>&note=<text>&url=<link>&project=<"Folder : Project" or name>&tags=<a,b>
            &flagged=1&due=<ISO or "fri"/"+3d">&defer=…&planned=…&quick=1&x-success=<return URL>
```

Without `quick` Quick Entry opens pre-filled; with `quick=1` the item is saved straight to the Inbox and `x-success`
(if given) is opened afterwards, returning to the calling app. `url` becomes the first line of the note, and app links
with custom schemes (e.g. `scriptorium://…`, `message://…`) are shown as tappable links.

**Scriptorium**: on the Mac the clip hotkeys send Scriptorium ⌃⌘C ("Copy Link") and capture the book/page title, the
deep link and any selected text; on iPhone/iPad use Scriptorium's "Send to Uberdoer" or the share sheet.

**Share menu (Mac)**: Uberdoer appears in every app's Share menu (Safari, Finder, Scriptorium's "Share Link to Page"…).
The extension is sandboxed, so it hands the item to the app through `uberdoer://add?quick=1`. If it's missing, enable it
in System Settings → General → Login Items & Extensions → Sharing. On iPhone/iPad Uberdoer is in the share sheet.

`uberdoer://task/<id>` opens Uberdoer on that task (selected, in its project or the Inbox), on Mac, iPhone and iPad. The id is the one the MCP tools return.

`uberdoer://clip` (Mac) runs the clipper on the frontmost app — `?quick=1` saves straight to the Inbox, `?dry=1` only
shows what would be captured. Handy from Shortcuts or Keyboard Maestro (use `open -g` so Uberdoer stays in the background).
