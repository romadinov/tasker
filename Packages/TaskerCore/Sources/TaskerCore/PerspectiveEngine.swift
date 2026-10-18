import Foundation

public struct ResultSection: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var taskIDs: [String]
}

/// Evaluates perspective rules (the JSON rule format also used by imported OmniFocus perspectives).
public struct PerspectiveEngine {
    public let s: Snapshot
    public init(_ snapshot: Snapshot) { s = snapshot }

    /// Rule types this engine understands; anything else is preserved but treated as "matches".
    public static let knownKeys: Set<String> = [
        "actionAvailability", "actionStatus", "actionHasAnyOfTags", "actionHasAllOfTags",
        "actionHasTagWithStatus", "actionIsUntagged", "actionHasProjectWithStatus", "actionWithinFocus",
        "actionHasDueDate", "actionHasDeferDate", "actionHasPlannedDate", "actionMatchingSearch", "actionRepeats",
        "actionIsLeaf", "actionIsProject", "actionIsGroup", "actionHasNoProject", "actionIsInSingleActionsList",
        "actionIsProjectOrGroup", "actionDateField", "actionHasDuration", "aggregateType", "aggregateRules", "disabledRule",
    ]

    public static func isSupported(_ rule: JSON) -> Bool {
        guard let o = rule.object else { return false }
        if let inner = o["aggregateRules"]?.array { return inner.allSatisfy(isSupported) }
        if o["disabledRule"] != nil { return true }
        return o.keys.allSatisfy { knownKeys.contains($0) || $0.hasPrefix("actionDateIs") }
    }

    func rulesMentionProjects(_ rules: [JSON]) -> Bool {
        rules.contains { r in
            if let inner = r["aggregateRules"]?.array { return rulesMentionProjects(inner) }
            return r["actionIsProject"] != nil || r["actionIsProjectOrGroup"] != nil
        }
    }

    public func evaluate(_ p: Perspective) -> [ResultSection] {
        let includeProjects = rulesMentionProjects(p.rules)
        let ids = s.tasks.values.filter { t in
            (includeProjects || !t.isProject) && matches(t, rules: p.rules, aggregation: p.aggregation)
        }.map(\.id)
        return group(sort(ids, by: p.sortBy, defaultCompletedFirst: p.rules.contains { $0["actionAvailability"]?.string == "completed" }), by: p.groupBy)
    }

    public func count(_ p: Perspective) -> Int {
        let includeProjects = rulesMentionProjects(p.rules)
        return s.tasks.values.reduce(0) { n, t in
            n + ((includeProjects || !t.isProject) && matches(t, rules: p.rules, aggregation: p.aggregation) ? 1 : 0)
        }
    }

    public func matches(_ t: TaskItem, rules: [JSON], aggregation: String) -> Bool {
        let active = rules.filter { $0["disabledRule"] == nil }
        if active.isEmpty { return true }
        switch aggregation {
        case "any": return active.contains { match(t, $0) }
        case "none": return !active.contains { match(t, $0) }
        default: return active.allSatisfy { match(t, $0) }
        }
    }

    func match(_ t: TaskItem, _ rule: JSON) -> Bool {
        guard let o = rule.object else { return true }
        let i = s.info[t.id] ?? TaskInfo()
        if let agg = o["aggregateType"]?.string, let inner = o["aggregateRules"]?.array {
            return matches(t, rules: inner, aggregation: agg)
        }
        if let v = o["actionAvailability"]?.string {
            switch v {
            case "available": return i.isAvailable
            case "remaining": return i.isRemaining
            case "completed": return i.effectivelyCompleted
            case "dropped": return i.effectivelyDropped
            case "firstAvailable": return i.isFirstAvailable
            default: return true
            }
        }
        if let v = o["actionStatus"]?.string {
            switch v {
            case "flagged": return i.effectiveFlagged
            case "due": return (i.effectiveDue.map { $0 <= s.dueSoon }) ?? false
            default: return true
            }
        }
        if let tags = o["actionHasAnyOfTags"]?.array?.compactMap(\.string) {
            return !Set(tags).isDisjoint(with: t.tagIDs)
        }
        if let tags = o["actionHasAllOfTags"]?.array?.compactMap(\.string) {
            return Set(tags).isSubset(of: t.tagIDs)
        }
        if let v = o["actionHasTagWithStatus"]?.string {
            return t.tagIDs.contains { id in
                guard let tag = s.tags[id] else { return false }
                switch v {
                case "active": return tag.status == .active
                case "onHold": return tag.status == .onHold
                case "dropped": return tag.status == .dropped
                case "remaining": return tag.status != .dropped
                default: return true
                }
            }
        }
        if o["actionIsUntagged"] != nil { return t.tagIDs.filter { s.tags[$0] != nil }.isEmpty == (o["actionIsUntagged"]?.bool ?? true) }
        if let v = o["actionHasProjectWithStatus"]?.string {
            guard let pid = i.projectID, let p = s.tasks[pid] else { return false }
            let pi = s.projectInfo[pid]
            switch v {
            case "active": return p.status == .active
            case "onHold": return p.status == .onHold
            case "remaining": return p.status == .active || p.status == .onHold
            case "completed": return p.status == .done
            case "dropped": return p.status == .dropped
            case "stalled": return pi?.isStalled ?? false
            case "pending": return pi?.isPending ?? false
            default: return true
            }
        }
        if let focus = o["actionWithinFocus"]?.array?.compactMap(\.string) {
            if focus.isEmpty { return true }
            let set = Set(focus)
            return set.contains(t.id) || s.ancestors(of: t.id).contains { set.contains($0) }
        }
        if let v = o["actionHasDueDate"]?.bool { return (t.dueDate != nil) == v }
        if let v = o["actionHasDeferDate"]?.bool { return (t.deferDate != nil) == v }
        if let v = o["actionHasPlannedDate"]?.bool { return (t.plannedDate != nil) == v }
        if let v = o["actionRepeats"]?.bool { return (t.repeatRule != nil) == v }
        if let v = o["actionIsLeaf"]?.bool { return !i.hasChildren == v }
        if let v = o["actionIsProject"]?.bool { return t.isProject == v }
        if let v = o["actionIsGroup"]?.bool { return (!t.isProject && i.hasChildren) == v }
        if let v = o["actionHasNoProject"]?.bool { return (i.projectID == nil && !t.isProject) == v }
        if let v = o["actionIsInSingleActionsList"]?.bool {
            return (i.projectID.flatMap { s.tasks[$0]?.singleActions } ?? false) == v
        }
        if let v = o["actionIsProjectOrGroup"] {
            let kind = t.isProject ? "project" : (i.hasChildren ? "group" : "neither")
            if let str = v.string { return str == kind }
            if let arr = v.array?.compactMap(\.string) { return arr.contains(kind) }
            return true
        }
        if let terms = o["actionMatchingSearch"]?.array?.compactMap(\.string) {
            let hay = t.title + " " + t.note
            return terms.allSatisfy { Fuzzy.containsAllWords($0, in: hay) }
        }
        if let d = o["actionHasDuration"] {
            guard let e = t.estimatedMinutes else { return false }
            if let lt = d["lessThan"]?.int { return e < lt }
            if let gt = d["greaterThan"]?.int { return e > gt }
            if let eq = d.int { return e <= eq }
            return true
        }
        if let field = o["actionDateField"]?.string {
            return matchDate(t, i, field: field, o)
        }
        return true // unknown rule: preserved, not enforced
    }

    func dateValue(_ t: TaskItem, _ i: TaskInfo, _ field: String) -> Date? {
        switch field {
        case "due": return i.effectiveDue
        case "defer": return i.effectiveDefer
        case "planned": return t.plannedDate
        case "completed": return t.completedAt
        case "dropped": return t.droppedAt
        case "added", "created": return t.createdAt
        case "changed", "modified": return t.modifiedAt
        default: return nil
        }
    }

    func matchDate(_ t: TaskItem, _ i: TaskInfo, field: String, _ o: [String: JSON]) -> Bool {
        guard let d = dateValue(t, i, field) else { return false }
        let cal = Calendar.current
        let today = cal.startOfDay(for: s.now)
        if o["actionDateIsToday"] != nil { return cal.isDate(d, inSameDayAs: s.now) }
        if o["actionDateIsYesterday"] != nil { return cal.isDate(d, inSameDayAs: cal.date(byAdding: .day, value: -1, to: today)!) }
        if o["actionDateIsTomorrow"] != nil { return cal.isDate(d, inSameDayAs: cal.date(byAdding: .day, value: 1, to: today)!) }
        func span(_ v: JSON) -> DateComponents {
            let n = v["amount"]?.int ?? v["relativeAmount"]?.int ?? v.int ?? 1
            let unit = v["unit"]?.string ?? v["relativeComponent"]?.string ?? "day"
            var c = DateComponents()
            switch unit.lowercased().prefix(1) {
            case "w": c.day = 7 * n
            case "m": c.month = n
            case "y": c.year = n
            default: c.day = n
            }
            return c
        }
        if let v = o["actionDateIsInTheNext"] {
            let end = cal.date(byAdding: span(v), to: today)!
            return d >= today && d < cal.date(byAdding: .day, value: 1, to: end)!
        }
        if let v = o["actionDateIsInThePast"] {
            let start = cal.date(byAdding: span(v).negated, to: today)!
            return d >= start && d <= s.now
        }
        if o["actionDateIsOverdue"] != nil || o["actionDateIsPast"] != nil { return d < s.now }
        return true
    }

    // MARK: Sorting & grouping

    public func sort(_ ids: [String], by sort: SortBy, defaultCompletedFirst: Bool = false) -> [String] {
        let manual = manualOrder()
        func cmpDate(_ a: Date?, _ b: Date?, ascending: Bool = true) -> Bool? {
            switch (a, b) {
            case (nil, nil): return nil
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?): return x == y ? nil : (ascending ? x < y : x > y)
            }
        }
        return ids.sorted { a, b in
            guard let ta = s.tasks[a], let tb = s.tasks[b] else { return a < b }
            let ia = s.info[a], ib = s.info[b]
            let r: Bool?
            switch sort {
            case .manual: r = nil
            case .due: r = cmpDate(ia?.effectiveDue, ib?.effectiveDue)
            case .deferDate: r = cmpDate(ia?.effectiveDefer, ib?.effectiveDefer)
            case .planned: r = cmpDate(ta.plannedDate, tb.plannedDate)
            case .added: r = cmpDate(ta.createdAt, tb.createdAt, ascending: false)
            case .changed: r = cmpDate(ta.modifiedAt, tb.modifiedAt, ascending: false)
            case .completed: r = cmpDate(ta.completedAt, tb.completedAt, ascending: false)
            case .title: r = ta.title.localizedStandardCompare(tb.title) == .orderedSame ? nil : ta.title.localizedStandardCompare(tb.title) == .orderedAscending
            case .flagged: r = (ia?.effectiveFlagged ?? false) == (ib?.effectiveFlagged ?? false) ? nil : (ia?.effectiveFlagged ?? false)
            }
            if let r { return r }
            return (manual[a] ?? Int.max, a) < (manual[b] ?? Int.max, b)
        }
    }

    /// Outline position of every task (library first, then inbox).
    public func manualOrder() -> [String: Int] {
        var out: [String: Int] = [:]
        var n = 0
        func walk(_ key: String) {
            for id in s.children[key] ?? [] {
                if s.tasks[id] != nil || s.folders[id] != nil { out[id] = n; n += 1; walk(id) }
            }
        }
        walk(Snapshot.inboxKey)
        walk(Snapshot.libraryKey)
        return out
    }

    public func group(_ ids: [String], by g: GroupBy) -> [ResultSection] {
        let cal = Calendar.current
        func dayBucket(_ d: Date?) -> (key: String, title: String, sort: Double) {
            guard let d else { return ("none", "No date", .infinity) }
            let today = cal.startOfDay(for: s.now)
            let day = cal.startOfDay(for: d)
            let diff = cal.dateComponents([.day], from: today, to: day).day ?? 0
            if diff < 0 { return ("past", "Past", -1) }
            if diff == 0 { return ("today", "Today", 0) }
            if diff == 1 { return ("tomorrow", "Tomorrow", 1) }
            if diff < 7 {
                let f = DateFormatter(); f.dateFormat = "EEEE"
                return ("d\(diff)", f.string(from: d), Double(diff))
            }
            if diff < 30 { return ("month", "Within a month", 30) }
            return ("later", "Later", 60)
        }
        var buckets: [String: (title: String, sort: String, ids: [String])] = [:]
        func add(_ key: String, _ title: String, _ sort: String, _ id: String) {
            buckets[key, default: (title, sort, [])].ids.append(id)
        }
        let manual = manualOrder()
        for id in ids {
            guard let t = s.tasks[id] else { continue }
            let i = s.info[id]
            switch g {
            case .none:
                add("all", "", "", id)
            case .project:
                if let pid = i?.projectID, let p = s.tasks[pid] {
                    add(pid, p.title, String(format: "1%09d", manual[pid] ?? 0), id)
                } else {
                    add("inbox", "Inbox", "0", id)
                }
            case .folder:
                let fid = i?.projectID.flatMap { s.projectInfo[$0]?.folderID } ?? (t.isProject ? s.projectInfo[id]?.folderID : nil)
                if let fid, let f = s.folders[fid] { add(fid, f.name, String(format: "1%09d", manual[fid] ?? 0), id) }
                else { add("nofolder", "No folder", "0", id) }
            case .tag:
                let order = Dictionary(uniqueKeysWithValues: s.orderedTags.enumerated().map { ($1.tag.id, $0) })
                let tags = t.tagIDs.filter { s.tags[$0] != nil }
                if tags.isEmpty { add("untagged", "Untagged", "z", id) }
                for tag in tags { add(tag, s.tags[tag]!.name, String(format: "1%09d", order[tag] ?? 0), id) }
            case .due:
                let b = dayBucket(i?.effectiveDue); add(b.key, b.title, String(format: "%012.0f", b.sort + 10), id)
            case .deferDate:
                let b = dayBucket(i?.effectiveDefer); add(b.key, b.title, String(format: "%012.0f", b.sort + 10), id)
            case .completed:
                let b = dayBucket(t.completedAt)
                add(b.key, b.key == "past" ? "Earlier" : b.title, String(format: "%012.0f", b.sort + 10), id)
            case .flagged:
                if i?.effectiveFlagged == true { add("flagged", "Flagged", "0", id) } else { add("unflagged", "Not flagged", "1", id) }
            }
        }
        // Completed-date groups read best newest first; everything else ascending.
        let sorted = buckets.sorted { g == .completed ? $0.value.sort > $1.value.sort : $0.value.sort < $1.value.sort }
        return sorted.map { ResultSection(id: $0.key, title: $0.value.title, taskIDs: $0.value.ids) }
    }
}

private extension DateComponents {
    var negated: DateComponents {
        var c = DateComponents()
        c.day = day.map { -$0 }; c.month = month.map { -$0 }; c.year = year.map { -$0 }
        return c
    }
}
