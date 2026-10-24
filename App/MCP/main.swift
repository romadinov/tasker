import Foundation
import TaskerCore

// uberdoer-mcp — Model Context Protocol server for Uberdoer (stdio, newline-delimited JSON-RPC 2.0).
//
// Works directly on the app's local database with its own replica id, so edits are ordinary
// CRDT ops: the Uberdoer app merges them immediately (Darwin notification) and syncs them via
// iCloud like any other device's changes. Dual-era: modern (2026-07-28, per-request `_meta`,
// `server/discover`) and legacy (`initialize` handshake) clients are both supported.

let modernVersions = ["2026-07-28"]
let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
let serverInfo: JSON = .object(["name": "uberdoer", "title": "Uberdoer", "version": "0.1.0"])
let instructions = """
Uberdoer is the user's task manager. Inbox holds unfiled actions; projects live in folders \
("Folder : Project"); tags are contexts; perspectives are saved views. Dates accept ISO 8601 or natural forms \
like "today", "tomorrow", "fri", "+3d", "2026-11-02". Prefer search_tasks/get_perspective_items to find ids \
before updating. Completing or dropping is reversible from the app.
"""

// MARK: - I/O

func send(_ value: JSON) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func log(_ s: String) { FileHandle.standardError.write("[uberdoer-mcp] \(s)\n".data(using: .utf8)!) }

func reply(_ id: JSON, _ result: JSON) { send(.object(["jsonrpc": "2.0", "id": id, "result": result])) }
func fail(_ id: JSON, _ code: Int, _ message: String, data: JSON? = nil) {
    var err: [String: JSON] = ["code": .number(Double(code)), "message": .string(message)]
    if let data { err["data"] = data }
    send(.object(["jsonrpc": "2.0", "id": id, "error": .object(err)]))
}

// MARK: - Store

let store: Store
do {
    store = try Store(url: TaskerConfig.databaseURL(), role: "mcp")
} catch {
    log("Cannot open database at \(TaskerConfig.databaseURL().path): \(error)")
    exit(1)
}

func snapshot() -> Snapshot {
    try? store.pullNewOps(notify: false) // pick up edits made in the app meanwhile
    return store.snapshot()
}

func commit(_ name: String, _ body: (inout Tx) -> Void) {
    store.transact(name, body)
    TaskerConfig.postExternalChange() // the app merges and uploads to iCloud right away
}

// MARK: - Formatting

let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = .current; return f }()
/// Millisecond precision for change cursors (whole seconds would re-report items changed in the same second).
let isoMS: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; f.timeZone = .current; return f }()
func date(_ d: Date?) -> JSON { d.map { .string(iso.string(from: $0)) } ?? .null }

func taskJSON(_ s: Snapshot, _ t: TaskItem, full: Bool = false) -> JSON {
    let i = s.info[t.id]
    var o: [String: JSON] = [
        "id": .string(t.id),
        "title": .string(t.title),
        "kind": .string(t.isProject ? "project" : "action"),
        "flagged": .bool(t.flagged),
        "status": .string(status(t, i)),
    ]
    if t.isProject {
        o["folder"] = .string(s.folderPath(of: t.id).joined(separator: " : "))
        o["projectStatus"] = .string(t.status.rawValue)
        o["type"] = .string(t.singleActions ? "single actions" : (t.sequential ? "sequential" : "parallel"))
        if let pi = s.projectInfo[t.id] { o["available"] = .number(Double(pi.availableCount)); o["remaining"] = .number(Double(pi.remainingCount)) }
        if let n = t.nextReviewDate { o["nextReview"] = date(n) }
    } else {
        o["project"] = i?.projectID.map { .string(s.qualifiedName(of: $0)) } ?? .string("Inbox")
    }
    let tags = s.tagNames(t.tagIDs)
    if !tags.isEmpty { o["tags"] = .array(tags.map(JSON.string)) }
    if let d = t.deferDate { o["defer"] = date(d) }
    if let d = t.dueDate { o["due"] = date(d) }
    if let d = t.plannedDate { o["planned"] = date(d) }
    if let e = t.estimatedMinutes { o["estimateMinutes"] = .number(Double(e)) }
    if let r = t.repeatRule { o["repeat"] = .string(r.summary) }
    if let c = t.completedAt { o["completed"] = date(c) }
    if let d = t.droppedAt { o["dropped"] = date(d) }
    if let r = t.externalRef { o["external_ref"] = .string(r) }
    if !t.isProject, let p = i?.parentID, s.tasks[p]?.isProject == false { o["parent"] = .string(p) }
    o["changed"] = .string(isoMS.string(from: t.modifiedAt))
    if full {
        o["note"] = .string(t.note)
        o["added"] = date(t.createdAt)
        let kids = s.childIDs(t.id).compactMap { s.tasks[$0] }
        if !kids.isEmpty { o["children"] = .array(kids.map { taskJSON(s, $0) }) }
    } else if !t.note.isEmpty {
        o["note"] = .string(String(t.note.prefix(200)))
    }
    return .object(o)
}

func status(_ t: TaskItem, _ i: TaskInfo?) -> String {
    guard let i else { return "unknown" }
    if i.effectivelyDropped { return "dropped" }
    if i.effectivelyCompleted { return "completed" }
    if i.isAvailable { return "available" }
    if i.isBlocked { return "blocked" }
    if i.isDeferred { return "deferred" }
    return "remaining"
}

// MARK: - Lookups

enum ToolError: Error { case message(String) }

func findTask(_ s: Snapshot, _ id: String?) throws -> TaskItem {
    guard let id, let t = s.tasks[id] else { throw ToolError.message("No task with id \(id ?? "?"). Use search_tasks to find ids.") }
    return t
}

func findProject(_ s: Snapshot, _ name: String) -> TaskItem? {
    if let p = s.project(atPath: name) { return p }
    if let p = s.tasks[name], p.isProject { return p }
    let remaining = s.orderedProjects.filter { s.info[$0.id]?.isRemaining == true }
    return Fuzzy.rank(remaining, name) { p in ([p.title] + s.folderPath(of: p.id)).joined(separator: "  ") }.first
}

func findByExternalRef(_ s: Snapshot, _ ref: String) -> TaskItem? {
    s.tasks.values.first { $0.externalRef == ref }
}

func findOrCreateTag(_ s: Snapshot, _ name: String, tx: inout Tx) -> String {
    if let t = s.tags.values.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) { return t.id }
    return tx.createTag(name)
}

func parseDate(_ s: Snapshot, _ v: JSON?, hour: Int) throws -> Date?? {
    guard let v else { return nil }                 // not provided: leave unchanged
    guard let str = v.string else { return .some(nil) }
    if str.isEmpty { return .some(nil) }           // "" clears
    if let d = iso.date(from: str) { return .some(d) }
    if let d = QuickEntryParser(snapshot: s).date(str, hour: hour) { return .some(d) }
    let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    if let d = det?.firstMatch(in: str, range: NSRange(str.startIndex..., in: str))?.date { return .some(d) }
    throw ToolError.message("Couldn't understand date “\(str)”. Use ISO 8601 or e.g. today, tomorrow, fri, +3d.")
}

// MARK: - Perspectives

let builtins = ["inbox", "flagged", "forecast", "available", "review", "projects"]

func perspectiveItems(_ s: Snapshot, _ name: String) throws -> [TaskItem] {
    let key = name.lowercased()
    let actions = s.tasks.values.filter { !$0.isProject }
    let engine = PerspectiveEngine(s)
    switch key {
    case "inbox":
        return engine.sort(s.inboxIDs.filter { s.info[$0]?.isRemaining == true }, by: .manual).compactMap { s.tasks[$0] }
    case "flagged":
        return engine.sort(actions.filter { s.info[$0.id].map { $0.isRemaining && $0.effectiveFlagged && !$0.isBlocked } ?? false }.map(\.id), by: .due).compactMap { s.tasks[$0] }
    case "forecast":
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: s.now))!
        let ids = actions.filter { t in
            guard s.info[t.id]?.isRemaining == true else { return false }
            return (t.dueDate.map { $0 < horizon } ?? false) || (t.plannedDate.map { $0 < horizon } ?? false)
        }.map(\.id)
        return engine.sort(ids, by: .due).compactMap { s.tasks[$0] }
    case "available":
        return engine.sort(actions.filter { s.info[$0.id]?.isAvailable == true }.map(\.id), by: .manual).compactMap { s.tasks[$0] }
    case "review":
        return s.orderedProjects.filter { s.projectInfo[$0.id]?.needsReview == true }
    case "projects":
        return s.orderedProjects.filter { s.info[$0.id]?.isRemaining == true }
    default:
        guard let p = s.perspectives.first(where: { $0.id == name || $0.name.compare(name, options: .caseInsensitive) == .orderedSame })
                ?? Fuzzy.rank(s.perspectives, name, text: { $0.name }).first else {
            throw ToolError.message("Unknown perspective “\(name)”. Use list_perspectives.")
        }
        return engine.evaluate(p).flatMap(\.taskIDs).compactMap { s.tasks[$0] }
    }
}

// MARK: - Tools

struct Tool {
    let name: String
    let title: String
    let description: String
    let schema: JSON
    let readOnly: Bool
    let run: ([String: JSON]) throws -> JSON
}

func obj(_ props: [String: JSON], required: [String] = []) -> JSON {
    .object(["type": "object", "properties": .object(props), "required": .array(required.map(JSON.string))])
}
func str(_ d: String) -> JSON { .object(["type": "string", "description": .string(d)]) }
func bool(_ d: String) -> JSON { .object(["type": "boolean", "description": .string(d)]) }
func int(_ d: String) -> JSON { .object(["type": "integer", "description": .string(d)]) }
func strArray(_ d: String) -> JSON { .object(["type": "array", "items": .object(["type": "string"]), "description": .string(d)]) }

func limited(_ items: [TaskItem], _ s: Snapshot, _ args: [String: JSON]) -> JSON {
    let limit = args["limit"]?.int ?? 100
    return .object(["count": .number(Double(items.count)), "items": .array(items.prefix(limit).map { taskJSON(s, $0) }),
                    "truncated": .bool(items.count > limit)])
}

let dateHelp = "ISO 8601 or natural (today, tomorrow, fri, +3d, 2026-11-02). Empty string clears."

let tools: [Tool] = [
    Tool(name: "list_perspectives", title: "List perspectives",
         description: "Built-in views (inbox, flagged, forecast, available, review, projects) and the user's custom perspectives.",
         schema: obj([:]), readOnly: true) { _ in
        let s = snapshot()
        return .object(["builtin": .array(builtins.map(JSON.string)),
                        "custom": .array(s.perspectives.map { .object(["id": .string($0.id), "name": .string($0.name)]) })])
    },
    Tool(name: "get_perspective_items", title: "Get perspective items",
         description: "Items shown in a perspective: a built-in name or a custom perspective's name/id.",
         schema: obj(["perspective": str("e.g. inbox, flagged, forecast, available, review, projects, or a custom perspective name"),
                      "limit": int("Max items (default 100)")], required: ["perspective"]), readOnly: true) { a in
        let s = snapshot()
        return limited(try perspectiveItems(s, a["perspective"]?.string ?? "inbox"), s, a)
    },
    Tool(name: "search_tasks", title: "Search tasks",
         description: "Find actions and projects whose title or note contains all words (either keyboard layout).",
         schema: obj(["query": str("Words to find"), "include_completed": bool("Include completed/dropped (default false)"),
                      "limit": int("Max items (default 50)")], required: ["query"]), readOnly: true) { a in
        let s = snapshot()
        let q = a["query"]?.string ?? ""
        let all = a["include_completed"]?.bool ?? false
        let hits = s.tasks.values.filter { t in
            (all || s.info[t.id]?.isRemaining == true) && Fuzzy.containsAllWords(q, in: t.title + " " + t.note)
        }
        var args = a; if args["limit"] == nil { args["limit"] = 50 }
        return limited(PerspectiveEngine(s).sort(hits.map(\.id), by: .manual).compactMap { s.tasks[$0] }, s, args)
    },
    Tool(name: "get_task", title: "Get task", description: "Full details of an action or project, including note and children.",
         schema: obj(["id": str("Task or project id")], required: ["id"]), readOnly: true) { a in
        let s = snapshot()
        return taskJSON(s, try findTask(s, a["id"]?.string), full: true)
    },
    Tool(name: "list_projects", title: "List projects", description: "Projects as \"Folder : Project\" with counts.",
         schema: obj(["include_completed": bool("Include completed/dropped projects"), "folder": str("Only projects under this folder name")]),
         readOnly: true) { a in
        let s = snapshot()
        let all = a["include_completed"]?.bool ?? false
        let folder = a["folder"]?.string?.lowercased()
        let projects = s.orderedProjects.filter { p in
            (all || s.info[p.id]?.isRemaining == true) && (folder == nil || s.folderPath(of: p.id).contains { $0.lowercased() == folder })
        }
        return .array(projects.map { p in
            .object(["id": .string(p.id), "name": .string(s.qualifiedName(of: p.id)), "status": .string(p.status.rawValue),
                     "available": .number(Double(s.projectInfo[p.id]?.availableCount ?? 0)),
                     "remaining": .number(Double(s.projectInfo[p.id]?.remainingCount ?? 0))])
        })
    },
    Tool(name: "list_tags", title: "List tags", description: "Tags (contexts) with status and available-action counts.",
         schema: obj([:]), readOnly: true) { _ in
        let s = snapshot()
        return .array(s.orderedTags.map { e in
            .object(["id": .string(e.tag.id), "name": .string(e.tag.name), "status": .string(e.tag.status.rawValue),
                     "parent": e.tag.position.parent.flatMap { s.tags[$0]?.name }.map(JSON.string) ?? .null,
                     "available": .number(Double((s.tasksByTag[e.tag.id] ?? []).filter { s.info[$0]?.isAvailable == true }.count))])
        })
    },
    Tool(name: "create_task", title: "Create task",
         description: "Add an action. Without a project it goes to the Inbox. The title may use shorthand: #tag ::project ! due:fri.",
         schema: obj(["title": str("Action title"), "note": str("Note (links welcome)"),
                      "project": str("Project as \"Folder : Project\" or a fuzzy name; created if a full path doesn't exist"),
                      "tags": strArray("Tag names (created if missing)"), "flagged": bool("Flag it"),
                      "defer": str(dateHelp), "due": str(dateHelp), "planned": str(dateHelp),
                      "estimate_minutes": int("Estimated duration"),
                      "parent": str("Put it inside this action or project (id): a subtask / nested node. Overrides project."),
                      "external_ref": str("Your own stable id, e.g. \"mindmapper:<node>\". If a task with it exists, that task is returned unchanged (existing: true) instead of creating a duplicate."),
                      "literal": bool("Use the title exactly as given (no #tag ::project ! due: shorthand)")], required: ["title"]), readOnly: false) { a in
        let s = snapshot()
        if let ref = a["external_ref"]?.string, !ref.isEmpty, let existing = findByExternalRef(s, ref) {
            guard case .object(var o) = taskJSON(s, existing, full: true) else { return taskJSON(s, existing, full: true) }
            o["existing"] = .bool(true)
            return .object(o)
        }
        let raw = a["title"]?.string ?? ""
        let parsed = (a["literal"]?.bool ?? false) ? QuickEntryParser.Result(title: raw.trimmingCharacters(in: .whitespacesAndNewlines))
                                                    : QuickEntryParser(snapshot: s).parse(raw)
        guard !parsed.title.isEmpty else { throw ToolError.message("Title is empty.") }
        let parentID = a["parent"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if let parentID, s.tasks[parentID] == nil { throw ToolError.message("No task or project with id \(parentID) for parent.") }
        let deferD = try parseDate(s, a["defer"], hour: 0), dueD = try parseDate(s, a["due"], hour: 17), plannedD = try parseDate(s, a["planned"], hour: 9)
        var newID = ""
        commit("MCP: Create Task") { tx in
            var n = NewTask(title: parsed.title)
            n.note = a["note"]?.string ?? ""
            if let pname = a["project"]?.string, !pname.isEmpty {
                if let p = findProject(s, pname) { n.parent = p.id }
                else if pname.contains(":") { n.parent = tx.createProject(path: pname) }
                else { var p = NewTask(title: pname); p.isProject = true; n.parent = tx.createTask(p) }
            } else { n.parent = parsed.projectID }
            if let parentID { n.parent = parentID }
            n.flagged = (a["flagged"]?.bool ?? false) || parsed.flagged
            n.deferDate = (deferD ?? nil) ?? parsed.deferDate
            n.dueDate = (dueD ?? nil) ?? parsed.dueDate
            n.plannedDate = (plannedD ?? nil) ?? parsed.plannedDate
            n.estimatedMinutes = a["estimate_minutes"]?.int ?? parsed.estimatedMinutes
            var tagIDs = Set(parsed.tagIDs)
            for name in (a["tags"]?.array?.compactMap(\.string) ?? []) + parsed.unknownTags { tagIDs.insert(findOrCreateTag(s, name, tx: &tx)) }
            n.tagIDs = Array(tagIDs)
            newID = tx.createTask(n)
            if let ref = a["external_ref"]?.string, !ref.isEmpty { tx.setTask(newID, F.externalRef, .string(ref)) }
        }
        let after = snapshot()
        return taskJSON(after, try findTask(after, newID), full: true)
    },
    Tool(name: "update_task", title: "Update task",
         description: "Change an action or project. Only provided fields change; empty string clears a date or the note.",
         schema: obj(["id": str("Task id"), "title": str("New title"), "note": str("Replace the note"), "append_note": str("Append to the note"),
                      "project": str("Move to project (\"Folder : Project\" or fuzzy); \"Inbox\" moves to the inbox"),
                      "add_tags": strArray("Tags to add"), "remove_tags": strArray("Tags to remove"), "flagged": bool("Flag or unflag"),
                      "defer": str(dateHelp), "due": str(dateHelp), "planned": str(dateHelp), "estimate_minutes": int("Estimate (0 clears)"),
                      "parent": str("Move inside this action or project (id); \"\" = to the top of its project (or Inbox)"),
                      "external_ref": str("Set your stable id (\"\" clears)")],
         required: ["id"]), readOnly: false) { a in
        let s = snapshot()
        let t = try findTask(s, a["id"]?.string)
        if let p = a["parent"]?.string, !p.isEmpty {
            guard s.tasks[p] != nil else { throw ToolError.message("No task or project with id \(p) for parent.") }
            if p == t.id || s.ancestors(of: p).contains(t.id) { throw ToolError.message("Can't move an item inside itself.") }
        }
        let deferD = try parseDate(s, a["defer"], hour: 0), dueD = try parseDate(s, a["due"], hour: 17), plannedD = try parseDate(s, a["planned"], hour: 9)
        var target: String??
        if let pname = a["project"]?.string {
            if pname.lowercased() == "inbox" || pname.isEmpty { target = .some(nil) }
            else if let p = findProject(s, pname) { target = .some(p.id) }
            else if !pname.contains(":") { throw ToolError.message("No project matches “\(pname)”. Use list_projects, or give a full \"Folder : Project\" path to create one.") }
        }
        commit("MCP: Update Task") { tx in
            if let v = a["title"]?.string, !v.isEmpty { tx.setTask(t.id, F.title, .string(v)) }
            if let v = a["note"]?.string { tx.setTask(t.id, F.note, .string(v)) }
            if let v = a["append_note"]?.string { tx.setTask(t.id, F.note, .string(t.note.isEmpty ? v : t.note + "\n\n" + v)) }
            if let pname = a["project"]?.string, target == nil, pname.contains(":") { tx.move(t.id, to: tx.createProject(path: pname)) }
            else if let target { tx.move(t.id, to: target ?? nil) }
            for name in a["add_tags"]?.array?.compactMap(\.string) ?? [] { tx.setTag(t.id, findOrCreateTag(s, name, tx: &tx), true) }
            for name in a["remove_tags"]?.array?.compactMap(\.string) ?? [] {
                if let tag = s.tags.values.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) { tx.setTag(t.id, tag.id, false) }
            }
            if let f = a["flagged"]?.bool { tx.setTask(t.id, F.flagged, .bool(f)) }
            if let d = deferD { tx.setTask(t.id, F.deferDate, .date(d)) }
            if let d = dueD { tx.setTask(t.id, F.dueDate, .date(d)) }
            if let d = plannedD { tx.setTask(t.id, F.plannedDate, .date(d)) }
            if let e = a["estimate_minutes"]?.int { tx.setTask(t.id, F.estimate, e > 0 ? .optional(e) : .null) }
            if let p = a["parent"]?.string, a["project"] == nil {
                if p.isEmpty { tx.move(t.id, to: s.info[t.id]?.projectID) } else { tx.move(t.id, to: p) }
            }
            if let ref = a["external_ref"]?.string { tx.setTask(t.id, F.externalRef, ref.isEmpty ? .null : .string(ref)) }
        }
        let after = snapshot()
        return taskJSON(after, try findTask(after, t.id), full: true)
    },
    Tool(name: "complete_task", title: "Complete task",
         description: "Mark an action or project complete (repeating actions advance to the next occurrence). undo=true marks it incomplete.",
         schema: obj(["id": str("Task id"), "undo": bool("Mark incomplete instead")], required: ["id"]), readOnly: false) { a in
        let s = snapshot()
        let t = try findTask(s, a["id"]?.string)
        commit("MCP: Complete") { tx in if a["undo"]?.bool == true { tx.uncomplete(t.id) } else { tx.complete(t.id) } }
        let after = snapshot()
        return taskJSON(after, try findTask(after, t.id))
    },
    Tool(name: "drop_task", title: "Drop task", description: "Drop an action or project (keeps it, hides it from remaining). undo=true restores it.",
         schema: obj(["id": str("Task id"), "undo": bool("Restore instead")], required: ["id"]), readOnly: false) { a in
        let s = snapshot()
        let t = try findTask(s, a["id"]?.string)
        commit("MCP: Drop") { tx in if a["undo"]?.bool == true { tx.undrop(t.id) } else { tx.drop(t.id) } }
        let after = snapshot()
        return taskJSON(after, try findTask(after, t.id))
    },
    Tool(name: "create_project", title: "Create project",
         description: "Create a project from \"Folder : Sub : Name\" (missing folders are created). Returns the existing one if it already exists.",
         schema: obj(["path": str("e.g. \"Common : Домашние дела\""), "type": str("parallel (default), sequential or single_actions"),
                      "note": str("Project note"),
                      "external_ref": str("Your stable id; an existing project with it is returned unchanged")], required: ["path"]), readOnly: false) { a in
        let s = snapshot()
        let path = a["path"]?.string ?? ""
        if let ref = a["external_ref"]?.string, !ref.isEmpty, let existing = findByExternalRef(s, ref) { return taskJSON(s, existing, full: true) }
        if let existing = s.project(atPath: path) { return taskJSON(s, existing, full: true) }
        var id = ""
        commit("MCP: Create Project") { tx in
            id = tx.createProject(path: path)
            switch a["type"]?.string {
            case "sequential": tx.setTask(id, F.sequential, true)
            case "single_actions", "single actions": tx.setTask(id, F.singleActions, true)
            default: break
            }
            if let n = a["note"]?.string { tx.setTask(id, F.note, .string(n)) }
            if let ref = a["external_ref"]?.string, !ref.isEmpty { tx.setTask(id, F.externalRef, .string(ref)) }
        }
        let after = snapshot()
        return taskJSON(after, try findTask(after, id), full: true)
    },
    Tool(name: "find_by_external_ref", title: "Find by external ref",
         description: "Look up items by your own stable id: an exact ref (\"mindmapper:abc\"), or all items whose ref starts with a prefix (\"mindmapper:\"). Includes completed/dropped.",
         schema: obj(["ref": str("Exact external ref"), "prefix": str("Ref prefix"), "limit": int("Max items (default 500)")]), readOnly: true) { a in
        let s = snapshot()
        let hits: [TaskItem]
        if let ref = a["ref"]?.string, !ref.isEmpty { hits = s.tasks.values.filter { $0.externalRef == ref } }
        else if let p = a["prefix"]?.string, !p.isEmpty { hits = s.tasks.values.filter { $0.externalRef?.hasPrefix(p) == true } }
        else { throw ToolError.message("Give ref or prefix.") }
        var args = a; if args["limit"] == nil { args["limit"] = 500 }
        return limited(hits.sorted { $0.id < $1.id }, s, args)
    },
    Tool(name: "changes_since", title: "Changes since",
         description: "Items changed after a moment (any device): completed, dropped, renamed, moved, edited. Each has `changed`, `status`, `completed`/`dropped`, `external_ref`. Pass the previous call's `now` next time.",
         schema: obj(["since": str("ISO 8601 moment"), "external_ref_prefix": str("Only items whose external_ref starts with this, e.g. \"mindmapper:\""),
                      "limit": int("Max items (default 500)")], required: ["since"]), readOnly: true) { a in
        let s = snapshot()
        guard let str = a["since"]?.string, let since = isoMS.date(from: str) ?? iso.date(from: str) ?? ISO8601DateFormatter().date(from: str) else {
            throw ToolError.message("since must be ISO 8601, e.g. 2026-10-24T09:00:00+11:00")
        }
        let prefix = a["external_ref_prefix"]?.string ?? ""
        let hits = s.tasks.values.filter { $0.modifiedAt > since && (prefix.isEmpty || $0.externalRef?.hasPrefix(prefix) == true) }
            .sorted { $0.modifiedAt < $1.modifiedAt }
        let limit = a["limit"]?.int ?? 500
        return .object(["now": .string(isoMS.string(from: Date())), "count": .number(Double(hits.count)),
                        "items": .array(hits.prefix(limit).map { taskJSON(s, $0) }), "truncated": .bool(hits.count > limit)])
    },
    Tool(name: "mark_reviewed", title: "Mark project reviewed", description: "Mark a project reviewed (sets the next review date).",
         schema: obj(["project": str("Project id, \"Folder : Project\" or fuzzy name")], required: ["project"]), readOnly: false) { a in
        let s = snapshot()
        guard let p = findProject(s, a["project"]?.string ?? "") else { throw ToolError.message("No such project.") }
        commit("MCP: Mark Reviewed") { $0.markReviewed(p.id) }
        let after = snapshot()
        return taskJSON(after, try findTask(after, p.id))
    },
]

func toolList() -> JSON {
    .array(tools.map { t in
        .object(["name": .string(t.name), "title": .string(t.title), "description": .string(t.description), "inputSchema": t.schema,
                 "annotations": .object(["readOnlyHint": .bool(t.readOnly), "destructiveHint": .bool(false), "openWorldHint": .bool(false)])])
    })
}

func callTool(_ params: [String: JSON]) -> JSON {
    let name = params["name"]?.string ?? ""
    guard let tool = tools.first(where: { $0.name == name }) else {
        return .object(["content": .array([.object(["type": "text", "text": .string("Unknown tool \(name)")])]), "isError": true])
    }
    do {
        let result = try tool.run(params["arguments"]?.object ?? [:])
        let text: String = {
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? String(decoding: e.encode(result), as: UTF8.self)) ?? "{}"
        }()
        var out: [String: JSON] = ["content": .array([.object(["type": "text", "text": .string(text)])])]
        if case .object = result { out["structuredContent"] = result } else { out["structuredContent"] = .object(["items": result]) }
        return .object(out)
    } catch ToolError.message(let m) {
        return .object(["content": .array([.object(["type": "text", "text": .string(m)])]), "isError": true])
    } catch {
        return .object(["content": .array([.object(["type": "text", "text": .string("\(error)")])]), "isError": true])
    }
}

// MARK: - Dispatch

let capabilities: JSON = .object(["tools": .object(["listChanged": false])])
var legacyVersion: String?

func handle(_ msg: [String: JSON]) {
    let id = msg["id"] ?? .null
    let isRequest = msg["id"] != nil
    let method = msg["method"]?.string ?? ""
    let params = msg["params"]?.object ?? [:]
    let meta = params["_meta"]?.object ?? [:]
    let modernVersion = meta["io.modelcontextprotocol/protocolVersion"]?.string

    if !isRequest { return } // notifications (initialized, cancelled, …) need no reply

    // Modern per-request version check.
    if let v = modernVersion, !modernVersions.contains(v) {
        fail(id, -32022, "Unsupported protocol version",
             data: .object(["supported": .array((modernVersions + legacyVersions).map(JSON.string)), "requested": .string(v)]))
        return
    }
    func respond(_ result: JSON) {
        if modernVersion != nil, case .object(var o) = result {
            o["resultType"] = "complete"
            reply(id, .object(o))
        } else {
            reply(id, result)
        }
    }

    switch method {
    case "initialize":
        let requested = params["protocolVersion"]?.string ?? legacyVersions[0]
        let chosen = legacyVersions.contains(requested) ? requested : legacyVersions[0]
        legacyVersion = chosen
        reply(id, .object(["protocolVersion": .string(chosen), "capabilities": capabilities,
                           "serverInfo": serverInfo, "instructions": .string(instructions)]))
    case "server/discover":
        respond(.object(["supportedVersions": .array((modernVersions + legacyVersions).map(JSON.string)), "capabilities": capabilities,
                         "_meta": .object(["io.modelcontextprotocol/serverInfo": serverInfo]), "instructions": .string(instructions)]))
    case "ping":
        respond(.object([:]))
    case "tools/list":
        respond(.object(["tools": toolList()]))
    case "tools/call":
        respond(callTool(params))
    default:
        fail(id, -32601, "Method not found: \(method)")
    }
}

log("ready (database \(TaskerConfig.databaseURL().path), replica \(store.replica))")
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let data = line.data(using: .utf8), let msg = try? JSONDecoder().decode(JSON.self, from: data).object else {
        fail(.null, -32700, "Parse error")
        continue
    }
    handle(msg)
}
