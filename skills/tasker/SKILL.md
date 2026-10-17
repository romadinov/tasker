---
name: tasker
description: Work with the user's Tasker task manager (an OmniFocus-style app on Mac/iPhone/iPad) through its MCP server — capture actions, process the Inbox, plan the day from Forecast/Flagged, run the weekly project Review, and find or update tasks. Use when the user says things like "add a task", "remind me to…", "what's on my plate today", "process my inbox", "do my weekly review", "what's in project X", "flag/defer/complete …", or mentions Tasker, perspectives, projects, tags or the Inbox.
---

# Tasker

Tasker is the user's task manager. Its MCP server (`tasker`, tools listed below) reads and writes the same
database as the app; changes appear in the app immediately and sync to the user's other devices via iCloud.

## Before anything: check the tools are connected

If no `tasker` MCP tools are available, don't improvise. Tell the user to connect it (Tasker → Settings → MCP has
the exact command), typically:

```
claude mcp add --scope user tasker -- "/Applications/Tasker.app/Contents/MacOS/tasker-mcp"
```

## Concepts (OmniFocus model)

- **Inbox** — unfiled actions. **Projects** live in folders and are written `Folder : Project`
  (e.g. `Common : Домашние дела`). Project types: parallel, sequential (only the first action is available),
  single actions.
- **Tags** are contexts (Home, Errands, Mac, People…). Some tags have locations (Nearby).
- **Defer** = hide until; **Due** = deadline (default 17:00); **Planned** = intended day (default 09:00).
- **Available** = can be done now (not deferred, not blocked by a sequential project, project active, tag not on hold).
- **Perspectives** are saved views: built-ins `inbox`, `flagged`, `forecast`, `available`, `review`, `projects`,
  plus the user's custom ones (call `list_perspectives`; e.g. "Today", "Work", "Не работа").
- The user writes in **Russian and English** and sometimes in the wrong keyboard layout; search and project/tag
  matching already tolerate typos and layout mix-ups, so pass their words through as-is.

## Tools

| Read | Write |
|---|---|
| `list_perspectives`, `get_perspective_items {perspective, limit}` | `create_task {title, note, project, tags, flagged, defer, due, planned, estimate_minutes}` |
| `search_tasks {query, include_completed, limit}` | `update_task {id, title, note, append_note, project, add_tags, remove_tags, flagged, defer, due, planned, estimate_minutes}` |
| `get_task {id}` (note + children) | `complete_task {id, undo}`, `drop_task {id, undo}` |
| `list_projects {folder, include_completed}`, `list_tags` | `create_project {path, type, note}`, `mark_reviewed {project}` |

Dates accept ISO 8601 or natural forms: `today`, `tomorrow`, `fri`, `+3d`, `+2w`, `2026-11-02`; `""` clears.
`create_task` titles may also use shorthand: `#tag ::project ! due:fri ~30m`.

## Ground rules

1. **Find ids first.** Never guess an id — use `search_tasks`, `get_perspective_items` or `list_projects`.
   If a search returns several plausible matches, ask which one.
2. **Confirm before completing, dropping or bulk changes.** Creating a single task the user dictated, or a single
   explicit edit ("flag the dentist task"), needs no confirmation. Anything touching more than one item, or
   completing/dropping, gets a short summary and a yes first. Both complete and drop are reversible with `undo: true`.
3. **Keep the user's wording** for titles and notes. Put links in the note, first.
4. **Projects:** prefer existing ones (`list_projects`); only create a project (`Folder : Name`) when the user agrees
   or clearly asks. Don't invent tags either — reuse existing tags unless asked.
5. **Report back briefly** with what changed (title → project, tags, dates), not raw JSON.

## Workflows

### Quick capture
User: "Add: call Anna about the lease, next Tuesday, phone"
→ `create_task {title: "Call Anna about the lease", due: "tue", tags: ["Phone"]}` → reply with one line:
"Added *Call Anna about the lease* — Inbox, #Phone, due Tue 17:00."
If the user names a project loosely ("for the house"), pass it as `project`; the server fuzzy-matches.

### Process the Inbox
1. `get_perspective_items {perspective: "inbox", limit: 30}`; also `list_projects` and `list_tags` once.
2. Propose a batch (≤10 items) as a table: item → project, tags, dates, or "do now / drop?". Base suggestions on
   titles, notes (links tell a lot) and existing project names.
3. On approval apply with `update_task` (project + add_tags + dates). Leave items the user skipped untouched.
4. Repeat with the next batch until done or the user stops. Finish with how many were filed.

### Plan today
1. `get_perspective_items` for `forecast` (overdue + due/planned soon), `flagged`, and the user's "Today"
   perspective if it exists (check `list_perspectives`).
2. Summarise: overdue first, then due today, then flagged/available, grouped by project; keep it scannable.
3. Offer concrete moves: defer what won't happen today (`update_task {defer: "tomorrow"}`), flag the top 3.

### Weekly review
1. `get_perspective_items {perspective: "review"}` — projects due for review.
2. For each project (one at a time): `get_task {id}` to see its actions. Point out: stalled (no available actions),
   overdue items, actions that look done, missing next action. Ask the user what to change.
3. Apply edits, then `mark_reviewed {project}`, and move to the next. Stop whenever the user wants.

### Find things
"What's in Самообразование?" → `list_projects {folder: "Самообразование"}` or `search_tasks`.
"What did I do last week?" → `get_perspective_items {perspective: "Completed"}` (custom) or
`search_tasks {include_completed: true}`.
