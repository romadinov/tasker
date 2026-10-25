# Uberdoer — product and technical spec

Living spec of what Uberdoer does and the contracts other code relies on. When behaviour changes, update this file
in the same commit. Lessons behind many of these decisions are in [LESSONS.md](LESSONS.md).

## 1. Product

A GTD task manager for Mac, iPhone and iPad that replaces OmniFocus for one user. Priorities, in order:

1. **Sync that never gets stuck** (the reason the project exists).
2. **OmniFocus-like speed of capture and processing**: global hotkeys, clipper, Quick Entry, inline row editing,
   perspectives.
3. **Things OmniFocus lacks**: Board (Kanban), Pomodoro, Analytics, speech entry, companion-app API.

### 1.1 Views (rail, left to right)

| View | What it shows |
|---|---|
| Inbox | Unfiled actions, outline (subtasks). Filed/completed items stay in place until Clean Up. |
| Projects | Folders → projects → actions outline; sidebar tree (context menu: Complete Project / Mark Active, Status, Rename, Convert to Action; a project completed there stays listed until Clean Up or a view change); Remaining/Available/Everything filter. |
| Tags | Actions per tag; sidebar tag tree. |
| Forecast | Past (overdue), a day strip (12 days) and Future; calendar events; **Today** also lists available flagged actions. Order: flagged & available, other available, not yet available. The selected day follows "today" unless the user picks another day. |
| Flagged | Remaining, unblocked flagged actions grouped by project. |
| Review | Projects whose review is due; Mark Reviewed advances. |
| Nearby | Actions whose tags have locations that apply here (place kinds via Apple Maps, or a fixed location). |
| Board | Kanban: one column per user-defined stage + "Up next" (flagged available actions not on the board). |
| Analytics | Throughput, added vs done, open-actions trend, lead time, weekdays, top projects/tags, focus time, upcoming load, stalled projects. |
| Custom perspectives | OmniFocus `archivedFilterRules` dialect, evaluated by `PerspectiveEngine`. |

Choosing a view clears the search box (a search otherwise replaces the view's content).

### 1.2 Rows and editing (Mac)

- **Click** selects; the selected row opens its fields: Project ▾, Tags, Defer, Due, note.
  Project → Return/Tab → Tags → Tab → Flag; Return on an empty Tags field moves to the next task (Inbox processing).
- **Double-click** edits the title (also folders/projects/tags anywhere via `RenamableName`).
- **Return** on a selected row creates a new action right below it in edit mode (on a project: at its top; on a folder:
  a new project). Return while editing saves and starts the next one.
- **Space** completes, **F** flags — only when no text field is being edited.
- Tags field: each tag has an **×**; Backspace in the empty field removes the last tag; **Escape restores** the tags
  as they were when the field opened; clicking away keeps changes.
- **Keep in place:** in every view, rows edited here (completed, unflagged, re-tagged, re-filed, converted) stay where
  they were until Clean Up (⌘K) or navigating elsewhere. Deletions and explicit moves (Organize, drag) apply at once.
- **No jumping:** when a click changes which row is open, the list scroll is corrected during layout so the clicked row
  stays under the pointer; at the top of the list the previous row stays open instead.
- Items with an on-hold tag only (e.g. Waiting) are drawn normally; deferred/blocked/on-hold-project items are dimmed.

### 1.3 Organize (OmniFocus Organize menu)

Add Inside ⇧⌘], Add Outside ⇧⌘[, Move Up/Down/Left/Right ⌃⌘arrows, Indent ⌘], Outdent ⌘[, Group ⌥⌘G, Ungroup ⌥⌘U,
Sort Once (title, status, added/completed/due/planned/defer/dropped date). Work on multi-selections, folders,
projects and tags. Indent goes into the row *visibly* above when that differs from the outline sibling.
Convert to Project keeps the row in place, expanded, so you can add actions to it; Convert to Action sends a project
to the Inbox as an action with subtasks and opens its Project field.

### 1.4 Completion

Completing a project or action group completes all its open descendants at the same timestamp. Mark Incomplete (or
project status Active) reopens only the ones completed at that moment. Repeating items: completing records a completed
copy (deterministic id) and advances dates; their children stay open.

### 1.5 Capture

| Path | Behaviour |
|---|---|
| ⌃⌥Space | Quick Entry panel (non-activating), OmniFocus layout. |
| ⌃⌥⌘Space / ⌃⌥⇧Space | Clip from front app (review / straight to Inbox): browser URL, Mail/Mimestream message link (subject as title), Slack message, Scriptorium passage link, selected text. Needs Accessibility. |
| ⌃⌥V, mic, ⌘D | Speech entry (see 1.7). iPhone/iPad: mic button above "+". |
| Services, Share menu/sheet, `uberdoer://add` | See §3. |
| Siri / Shortcuts | App Intent "Add to Uberdoer Inbox". |

Quick-entry shorthand in titles: `#tag` (must start with a letter — `#116` stays text), `::project`, `!` flag,
`due:` `defer:` `plan:`, `~30m`. `ЖЖ` = `::` on the Russian layout. Project/tag matching is fuzzy and layout-tolerant.

### 1.6 Pomodoro

Start on an action (right-click or ⌃⌘P). Timer in the Mac menu bar and a bar above every view; live 🍅 badge on the
row/card. Work → break (long after every 4th) → ready. Notifications at phase ends. Optional ticking: a 1-second loop
(1, 2 or 4 identical clicks per second, default 1) played only while focusing; keeps playing in the background
(App Nap disabled during a pomodoro; iOS background audio mode). Mac sleep/lid/screen lock pauses the timer (stays
paused, reason shown). Each finished work session is logged on the action and synced (`pomo:<id>` registers).
Durations are per device.

### 1.7 Speech entry

Engines: **Whisper** (WhisperKit, on-device; default) and **Apple** (`SFSpeechRecognizer`). Whisper model: large-v3
turbo 632 MB on the Mac, the device-recommended model on iPhone/iPad, downloaded on first use into Application
Support; Apple's recogniser is used until it's ready. First load compiles the Core ML model (tens of minutes once),
then ~2 s. Language "Automatic" detects; if Whisper guesses a language other than Russian/English it re-runs in the
keyboard layout's language. Live partial text (re-transcribe every 1.2 s), auto-stop after ~1.6 s of silence,
titles get a capital letter and no trailing period.

### 1.8 Board (Kanban)

Stages are user-defined (Edit Stages…: name, colour, order, "Completes"). Defaults To Do / In Progress / Waiting /
Done (Done completes) with fixed ids so two devices creating them merge. Cards open like rows (fields, double-click
title). Drag between/within columns; Up next → stage puts work on the board; back to Up next takes it off.
Board ▸ menu on every action; stage badge on rows.

## 2. Architecture

| Part | Where |
|---|---|
| CRDT, store, snapshot, perspective engine, commands, importer, sync | `Packages/TaskerCore` |
| SwiftUI app (Mac + iOS) | `App/Shared` (+ `App/macOS`, `App/iOS`) |
| MCP server | `App/MCP/main.swift` → `uberdoer-mcp` |
| Share extensions | `ShareExtension` (iOS), `ShareExtensionMac` (sandboxed; forwards via `uberdoer://add`) |

Internal names stay "Tasker" (bundle ids `com.romadinov.tasker[.mac|.share]`, container `iCloud.com.romadinov.tasker`,
app group `group.com.romadinov.tasker`, data folder `Application Support/Tasker`, team SZVSSCJQFN). Never rename them:
it would orphan synced data.

### 2.1 Data model (CRDT)

- Every edit is an immutable **op** `(replica, counter, HLC, entityType, entityID, field, value)`.
- State = **last-writer-wins register per field**. Tags on a task are one register per tag (`tag:<id>`).
  Pomodoro sessions are one register each (`pomo:<id>`) so sessions from two devices both survive.
- `pos` = `{p: parent, o: fractional order key}` — parent and order move atomically. Concurrent moves that form a cycle
  are broken deterministically (newest member goes to the root).
- Entity types are a **closed enum**: task, folder, tag, perspective, setting. Older builds fail to decode a batch
  containing an unknown type, so new kinds of data use existing types: Board stages are settings `stage:<id>`;
  new task fields (`stage`, `stageOrder`, `externalRef`, `pomo:*`) are ignored by builds that don't know them.
- Task fields: `title note pos kind flagged defer due planned estimate completed dropped sequential autoComplete repeat
  status singleActions reviewEvery nextReview lastReview created deleted tag:<id> stage stageOrder externalRef pomo:<id>`.

### 2.2 Store and snapshot

SQLite (WAL) with `ops`, `registers`, `meta`, `heads`. Multi-process safe: each process role (`app`, `share`, `mcp`,
`import`) has its own replica id. Other processes post the Darwin notification `com.romadinov.tasker.external-change`
and the app pulls new ops. `Snapshot` is an immutable view rebuilt per change (≈11 ms for ~5,000 items): children
sorted by precomputed (order, id), availability/effective dates computed top-down.

### 2.3 CloudKit sync

CKSyncEngine, private DB, zone `Uberdoer`. Each replica uploads immutable `OpBatch` records
`b_<replica>_<first>_<last>` (lzfse JSON, CKAsset when large) and a `Head` record `h_<replica>` (ops uploaded).
Gap detection: a head ahead of what we hold for >3 min triggers a full re-fetch (≤ every 30 min). Zone deletion,
account change or environment change (meta `ck.container` = `id#env`) triggers a full re-upload. Debug builds use the
Development environment, archived builds Production. Daily local backups; Export/Merge database file as an escape hatch.

## 3. External interfaces (contracts)

### 3.1 URL scheme `uberdoer://` (also `throughline://`, `tasker://`)

- `add?title=&note=&url=&project=&tags=a,b&flagged=1&due=&defer=&planned=&quick=1&x-success=&external_ref=&parent=`
  - Without `quick`, Quick Entry opens pre-filled. With `quick=1` the item is saved; `external_ref` reuses an existing
    item with that ref (no duplicate); `parent=<id>` nests it; `x-success` is opened with `id=<task id>` appended.
- `task/<id>` — reveal and select that task (completed ones too) on Mac/iPhone/iPad; "Task not found" otherwise.
- `clip[?quick=1|dry=1]` (Mac) — run the clipper on the front app.

### 3.2 MCP server `uberdoer-mcp` (stdio JSON-RPC, legacy `initialize` and 2026-07-28 `_meta`)

Read: `list_perspectives`, `get_perspective_items`, `search_tasks {query, include_completed, limit=50}` (title + note,
either layout), `get_task`, `list_projects`, `list_tags`, `find_by_external_ref {ref | prefix}`,
`changes_since {since, external_ref_prefix} → {now, items}` (ms-precision cursor).
Write: `create_task {…, parent, external_ref, literal}` (existing `external_ref` → returned unchanged with
`existing: true`), `update_task {…, parent, external_ref}`, `complete_task`/`drop_task {undo}`,
`create_project {path, type, note, external_ref}`, `mark_reviewed`.
Task JSON includes `changed` (ms), `status`, `completed`, `dropped`, `external_ref`, `parent`.
`TASKER_DB=/path` points the server (and the app) at another database.

### 3.3 Change notification

The app posts the Darwin notification **`com.romadinov.uberdoer.changed`** (no payload, at most every 2 s) after any
data change, local or synced. Companion apps debounce it, ignore echoes after their own writes, then re-read.

### 3.4 Companion apps

- **Jinnie** (`~/Dev/jinnie`): pushes next actions and Waiting tasks (`[Person]//[What I need]`, tags Waiting + Jinnie)
  with `external_ref: "jinnie:<id>"`, `literal: true`; observes 3.3; links `jinnie://action/<id>` ↔ `uberdoer://task/<id>`.
- **Mindmapper** (`~/Dev/mindmapper`): mind-map nodes as projects/nested tasks via `parent` and `external_ref "mm:…"`.
- **Scriptorium** (`~/Dev/reader`): "Send to Uberdoer" via `uberdoer://add`; ⌃⌘C Copy Link used by the clipper.
- Any Claude session may ask to file reminders for the user; they're added via MCP.

## 4. Builds and install

- Mac: `scripts/install-mac.sh` → optimised (`-O`, whole-module) Debug-config build → `/Applications/Uberdoer.app`
  (always run that copy). iOS devices: build `TaskerIOS` for `generic/platform=iOS` with the same flags and
  `xcrun devicectl device install app`. TestFlight/Developer ID: [TESTFLIGHT.md](TESTFLIGHT.md).
- Debug harness (`App/macOS/DebugSnapshots.swift`, DEBUG only, env-driven): `TASKER_SNAPSHOT_DIR` (render each step to
  PNG, with synthetic clicks/keys), `TASKER_PERF_TEST`, `TASKER_JUMP_TEST`, `TASKER_LINK_TEST=<url>`,
  `TASKER_TICK_TEST`, `TASKER_WHISPER_TEST=a.wav,…`; always with `TASKER_DB=<copy> TASKER_NO_SYNC=1`.
- Core tests: `cd Packages/TaskerCore && swift test` (58 tests incl. randomized 3-replica convergence).
