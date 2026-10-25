# Lessons learnt building Uberdoer

What went wrong (or nearly did), why, and the rule we keep now. Newest themes first within each section.

## Sync and data safety

- **Never add a new CRDT entity type.** `EntityType` is a closed enum; a build that meets an unknown type fails to
  decode the whole OpBatch, so its sync stalls until updated. New kinds of data ride on existing types (Board stages
  as `setting` records `stage:<id>`, pomodoro sessions as task registers `pomo:<id>`). Unknown *fields* are safe.
- **One register per independently-edited thing.** Tags per tag, pomodoro sessions per session: concurrent additions
  on two devices then both survive instead of last-writer-wins dropping one.
- **Deterministic ids for things two devices might create at once** (default Board stages, repeat clones), so they
  merge instead of duplicating.
- **Order keys must be unique within one transaction.** Two inserts into the same column in one transaction got equal
  fractional keys because `base` doesn't include the first; track in-transaction appends (`lastAppended`).
- **"Today" must be computed, not stored.** Forecast stored `startOfDay(Date())` at launch, so after midnight it showed
  an empty yesterday. Store only an explicit user pick; derive today on read.
- **Importer: siblings of different kinds share one order.** OmniFocus numbers folders and projects together in a
  container; ordering them as two lists lost their interleaving. Verify imports against a fresh export diff, not by eye.
- **A no-op re-import writes nothing**, so "I re-imported and nothing changed" can mean the old code ran. Check the op
  log timestamps before debugging the importer.
- **Write to the live database only through `Store`** with its own role (replica id), back it up first
  (`sqlite3 .backup`), and post the external-change notification.

## Performance

- **Install optimised builds.** The daily-driver app was an unoptimised Debug build; the Debug configuration only
  exists to select the CloudKit Development environment. `install-mac.sh` now always passes `-O`/whole-module.
- **Measure before fixing.** Phase timers in `Snapshot.init` showed 15 of 26 ms in child sorting (dictionary lookups
  inside the comparator) — fixed by precomputed sort keys, plus dropping an unneeded sort in cycle breaking.
- **Batch multi-item edits into one transaction** — completing N items as N `perform`s rebuilt the snapshot N times.
- **Don't read high-churn state in every row.** Rows reading `model.selection` all re-rendered on each click; pass
  `isSelected` from the list. Rebuild-per-item panels (inspector) should follow the selection a frame later, coalesced.
- **Profile with the Time Profiler on a release-like build** (`xctrace record --attach <pid>`; xctrace resolves app
  bundles by id and picks /Applications, so launch the test build yourself and attach).

## SwiftUI / AppKit gotchas

- **SwiftUI may create an NSViewRepresentable twice.** An auto-focusing text field's second copy stole focus and the
  first committed an empty edit. Fields editing the same thing share a `focusKey`; a copy that loses focus to another
  copy hands over quietly (checked one run-loop turn later, when focus has settled).
- **A `.draggable` preview builds its view eagerly** — a full card there created a hidden focus-stealing editor.
  Use static previews.
- **Fix layout jumps during layout, not after.** Timer-based scroll corrections were visible; observing the table's
  frame changes corrects before the window draws. Measure jumps by sampling a row's position every 15 ms.
- **List key handlers see keys from text fields inside rows** (`onKeyPress(.space)` completed a task while typing a
  project). Guard on "is any field editing / is the first responder an NSText".
- **Use the list's own double-click** (`contextMenu(forSelectionType:primaryAction:)`) instead of tap gestures on text:
  immediate, and works from an open field.
- **`showSettingsWindow:` no longer opens SwiftUI Settings** — use `@Environment(\.openSettings)`.
- **Changing observable state inside the NSTableView delegate** triggers re-entrancy warnings; one early warning in the
  harness predates our changes — don't chase it blindly.
- **Escape vs losing focus are different intents.** Escape restores (Tags), clicking away keeps changes.

- **Installing a new app doesn't update running MCP servers.** Each Claude session keeps its own long-lived
  `uberdoer-mcp` process on the old binary (and the old tool schema) until the session reconnects (`/mcp`). After
  changing MCP behaviour, tell sessions to reconnect; until then their writes use the old code (e.g. `#127` parsed
  as a tag after the parser fix shipped).

- **A popover anchored to a text field takes that field's focus on iPad** — you got the list or the keyboard, never
  both, so typing didn't filter. Put the search field inside the popover with the list. `arrowEdge: .top` opens it
  below the anchor, away from the keyboard.

## Testing practice

- **The debug harness on a database copy is the main test bench**: render steps to PNG, post real events
  (`NSApp.postEvent`, not `sendEvent`, so tracking loops see the mouse-up), find elements via AX in-process.
- **Synthetic events need realistic timing.** A double-click with zero gap between clicks failed for reasons a human
  never hits; space clicks ~150 ms. Keep each harness step within its 1.2 s slot or the next step resets state.
- **Make the harness bring its window to the front** before clicking, or clicks only activate the app.
- **The harness shares UserDefaults with the real app** (same bundle id). A test that toggled the inspector turned
  the user's inspector off. Never persist settings in harness steps; restore anything touched; avoid mutating steps
  in the permanent harness (keep them temporary) — they could run against a real database.
- **A control experiment proves a fix.** "0 px movement" meant nothing until the same test with the fix disabled
  showed −32 px.
- **iOS flows can be checked on a simulator without tapping**: `TASKER_DEBUG_ACTION=<hook>` via
  `SIMCTL_CHILD_*` env vars on `simctl launch`, then `simctl io … screenshot`.
- **macOS has no `timeout`**; use a background run + polling + `pkill`.
- **Sound/voice can't be verified by ear here** — say so; test the logic (state, background playback, file
  transcription with `say`-generated audio).

## Product / UX lessons from the user

- **Nothing should move under the user's hands** — no jumps on click, edited rows stay put until Clean Up, inline
  fields stay attached. This came up repeatedly; treat any layout shift as a bug.
- **Mirror OmniFocus where the user relies on muscle memory** (Organize menu, shortcuts, Return/Tab chains, rename by
  double-click), then go beyond it.
- **Bilingual input everywhere**: Russian/English and wrong keyboard layout (fuzzy matching, `Ж`→`:`, Whisper language
  detection with keyboard-language fallback).
- **Companion apps and other Claude sessions are first-class users of Uberdoer.** Give them stable contracts
  (external_ref, changes_since, change notification, task links) and document them in SPEC.md.
- **Reminders requested by other sessions get filed** — a task is a note for the user, even if it mentions a command
  that session couldn't run.

## Process

- **Search the web before claiming something is impossible or guessing APIs** (SpeechAnalyzer has no Russian model;
  WhisperKit API checked in its source).
- **Ask for a working precedent before config archaeology.**
- **Commit and push after each user-visible change**; describe the change in user terms in the commit.
- **Install on iPhone/iPad when they're reachable** — they silently fall behind (the user missed voice entry because
  the phone had a weeks-old build).
