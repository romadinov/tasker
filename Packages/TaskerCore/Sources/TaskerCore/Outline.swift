import Foundation

/// Orders available in Organize → Sort Once.
public enum OutlineSort: String, CaseIterable, Sendable {
    case title, status, added, completed, due, planned, deferred, dropped
    public var label: String {
        switch self {
        case .title: "By Title"; case .status: "By Status"; case .added: "By Added Date"
        case .completed: "By Completed Date"; case .due: "By Due Date"; case .planned: "By Planned Date"
        case .deferred: "By Defer Date"; case .dropped: "By Dropped Date"
        }
    }
}

/// OmniFocus-style Organize commands (indent, outdent, move, group, ungroup, sort once).
/// They work on a whole selection at once: `base` doesn't change during a transaction,
/// so each command computes every new position up front and writes the selection as one ordered run.
extension Tx {
    enum OutlineKind { case action, project, folder, tag }

    func outlineKind(_ id: String) -> OutlineKind? {
        if let t = base.tasks[id] { return t.isProject ? .project : .action }
        if base.folders[id] != nil { return .folder }
        if base.tags[id] != nil { return .tag }
        return nil
    }

    private func entityType(_ k: OutlineKind) -> EntityType {
        switch k { case .action, .project: .task; case .folder: .folder; case .tag: .tag }
    }

    /// The key of the sibling list the item sits in (an id, or a root key such as `#inbox`).
    public func siblingKey(_ id: String) -> String? {
        switch outlineKind(id) {
        case .action: return base.info[id]?.parentID ?? Snapshot.inboxKey
        case .project: return base.projectInfo[id]?.folderID ?? Snapshot.libraryKey
        case .folder: return base.folders[id]?.position.parent.flatMap { base.folders[$0] != nil ? $0 : nil } ?? Snapshot.libraryKey
        case .tag: return base.tags[id]?.position.parent.flatMap { base.tags[$0] != nil ? $0 : nil } ?? Snapshot.tagsKey
        case nil: return nil
        }
    }

    func outlineSiblings(_ key: String, tags: Bool) -> [String] {
        (tags ? base.tagChildren[key] : base.children[key]) ?? []
    }

    private func outlineOrder(_ id: String) -> String {
        guard let k = outlineKind(id), let p = current(entityType(k), id, F.pos) else { return "V" }
        return Position(json: p).order
    }

    private func outlineAncestors(_ id: String) -> [String] {
        guard outlineKind(id) == .tag else { return base.ancestors(of: id) }
        var out: [String] = [], cur = id
        while let p = base.tags[cur]?.position.parent, base.tags[p] != nil, !out.contains(p), out.count < 1000 { out.append(p); cur = p }
        return out
    }

    /// The selection without items whose ancestor is also selected (those move along with it).
    func outlineRoots(_ ids: [String]) -> [String] {
        let set = Set(ids)
        return ids.filter { outlineKind($0) != nil && !outlineAncestors($0).contains(where: set.contains) }
    }

    /// Selected roots grouped by sibling list, each group in outline order.
    private func groupedBySiblings(_ ids: [String]) -> [(key: String, items: [String])] {
        var groups: [String: Set<String>] = [:]
        var keys: [String] = []
        for id in outlineRoots(ids) {
            guard let key = siblingKey(id) else { continue }
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].insert(id)
        }
        return keys.map { key in
            let tags = groups[key]!.contains { outlineKind($0) == .tag }
            return (key, outlineSiblings(key, tags: tags).filter { groups[key]!.contains($0) })
        }
    }

    /// Puts `ids`, in this order, as one run in the sibling list `key`.
    mutating func place(_ ids: [String], in key: String, _ placement: Placement) {
        guard let first = ids.first, let kind = outlineKind(first) else { return }
        let moving = Set(ids)
        let sibs = outlineSiblings(key, tags: kind == .tag).filter { !moving.contains($0) }
        var lo: String?, hi: String?
        switch placement {
        case .start: hi = sibs.first.map(outlineOrder)
        case .end: lo = sibs.last.map(outlineOrder)
        case .after(let a):
            if let i = sibs.firstIndex(of: a) { lo = outlineOrder(a); hi = i + 1 < sibs.count ? outlineOrder(sibs[i + 1]) : nil }
            else { lo = sibs.last.map(outlineOrder) }
        case .before(let b):
            if let i = sibs.firstIndex(of: b) { hi = outlineOrder(b); lo = i > 0 ? outlineOrder(sibs[i - 1]) : nil }
            else { hi = sibs.first.map(outlineOrder) }
        }
        let parent: String? = key.hasPrefix("#") ? nil : key
        for id in ids {
            guard let k = outlineKind(id) else { continue }
            let o = FractionalIndex.between(lo, hi)
            lo = o
            set(entityType(k), id, F.pos, Position(parent: parent, order: o).json)
        }
    }

    private func canContain(_ container: String, _ item: String) -> Bool {
        switch (outlineKind(item), outlineKind(container)) {
        case (.action, .action), (.action, .project): return true
        case (.project, .folder), (.folder, .folder): return true
        case (.tag, .tag): return true
        default: return false
        }
    }

    /// Indent (Move Right): each selected item becomes the last child of the nearest unselected item above it.
    /// Returns the new parents, so the UI can expand them.
    @discardableResult
    public mutating func indent(_ ids: [String]) -> [String] {
        var parents: [String] = []
        for g in groupedBySiblings(ids) {
            let chosen = Set(g.items)
            let tags = outlineKind(g.items[0]) == .tag
            var target: String?
            var runs: [(String, [String])] = []
            for s in outlineSiblings(g.key, tags: tags) {
                if !chosen.contains(s) { target = s; continue }
                guard let t = target, canContain(t, s) else { continue }
                if runs.last?.0 == t { runs[runs.count - 1].1.append(s) } else { runs.append((t, [s])) }
            }
            for (t, items) in runs { place(items, in: t, .end); parents.append(t) }
        }
        return parents
    }

    /// Outdent (Move Left): selected items move out of their parent, right after it, keeping their order.
    public mutating func outdent(_ ids: [String]) {
        for g in groupedBySiblings(ids) {
            let parent = g.key
            guard !parent.hasPrefix("#"), let pk = outlineKind(parent), let newKey = siblingKey(parent) else { continue }
            // Actions can't leave their project this way (Move To… does that); projects stay in the library.
            if pk == .project { continue }
            place(g.items, in: newKey, .after(parent))
        }
    }

    /// Move Up / Move Down: the selection swaps with the nearest unselected sibling.
    public mutating func moveVertically(_ ids: [String], up: Bool) {
        for g in groupedBySiblings(ids) {
            let chosen = Set(g.items)
            let sibs = outlineSiblings(g.key, tags: outlineKind(g.items[0]) == .tag)
            guard let lo = sibs.firstIndex(where: chosen.contains), let hi = sibs.lastIndex(where: chosen.contains) else { continue }
            if up {
                guard let anchor = sibs[..<lo].last(where: { !chosen.contains($0) }) else { continue }
                place(g.items, in: g.key, .before(anchor))
            } else {
                guard let anchor = sibs[(hi + 1)...].first(where: { !chosen.contains($0) }) else { continue }
                place(g.items, in: g.key, .after(anchor))
            }
        }
    }

    /// Add Inside: a new empty action as the first child of `id` (an action or project).
    public mutating func addInside(_ id: String) -> String? {
        guard base.tasks[id] != nil else { return nil }
        var n = NewTask(title: "", parent: id)
        n.placement = .start
        return createTask(n)
    }

    /// Add Outside: a new empty action right after the parent of `id`.
    public mutating func addOutside(_ id: String) -> String? {
        guard outlineKind(id) == .action, let parent = base.info[id]?.parentID, outlineKind(parent) == .action else { return nil }
        var n = NewTask(title: "", parent: base.info[parent]?.parentID)
        n.placement = .after(parent)
        return createTask(n)
    }

    /// Group: wraps the selection in a new action group (actions) or folder (projects/folders),
    /// placed where the first selected item was. Returns the new group's id.
    public mutating func group(_ ids: [String]) -> String? {
        let roots = outlineRoots(ids)
        guard let first = roots.first, let key = siblingKey(first), let kind = outlineKind(first) else { return nil }
        let ordered = groupedBySiblings(roots).flatMap(\.items)
        let parent: String? = key.hasPrefix("#") ? nil : key
        let groupID: String
        switch kind {
        case .action:
            guard roots.allSatisfy({ outlineKind($0) == .action }) else { return nil }
            var n = NewTask(title: "", parent: parent)
            n.placement = .before(first)
            groupID = createTask(n)
        case .project, .folder:
            guard roots.allSatisfy({ [.project, .folder].contains(outlineKind($0)) }) else { return nil }
            groupID = createFolder("New Folder", parent: parent)
            let sibs = outlineSiblings(key, tags: false)
            let i = sibs.firstIndex(of: first) ?? 0
            let order = FractionalIndex.between(i > 0 ? outlineOrder(sibs[i - 1]) : nil, outlineOrder(first))
            set(.folder, groupID, F.pos, Position(parent: parent, order: order).json)
        case .tag:
            return nil
        }
        // The group isn't in `base` yet, so write positions directly.
        let keys = FractionalIndex.evenlySpaced(ordered.count)
        for (i, id) in ordered.enumerated() {
            guard let k = outlineKind(id) else { continue }
            set(entityType(k), id, F.pos, Position(parent: groupID, order: keys[i]).json)
        }
        return groupID
    }

    /// Ungroup: moves the children of each selected group/folder up one level, then deletes the empty group.
    public mutating func ungroup(_ ids: [String]) {
        for id in outlineRoots(ids) {
            guard let kind = outlineKind(id), kind == .action || kind == .folder, let key = siblingKey(id) else { continue }
            let kids = outlineSiblings(id, tags: false)
            guard !kids.isEmpty else { continue }
            place(kids, in: key, .after(id))
            set(entityType(kind), id, F.deleted, true)
        }
    }

    /// Sort Once: one selected container sorts its children; several selected siblings are sorted
    /// among the places they already occupy. `rootKey` is used when nothing is selected.
    public mutating func sortOnce(_ ids: [String], by sort: OutlineSort, rootKey: String? = nil) {
        let roots = outlineRoots(ids)
        if roots.count <= 1 {
            let key = roots.first ?? rootKey
            guard let key else { return }
            let tags = key == Snapshot.tagsKey || outlineKind(key) == .tag
            let kids = outlineSiblings(key, tags: tags)
            guard kids.count > 1 else { return }
            let keys = FractionalIndex.evenlySpaced(kids.count)
            write(sorted(kids, by: sort), orders: keys, in: key)
        } else {
            for g in groupedBySiblings(roots) where g.items.count > 1 {
                write(sorted(g.items, by: sort), orders: g.items.map(outlineOrder).sorted(), in: g.key)
            }
        }
    }

    private mutating func write(_ ids: [String], orders: [String], in key: String) {
        let parent: String? = key.hasPrefix("#") ? nil : key
        for (i, id) in ids.enumerated() {
            guard let k = outlineKind(id) else { continue }
            set(entityType(k), id, F.pos, Position(parent: parent, order: orders[i]).json)
        }
    }

    func sorted(_ ids: [String], by sort: OutlineSort) -> [String] {
        func name(_ id: String) -> String { base.tasks[id]?.title ?? base.folders[id]?.name ?? base.tags[id]?.name ?? "" }
        func date(_ id: String) -> Date? {
            guard let t = base.tasks[id] else { return nil }
            switch sort {
            case .added: return t.createdAt
            case .completed: return t.completedAt
            case .due: return t.dueDate
            case .planned: return t.plannedDate
            case .deferred: return t.deferDate
            case .dropped: return t.droppedAt
            case .title, .status: return nil
            }
        }
        func status(_ id: String) -> Int {
            guard let t = base.tasks[id] else { return 0 }
            if t.isDropped { return 3 }
            if t.isCompleted { return 2 }
            return base.info[id]?.isRemaining == false ? 1 : 0
        }
        let current = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return ids.sorted { a, b in
            switch sort {
            case .title:
                let r = name(a).localizedStandardCompare(name(b))
                if r != .orderedSame { return r == .orderedAscending }
            case .status:
                if status(a) != status(b) { return status(a) < status(b) }
            default:
                // Items without the date go last; ties keep their current order.
                switch (date(a), date(b)) {
                case let (x?, y?) where x != y: return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            }
            return current[a]! < current[b]!
        }
    }
}
