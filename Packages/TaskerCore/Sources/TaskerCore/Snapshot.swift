import Foundation

/// Derived, per-task state computed from the whole tree (OmniFocus "effective" values).
public struct TaskInfo: Hashable, Sendable {
    public var projectID: String?
    public var parentID: String?          // resolved parent (task or project), nil = inbox root
    public var depth = 0
    public var effectiveDefer: Date?
    public var effectiveDue: Date?
    public var effectiveFlagged = false
    public var isRemaining = true          // not completed/dropped, nor any ancestor
    /// Completed/dropped either itself or via the nearest ancestor that is (OmniFocus semantics).
    public var effectivelyCompleted = false
    public var effectivelyDropped = false
    public var isAvailable = false
    public var isBlocked = false           // waiting on an earlier sibling in a sequential container
    public var isDeferred = false
    public var isFirstAvailable = false    // the project's next action
    public var hasOnHoldTag = false
    public var hasChildren = false
    public var remainingChildren = 0
    public var isInbox: Bool { projectID == nil }
    public init() {}
}

public struct ProjectInfo: Hashable, Sendable {
    public var folderID: String?
    public var isStalled = false   // active, remaining, but nothing available
    public var isPending = false   // deferred
    public var availableCount = 0
    public var remainingCount = 0
    public var folderDropped = false
    public var needsReview = false
    public init() {}
}

/// An immutable, fully resolved view of the database at one moment.
public struct Snapshot: Sendable {
    public static let inboxKey = "#inbox"
    public static let libraryKey = "#library"
    public static let tagsKey = "#tags"

    public let now: Date
    public let dueSoon: Date
    public let tasks: [String: TaskItem]
    public let folders: [String: Folder]
    public let tags: [String: Tag]
    public let perspectives: [Perspective]
    public let settings: [String: JSON]
    /// Ordered children by parent id (or one of the root keys).
    public let children: [String: [String]]
    public let tagChildren: [String: [String]]
    public let info: [String: TaskInfo]
    public let projectInfo: [String: ProjectInfo]
    public let tasksByTag: [String: [String]]
    public let version: Int

    public static let empty = Snapshot(state: CRDTState(), version: 0)

    public func task(_ id: String?) -> TaskItem? { id.flatMap { tasks[$0] } }
    public func childIDs(_ parent: String?) -> [String] { children[parent ?? Snapshot.inboxKey] ?? [] }

    public var inboxIDs: [String] { children[Snapshot.inboxKey] ?? [] }
    public var libraryIDs: [String] { children[Snapshot.libraryKey] ?? [] }
    public var rootTagIDs: [String] { tagChildren[Snapshot.tagsKey] ?? [] }

    /// Projects in library (outline) order.
    public var orderedProjects: [TaskItem] {
        var out: [TaskItem] = []
        func walk(_ ids: [String]) {
            for id in ids {
                if let t = tasks[id], t.isProject { out.append(t) }
                else if folders[id] != nil { walk(children[id] ?? []) }
            }
        }
        walk(libraryIDs)
        return out
    }

    /// Tags in outline order, with depth.
    public var orderedTags: [(tag: Tag, depth: Int)] {
        var out: [(Tag, Int)] = []
        func walk(_ ids: [String], _ depth: Int) {
            for id in ids { if let t = tags[id] { out.append((t, depth)); walk(tagChildren[id] ?? [], depth + 1) } }
        }
        walk(rootTagIDs, 0)
        return out
    }

    public var orderedFolders: [(folder: Folder, depth: Int)] {
        var out: [(Folder, Int)] = []
        func walk(_ ids: [String], _ depth: Int) {
            for id in ids { if let f = folders[id] { out.append((f, depth)); walk(children[id] ?? [], depth + 1) } }
        }
        walk(libraryIDs, 0)
        return out
    }

    public func setting(_ key: String) -> JSON? { settings[key] }

    /// Ancestor chain (closest first): tasks, then the project, then folders.
    public func ancestors(of id: String) -> [String] {
        var out: [String] = []
        var cur = id
        var guardCount = 0
        while guardCount < 1000 {
            guardCount += 1
            if let t = tasks[cur] {
                let p = t.isProject ? (projectInfo[cur]?.folderID) : info[cur]?.parentID
                guard let p else { break }
                out.append(p); cur = p
            } else if let f = folders[cur], let p = resolvedFolderParent(f) {
                out.append(p); cur = p
            } else { break }
        }
        return out
    }

    func resolvedFolderParent(_ f: Folder) -> String? {
        guard let p = f.position.parent, folders[p] != nil else { return nil }
        return p
    }

    /// Folder names above a project or folder, outermost first.
    public func folderPath(of id: String) -> [String] {
        ancestors(of: id).reversed().compactMap { folders[$0]?.name }
    }

    /// "Folder : Sub : Project" — the OmniFocus way of naming a project with its folders.
    public func qualifiedName(of projectID: String) -> String {
        (folderPath(of: projectID) + [tasks[projectID]?.title ?? ""]).joined(separator: " : ")
    }

    /// Splits "Common : Домашние дела" into (["Common"], "Домашние дела").
    public static func splitPath(_ s: String) -> (folders: [String], name: String) {
        let parts = s.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = parts.last else { return ([], s.trimmingCharacters(in: .whitespaces)) }
        return (Array(parts.dropLast()), last)
    }

    /// Existing project matching a "Folder : Project" path exactly (case-insensitive), if any.
    public func project(atPath path: String) -> TaskItem? {
        let (folders, name) = Snapshot.splitPath(path)
        return orderedProjects.first { p in
            p.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame &&
            (folders.isEmpty || folderPath(of: p.id).map { $0.lowercased() }.suffix(folders.count) == ArraySlice(folders.map { $0.lowercased() }))
        }
    }

    public func projectName(for taskID: String) -> String? {
        info[taskID]?.projectID.flatMap { tasks[$0]?.title }
    }

    public func tagNames(_ ids: [String]) -> [String] {
        ids.compactMap { tags[$0]?.name }
    }

    /// All descendant task ids (depth-first, ordered).
    public func descendants(of id: String) -> [String] {
        var out: [String] = []
        func walk(_ p: String) { for c in children[p] ?? [] where tasks[c] != nil { out.append(c); walk(c) } }
        walk(id)
        return out
    }

    public func path(of id: String) -> String {
        let names = ancestors(of: id).reversed().compactMap { tasks[$0]?.title ?? folders[$0]?.name }
        return names.joined(separator: " ▸ ")
    }
}

// MARK: - Building

extension Snapshot {
    init(state: CRDTState, version: Int, cache: [EntityKey: Any] = [:], now: Date = Date(), dueSoonDays: Int? = nil) {
        var tasks: [String: TaskItem] = [:]
        var folders: [String: Folder] = [:]
        var tags: [String: Tag] = [:]
        var perspectives: [Perspective] = []
        var settings: [String: JSON] = [:]

        for (key, fields) in state.entities {
            switch key.type {
            case .task:
                let t = (cache[key] as? TaskItem) ?? TaskItem(id: key.id, fields: fields)
                if !t.deleted { tasks[key.id] = t }
            case .folder:
                let f = (cache[key] as? Folder) ?? Folder(id: key.id, fields: fields)
                if !f.deleted { folders[key.id] = f }
            case .tag:
                let t = (cache[key] as? Tag) ?? Tag(id: key.id, fields: fields)
                if !t.deleted { tags[key.id] = t }
            case .perspective:
                let p = (cache[key] as? Perspective) ?? Perspective(id: key.id, fields: fields)
                if !p.deleted { perspectives.append(p) }
            case .setting:
                settings[key.id] = fields[F.value]?.value ?? .null
            }
        }
        perspectives.sort { ($0.order, $0.id) < ($1.order, $1.id) }

        self.now = now
        let soonDays = dueSoonDays ?? settings["dueSoonDays"]?.int ?? 2
        let startOfToday = Calendar.current.startOfDay(for: now)
        self.dueSoon = Calendar.current.date(byAdding: .day, value: soonDays, to: startOfToday) ?? now
        self.version = version
        self.settings = settings
        self.perspectives = perspectives
        self.folders = folders
        self.tags = tags

        // ---- Resolve parents (never lose an item: unresolvable parents fall back to a root) ----
        var parentOf: [String: String] = [:]   // child -> parent key
        for (id, t) in tasks {
            if t.isProject {
                if let p = t.position.parent, folders[p] != nil { parentOf[id] = p } else { parentOf[id] = Snapshot.libraryKey }
            } else {
                if let p = t.position.parent, p != id, tasks[p] != nil { parentOf[id] = p } else { parentOf[id] = Snapshot.inboxKey }
            }
        }
        for (id, f) in folders {
            if let p = f.position.parent, p != id, folders[p] != nil { parentOf[id] = p } else { parentOf[id] = Snapshot.libraryKey }
        }
        Snapshot.breakCycles(&parentOf, stamp: { id in tasks[id]?.positionStamp ?? folders[id]?.positionStamp ?? .zero },
                             rootFor: { id in tasks[id].map { $0.isProject ? Snapshot.libraryKey : Snapshot.inboxKey } ?? Snapshot.libraryKey })

        var tagParent: [String: String] = [:]
        for (id, t) in tags {
            if let p = t.position.parent, p != id, tags[p] != nil { tagParent[id] = p } else { tagParent[id] = Snapshot.tagsKey }
        }
        Snapshot.breakCycles(&tagParent, stamp: { tags[$0]?.positionStamp ?? .zero }, rootFor: { _ in Snapshot.tagsKey })

        func orderKey(_ id: String) -> String {
            tasks[id]?.position.order ?? folders[id]?.position.order ?? "V"
        }
        var children: [String: [String]] = [:]
        for (c, p) in parentOf { children[p, default: []].append(c) }
        for (k, v) in children { children[k] = v.sorted { (orderKey($0), $0) < (orderKey($1), $1) } }
        self.children = children

        var tagChildren: [String: [String]] = [:]
        for (c, p) in tagParent { tagChildren[p, default: []].append(c) }
        for (k, v) in tagChildren {
            tagChildren[k] = v.sorted { ((tags[$0]?.position.order ?? ""), $0) < ((tags[$1]?.position.order ?? ""), $1) }
        }
        self.tagChildren = tagChildren

        // Tag status inherits: a tag under an on-hold tag is effectively on hold.
        var tagOnHold: [String: Bool] = [:]
        func tagHeld(_ id: String) -> Bool {
            if let v = tagOnHold[id] { return v }
            tagOnHold[id] = false
            let t = tags[id]
            var held = t.map { $0.status != .active } ?? false
            if !held, let p = tagParent[id], p != Snapshot.tagsKey { held = tagHeld(p) }
            tagOnHold[id] = held
            return held
        }

        // ---- Effective values and availability (top-down walk) ----
        var info: [String: TaskInfo] = [:]
        var projectInfo: [String: ProjectInfo] = [:]

        struct Ctx {
            var projectID: String?
            var defer_: Date?
            var due: Date?
            var flagged = false
            var remaining = true
            var done = false
            var dropped = false
            var blocked = false
            var projectActive = true
            var depth = 0
        }

        func walk(container: String, ctx: Ctx, sequential: Bool, firstAvailableHolder: inout Bool) -> (remaining: Int, available: Int) {
            var remainingCount = 0
            var availableCount = 0
            var seenRemainingSibling = false
            for id in children[container] ?? [] {
                guard let t = tasks[id], !t.isProject else { continue }
                var i = TaskInfo()
                i.projectID = ctx.projectID
                i.parentID = container == Snapshot.inboxKey ? nil : container
                i.depth = ctx.depth
                i.effectiveDefer = [t.deferDate, ctx.defer_].compactMap { $0 }.max()
                i.effectiveDue = [t.dueDate, ctx.due].compactMap { $0 }.min()
                i.effectiveFlagged = t.flagged || ctx.flagged
                i.isRemaining = ctx.remaining && t.completedAt == nil && t.droppedAt == nil
                if t.droppedAt != nil { i.effectivelyDropped = true }
                else if t.completedAt != nil { i.effectivelyCompleted = true }
                else { i.effectivelyDropped = ctx.dropped; i.effectivelyCompleted = ctx.done }
                i.isBlocked = ctx.blocked || (sequential && seenRemainingSibling)
                i.isDeferred = (i.effectiveDefer.map { $0 > now }) ?? false
                i.hasOnHoldTag = t.tagIDs.contains { tagHeld($0) }
                let kids = (children[id] ?? []).filter { tasks[$0] != nil }
                i.hasChildren = !kids.isEmpty
                i.isAvailable = i.isRemaining && !i.isBlocked && !i.isDeferred && !i.hasOnHoldTag && ctx.projectActive
                if i.isRemaining { seenRemainingSibling = true; remainingCount += 1 }

                var childCtx = ctx
                childCtx.defer_ = i.effectiveDefer
                childCtx.due = i.effectiveDue
                childCtx.flagged = i.effectiveFlagged
                childCtx.remaining = i.isRemaining
                childCtx.done = i.effectivelyCompleted
                childCtx.dropped = i.effectivelyDropped
                childCtx.blocked = i.isBlocked
                childCtx.depth = ctx.depth + 1
                // Children are visited before this task's "first available" status is decided,
                // so the next action is the first available *leaf*, as in OmniFocus.
                let sub = walk(container: id, ctx: childCtx, sequential: t.sequential, firstAvailableHolder: &firstAvailableHolder)
                i.remainingChildren = sub.remaining
                if i.hasChildren && sub.remaining > 0 {
                    // An action group is available when one of its children is.
                    i.isAvailable = i.isAvailable && sub.available > 0
                }
                if i.isAvailable && !(i.hasChildren && sub.remaining > 0) {
                    availableCount += 1
                    if !firstAvailableHolder { i.isFirstAvailable = true; firstAvailableHolder = true }
                }
                availableCount += sub.available
                info[id] = i
            }
            return (remainingCount, availableCount)
        }

        // Inbox
        var inboxHolder = true // inbox has no "next action"
        _ = walk(container: Snapshot.inboxKey, ctx: Ctx(), sequential: false, firstAvailableHolder: &inboxHolder)

        // Projects
        func folderDropped(_ id: String?) -> Bool {
            var cur = id
            var n = 0
            while let c = cur, c != Snapshot.libraryKey, n < 200 {
                if folders[c]?.dropped == true { return true }
                cur = parentOf[c]; n += 1
            }
            return false
        }
        for (id, p) in tasks where p.isProject {
            var pi = ProjectInfo()
            let parent = parentOf[id]
            pi.folderID = parent == Snapshot.libraryKey ? nil : parent
            pi.folderDropped = folderDropped(pi.folderID)
            let remaining = p.status == .active || p.status == .onHold
            let projectRemaining = remaining && p.completedAt == nil && p.droppedAt == nil && !pi.folderDropped
            let deferred = p.deferDate.map { $0 > now } ?? false
            pi.isPending = deferred
            var ctx = Ctx()
            ctx.projectID = id
            ctx.defer_ = p.deferDate
            ctx.due = p.dueDate
            ctx.flagged = p.flagged
            ctx.remaining = projectRemaining
            ctx.dropped = p.status == .dropped || p.droppedAt != nil || pi.folderDropped
            ctx.done = !ctx.dropped && (p.status == .done || p.completedAt != nil)
            ctx.projectActive = p.status == .active && !deferred && !p.tagIDs.contains { tagHeld($0) }
            var holder = false
            let r = walk(container: id, ctx: ctx, sequential: p.sequential && !p.singleActions, firstAvailableHolder: &holder)
            pi.remainingCount = r.remaining
            pi.availableCount = r.available
            pi.isStalled = p.status == .active && projectRemaining && !deferred && r.available == 0 && !p.singleActions
            pi.needsReview = projectRemaining && (p.nextReviewDate.map { $0 <= now } ?? false)
            projectInfo[id] = pi

            // The project row itself.
            var own = TaskInfo()
            own.projectID = id
            own.effectiveDefer = p.deferDate
            own.effectiveDue = p.dueDate
            own.effectiveFlagged = p.flagged
            own.isRemaining = projectRemaining
            own.effectivelyDropped = ctx.dropped
            own.effectivelyCompleted = ctx.done
            own.isDeferred = deferred
            own.isAvailable = projectRemaining && p.status == .active && !deferred
            own.hasChildren = !(children[id] ?? []).isEmpty
            own.remainingChildren = r.remaining
            info[id] = own
        }

        var byTag: [String: [String]] = [:]
        for (id, t) in tasks { for tag in t.tagIDs where tags[tag] != nil { byTag[tag, default: []].append(id) } }
        self.tasksByTag = byTag
        self.tasks = tasks
        self.info = info
        self.projectInfo = projectInfo
    }

    /// Concurrent moves can create a cycle (A into B on one device, B into A on another).
    /// Every replica breaks it the same way: the member whose move is newest goes to the root.
    static func breakCycles(_ parentOf: inout [String: String], stamp: (String) -> HLC, rootFor: (String) -> String) {
        var state: [String: Int] = [:] // 1 = visiting, 2 = done
        for start in parentOf.keys.sorted() {
            var path: [String] = []
            var cur: String? = start
            while let c = cur, parentOf[c] != nil, state[c] != 2 {
                if state[c] == 1 {
                    if let idx = path.firstIndex(of: c) {
                        let cycle = Array(path[idx...])
                        let newest = cycle.max { (stamp($0), $0) < (stamp($1), $1) }!
                        parentOf[newest] = rootFor(newest)
                    }
                    break
                }
                state[c] = 1
                path.append(c)
                cur = parentOf[c]
            }
            for p in path { state[p] = 2 }
        }
    }
}
