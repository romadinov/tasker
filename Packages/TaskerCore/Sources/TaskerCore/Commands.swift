import Foundation

/// Where to insert an item among its siblings.
public enum Placement: Sendable {
    case end, start
    case after(String)
    case before(String)
}

public struct NewTask: Sendable {
    public var title: String
    public var note = ""
    public var parent: String?           // task/project id, nil = inbox
    public var placement: Placement = .end
    public var flagged = false
    public var deferDate: Date?
    public var dueDate: Date?
    public var plannedDate: Date?
    public var estimatedMinutes: Int?
    public var tagIDs: [String] = []
    public var isProject = false
    public var sequential = false
    public var singleActions = false
    public init(title: String, parent: String? = nil) { self.title = title; self.parent = parent }
}

extension Tx {
    // MARK: Ordering

    /// Order key for a new item under `parent` (a task/project/folder id, or a root key).
    mutating func orderKey(in parentKey: String, placement: Placement, excluding moving: String? = nil) -> String {
        let key = computeOrderKey(in: parentKey, placement: placement, excluding: moving)
        if case .end = placement { lastAppended[parentKey] = key }
        return key
    }

    func computeOrderKey(in parentKey: String, placement: Placement, excluding moving: String?) -> String {
        let siblings = (base.children[parentKey] ?? []).filter { $0 != moving }
        func order(_ id: String) -> String {
            if base.tasks[id] != nil, let p = current(.task, id, F.pos) { return Position(json: p).order }
            if base.folders[id] != nil, let p = current(.folder, id, F.pos) { return Position(json: p).order }
            return "V"
        }
        switch placement {
        case .end:
            // Items appended earlier in this same transaction aren't in the snapshot yet.
            let last = [siblings.last.map(order), lastAppended[parentKey]].compactMap { $0 }.max()
            return FractionalIndex.between(last, nil)
        case .start: return FractionalIndex.between(nil, siblings.first.map(order))
        case .after(let id):
            guard let i = siblings.firstIndex(of: id) else { return FractionalIndex.between(siblings.last.map(order), nil) }
            let next = i + 1 < siblings.count ? order(siblings[i + 1]) : nil
            return FractionalIndex.between(order(id), next)
        case .before(let id):
            guard let i = siblings.firstIndex(of: id) else { return FractionalIndex.between(nil, siblings.first.map(order)) }
            let prev = i > 0 ? order(siblings[i - 1]) : nil
            return FractionalIndex.between(prev, order(id))
        }
    }

    static func parentKey(task parent: String?, isProject: Bool) -> String {
        parent ?? (isProject ? Snapshot.libraryKey : Snapshot.inboxKey)
    }

    // MARK: Tasks & projects

    @discardableResult
    public mutating func createTask(_ n: NewTask, id: String = IDs.make()) -> String {
        markCreated(.task, id)
        let key = Tx.parentKey(task: n.parent, isProject: n.isProject)
        let order = orderKey(in: key, placement: n.placement)
        set(.task, id, F.kind, n.isProject ? "project" : "action")
        set(.task, id, F.title, .string(n.title))
        if !n.note.isEmpty { set(.task, id, F.note, .string(n.note)) }
        set(.task, id, F.pos, Position(parent: n.parent, order: order).json)
        set(.task, id, F.created, .date(now))
        if n.flagged { set(.task, id, F.flagged, true) }
        if let d = n.deferDate { set(.task, id, F.deferDate, .date(d)) }
        if let d = n.dueDate { set(.task, id, F.dueDate, .date(d)) }
        if let d = n.plannedDate { set(.task, id, F.plannedDate, .date(d)) }
        if let e = n.estimatedMinutes { set(.task, id, F.estimate, .optional(e)) }
        for t in n.tagIDs { set(.task, id, F.tag(t), true) }
        if n.sequential { set(.task, id, F.sequential, true) }
        if n.isProject {
            set(.task, id, F.status, "active")
            if n.singleActions { set(.task, id, F.singleActions, true) }
            set(.task, id, F.reviewEvery, JSON(encoding: ReviewInterval.weekly))
            set(.task, id, F.nextReview, .date(ReviewInterval.weekly.advance(now)))
        }
        return id
    }

    public mutating func setTask(_ id: String, _ field: String, _ value: JSON) {
        set(.task, id, field, value)
    }

    public mutating func setTag(_ taskID: String, _ tagID: String, _ on: Bool) {
        set(.task, taskID, F.tag(tagID), .bool(on))
    }

    /// Moves a task/project. `parent` is a task/project id (actions) or a folder id (projects); nil = inbox/library root.
    public mutating func move(_ id: String, to parent: String?, placement: Placement = .end) {
        guard let t = base.tasks[id] else { return }
        // Refuse moves into the item's own subtree.
        if let p = parent, p == id || base.ancestors(of: p).contains(id) { return }
        let key = Tx.parentKey(task: parent, isProject: t.isProject)
        set(.task, id, F.pos, Position(parent: parent, order: orderKey(in: key, placement: placement, excluding: id)).json)
    }

    public mutating func moveFolder(_ id: String, to parent: String?, placement: Placement = .end) {
        if let p = parent, p == id || base.ancestors(of: p).contains(id) { return }
        let key = parent ?? Snapshot.libraryKey
        set(.folder, id, F.pos, Position(parent: parent, order: orderKey(in: key, placement: placement, excluding: id)).json)
    }

    /// Indent: become the last child of the previous sibling.
    public mutating func indent(_ id: String) {
        guard let t = base.tasks[id], !t.isProject else { return }
        let parentKey = base.info[id]?.parentID ?? Snapshot.inboxKey
        let siblings = base.children[parentKey] ?? []
        guard let i = siblings.firstIndex(of: id), i > 0 else { return }
        let newParent = siblings[i - 1]
        guard base.tasks[newParent] != nil else { return }
        move(id, to: newParent, placement: .end)
    }

    /// Outdent: become the next sibling of the current parent.
    public mutating func outdent(_ id: String) {
        guard let parent = base.info[id]?.parentID, let p = base.tasks[parent], !p.isProject else { return }
        let grand = base.info[parent]?.parentID ?? (base.info[parent]?.projectID)
        move(id, to: grand, placement: .after(parent))
    }

    public mutating func complete(_ id: String, at date: Date? = nil) {
        guard let t = base.tasks[id] else { return }
        let when = date ?? now
        if t.isProject {
            set(.task, id, F.status, "done")
            set(.task, id, F.completed, .date(when))
            return
        }
        if let rule = t.repeatRule {
            completeRepeating(t, rule: rule, at: when)
            return
        }
        set(.task, id, F.completed, .date(when))
        // A group that completes with its children completes when its last child does.
        if let parent = base.info[id]?.parentID, let p = base.tasks[parent], !p.isProject, p.completesWithChildren {
            let others = (base.children[parent] ?? []).filter { $0 != id && base.info[$0]?.isRemaining == true }
            if others.isEmpty { complete(parent, at: when) }
        }
    }

    public mutating func uncomplete(_ id: String) {
        guard let t = base.tasks[id] else { return }
        if t.isProject { set(.task, id, F.status, "active") }
        set(.task, id, F.completed, .null)
    }

    public mutating func drop(_ id: String) {
        guard let t = base.tasks[id] else { return }
        if t.isProject { set(.task, id, F.status, "dropped") }
        set(.task, id, F.dropped, .date(now))
    }

    public mutating func undrop(_ id: String) {
        guard let t = base.tasks[id] else { return }
        if t.isProject { set(.task, id, F.status, "active") }
        set(.task, id, F.dropped, .null)
    }

    /// Deletes the item and its subtree. Children created concurrently on another device
    /// (that this device hasn't seen) surface in the Inbox rather than vanishing.
    public mutating func delete(_ id: String) {
        guard base.tasks[id] != nil else { return }
        for d in base.descendants(of: id) { set(.task, d, F.deleted, true) }
        set(.task, id, F.deleted, true)
    }

    public mutating func markReviewed(_ projectID: String) {
        guard let p = base.tasks[projectID] else { return }
        let interval = p.reviewInterval ?? .weekly
        set(.task, projectID, F.lastReview, .date(now))
        set(.task, projectID, F.nextReview, .date(interval.advance(Calendar.current.startOfDay(for: now))))
    }

    public mutating func convertToProject(_ id: String, folder: String?) {
        guard let t = base.tasks[id], !t.isProject else { return }
        set(.task, id, F.kind, "project")
        set(.task, id, F.status, "active")
        set(.task, id, F.reviewEvery, JSON(encoding: ReviewInterval.weekly))
        set(.task, id, F.nextReview, .date(ReviewInterval.weekly.advance(now)))
        set(.task, id, F.pos, Position(parent: folder, order: orderKey(in: folder ?? Snapshot.libraryKey, placement: .end, excluding: id)).json)
    }

    // MARK: Repeating tasks

    /// A completed copy is left behind and the task's dates move to the next
    /// occurrence. The copy's id is derived from the task and occurrence, so completing the same
    /// occurrence on two offline devices converges to one copy, and dates advance only once.
    mutating func completeRepeating(_ t: TaskItem, rule: RepeatRule, at when: Date) {
        let anchorDate: Date? = switch rule.anchor {
        case .due: t.dueDate ?? t.deferDate ?? t.plannedDate
        case .deferDate: t.deferDate ?? t.dueDate ?? t.plannedDate
        case .planned: t.plannedDate ?? t.dueDate ?? t.deferDate
        }
        let occurrenceKey = anchorDate.map { String(Int($0.timeIntervalSince1970)) } ?? "c\(Int(t.modifiedAt.timeIntervalSince1970))"

        // Completed copy of the item (and its subtree for repeating action groups).
        let cloneID = IDs.derived("\(t.id)@\(occurrenceKey)")
        cloneSubtree(t.id, as: cloneID, seed: occurrenceKey, parent: base.info[t.id]?.parentID ?? base.info[t.id]?.projectID,
                     placement: .before(t.id), completedAt: when)

        // Advance dates.
        let r = rule.parsed
        let cal = Calendar.current
        var base = rule.fromCompletion ? when : (anchorDate ?? when)
        if rule.fromCompletion, let a = anchorDate {
            // Keep the original time of day when repeating from completion.
            let tod = cal.dateComponents([.hour, .minute, .second], from: a)
            base = cal.date(bySettingHour: tod.hour ?? 0, minute: tod.minute ?? 0, second: tod.second ?? 0, of: when) ?? when
        }
        var next = r.next(after: base, calendar: cal)
        if !rule.fromCompletion && rule.catchUp {
            var guardN = 0
            while next < when && guardN < 10_000 { next = r.next(after: next, calendar: cal); guardN += 1 }
        }
        let delta = next.timeIntervalSince(anchorDate ?? base)
        for (field, d) in [(F.deferDate, t.deferDate), (F.dueDate, t.dueDate), (F.plannedDate, t.plannedDate)] {
            if let d { set(.task, t.id, field, .date(d.addingTimeInterval(delta))) }
        }
        if anchorDate == nil {
            // No dates at all: give it the next occurrence as a defer date so it disappears until then.
            set(.task, t.id, F.deferDate, .date(next))
        }
        // Reset the subtree of a repeating group.
        for d in self.base.descendants(of: t.id) {
            if self.base.tasks[d]?.completedAt != nil { set(.task, d, F.completed, .null) }
        }
    }

    private mutating func cloneSubtree(_ sourceID: String, as newID: String, seed: String, parent: String?, placement: Placement, completedAt: Date) {
        guard let s = base.tasks[sourceID] else { return }
        if exists(.task, newID) && base.tasks[newID] != nil { return } // already completed elsewhere
        markCreated(.task, newID)
        let key = Tx.parentKey(task: parent, isProject: false)
        set(.task, newID, F.kind, "action")
        set(.task, newID, F.title, .string(s.title))
        if !s.note.isEmpty { set(.task, newID, F.note, .string(s.note)) }
        set(.task, newID, F.pos, Position(parent: parent, order: orderKey(in: key, placement: placement)).json)
        set(.task, newID, F.created, .date(s.createdAt ?? now))
        if s.flagged { set(.task, newID, F.flagged, true) }
        if let d = s.deferDate { set(.task, newID, F.deferDate, .date(d)) }
        if let d = s.dueDate { set(.task, newID, F.dueDate, .date(d)) }
        if let d = s.plannedDate { set(.task, newID, F.plannedDate, .date(d)) }
        if let e = s.estimatedMinutes { set(.task, newID, F.estimate, .optional(e)) }
        if s.sequential { set(.task, newID, F.sequential, true) }
        for tag in s.tagIDs { set(.task, newID, F.tag(tag), true) }
        set(.task, newID, F.completed, .date(s.completedAt ?? completedAt))
        for c in base.children[sourceID] ?? [] where base.tasks[c] != nil {
            cloneSubtree(c, as: IDs.derived("\(c)@\(seed)"), seed: seed, parent: newID, placement: .end, completedAt: completedAt)
        }
    }

    // MARK: Folders, tags, perspectives

    /// Finds or creates nested folders by name ("Work", "Clients"); returns the innermost folder id.
    public mutating func ensureFolderPath(_ names: [String]) -> String? {
        var parent: String? = nil
        for name in names {
            let siblings = base.children[parent ?? Snapshot.libraryKey] ?? []
            let existing = siblings.first { id in
                guard let f = base.folders[id] else { return false }
                return f.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            } ?? createdFolders[(parent ?? "") + "/" + name.lowercased()]
            if let existing { parent = existing; continue }
            let id = createFolder(name, parent: parent)
            createdFolders[(parent ?? "") + "/" + name.lowercased()] = id
            parent = id
        }
        return parent
    }

    /// Creates a project from "Folder : Sub : Name", creating missing folders.
    @discardableResult
    public mutating func createProject(path: String) -> String {
        let (folders, name) = Snapshot.splitPath(path)
        var n = NewTask(title: name)
        n.isProject = true
        n.parent = ensureFolderPath(folders)
        return createTask(n)
    }

    @discardableResult
    public mutating func createFolder(_ name: String, parent: String? = nil, id: String = IDs.make()) -> String {
        markCreated(.folder, id)
        set(.folder, id, F.name, .string(name))
        set(.folder, id, F.pos, Position(parent: parent, order: orderKey(in: parent ?? Snapshot.libraryKey, placement: .end)).json)
        set(.folder, id, F.status, "active")
        return id
    }

    @discardableResult
    public mutating func createTag(_ name: String, parent: String? = nil, id: String = IDs.make()) -> String {
        markCreated(.tag, id)
        let siblings = base.tagChildren[parent ?? Snapshot.tagsKey] ?? []
        let last = siblings.last.flatMap { base.tags[$0]?.position.order }
        set(.tag, id, F.name, .string(name))
        set(.tag, id, F.pos, Position(parent: parent, order: FractionalIndex.between(last, nil)).json)
        set(.tag, id, F.status, "active")
        return id
    }

    public mutating func setTagStatus(_ id: String, _ status: TagStatus) {
        set(.tag, id, F.status, .string(status.rawValue))
    }

    @discardableResult
    public mutating func createPerspective(_ p: Perspective) -> String {
        markCreated(.perspective, p.id)
        let last = base.perspectives.last?.order
        writePerspective(p, order: FractionalIndex.between(last, nil))
        return p.id
    }

    public mutating func writePerspective(_ p: Perspective, order: String? = nil) {
        let old = base.perspectives.first { $0.id == p.id }
        if old?.name != p.name { set(.perspective, p.id, F.name, .string(p.name)) }
        if old?.icon != p.icon { set(.perspective, p.id, F.icon, .string(p.icon)) }
        if old?.rules != p.rules { set(.perspective, p.id, F.rules, .array(p.rules)) }
        if old?.aggregation != p.aggregation { set(.perspective, p.id, F.aggregation, .string(p.aggregation)) }
        if old?.groupBy != p.groupBy { set(.perspective, p.id, F.groupBy, .string(p.groupBy.rawValue)) }
        if old?.sortBy != p.sortBy { set(.perspective, p.id, F.sortBy, .string(p.sortBy.rawValue)) }
        if let order { set(.perspective, p.id, F.pos, Position(parent: nil, order: order).json) }
    }

    public mutating func setSetting(_ key: String, _ value: JSON) {
        set(.setting, key, F.value, value)
    }
}
