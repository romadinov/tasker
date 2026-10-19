import Foundation

/// Inline shorthand for fast capture:
///   `Call Anna about lease #phone #errands ::Home ! due:fri defer:tomorrow ~15m`
/// `#tag`, `::project`, `!` flag, `due:`/`defer:`/`plan:` dates, `~15m`/`~1h` estimate.
public struct QuickEntryParser {
    public struct Result: Equatable {
        public var title: String
        public var tagIDs: [String] = []
        public var unknownTags: [String] = []
        public var projectID: String?
        public var flagged = false
        public var deferDate: Date?
        public var dueDate: Date?
        public var plannedDate: Date?
        public var estimatedMinutes: Int?
        public init(title: String) { self.title = title }
    }

    public let snapshot: Snapshot
    public var now: Date
    public var calendar = Calendar.current
    /// Defaults: due at 17:00, defer at 00:00, planned at 09:00.
    public var dueHour = 17, deferHour = 0, plannedHour = 9

    public init(snapshot: Snapshot, now: Date = Date()) {
        self.snapshot = snapshot; self.now = now
    }

    public func parse(_ text: String) -> Result {
        var r = Result(title: "")
        var words: [String] = []
        for token in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let lower = token.lowercased()
            if token == "!" { r.flagged = true; continue }
            if token.hasPrefix("#"), token.count > 1 {
                let name = String(token.dropFirst())
                if let id = matchTag(name) { if !r.tagIDs.contains(id) { r.tagIDs.append(id) } } else { r.unknownTags.append(name) }
                continue
            }
            // "ЖЖ" is "::" typed on the Russian layout.
            if token.count > 2, (token.hasPrefix("ЖЖ") || token.hasPrefix("жж")) {
                let rest = Fuzzy.layoutColon(String(token.dropFirst(2)), folderNames: snapshot.folders.values.map(\.name))
                if let id = matchProject(rest) { r.projectID = id; continue }
            }
            if token.hasPrefix("::"), token.count > 2 {
                if let id = matchProject(String(token.dropFirst(2))) { r.projectID = id; continue }
            }
            if token.hasPrefix("~"), let m = Self.minutes(String(token.dropFirst())) { r.estimatedMinutes = m; continue }
            if let colon = lower.firstIndex(of: ":"), colon != lower.startIndex {
                let key = String(lower[..<colon]), value = String(lower[lower.index(after: colon)...])
                switch key {
                case "due", "d": if let d = date(value, hour: dueHour) { r.dueDate = d; continue }
                case "defer", "start", "s": if let d = date(value, hour: deferHour) { r.deferDate = d; continue }
                case "plan", "planned", "p": if let d = date(value, hour: plannedHour) { r.plannedDate = d; continue }
                default: break
                }
            }
            words.append(token)
        }
        r.title = words.joined(separator: " ")
        return r
    }

    func matchTag(_ name: String) -> String? {
        let n = name.lowercased().replacingOccurrences(of: "_", with: " ")
        let tags = snapshot.orderedTags.map(\.tag).filter { $0.status != .dropped }
        if let exact = tags.first(where: { $0.name.lowercased() == n }) { return exact.id }
        if let prefix = tags.first(where: { $0.name.lowercased().hasPrefix(n) }) { return prefix.id }
        // Fuzzy only for 3+ letters, so a short new tag like "#ab" isn't swallowed by an unrelated one.
        guard n.count >= 3 else { return nil }
        return Fuzzy.rank(tags, n) { $0.name }.first?.id
    }

    func matchProject(_ name: String) -> String? {
        let spaced = name.replacingOccurrences(of: "_", with: " ")
        if spaced.contains(":") {
            // "::Common:Домашние_дела" — folder path plus project name.
            if let exact = snapshot.project(atPath: spaced) { return exact.id }
            let (folders, last) = Snapshot.splitPath(spaced)
            let l = last.lowercased(), fs = folders.map { $0.lowercased() }
            return snapshot.orderedProjects.first { p in
                snapshot.info[p.id]?.isRemaining == true && p.title.lowercased().hasPrefix(l) &&
                zip(snapshot.folderPath(of: p.id).map { $0.lowercased() }.suffix(fs.count), fs).allSatisfy { $0.hasPrefix($1) }
            }?.id
        }
        let n = spaced.lowercased()
        let projects = snapshot.orderedProjects.filter { snapshot.info[$0.id]?.isRemaining == true }
        if let p = projects.first(where: { $0.title.lowercased() == n }) { return p.id }
        if let p = projects.first(where: { $0.title.lowercased().hasPrefix(n) }) { return p.id }
        return Fuzzy.rank(projects, n) { p in ([p.title] + snapshot.folderPath(of: p.id)).joined(separator: "  ") }.first?.id
    }

    static func minutes(_ s: String) -> Int? {
        let l = s.lowercased()
        if l.hasSuffix("h"), let v = Double(l.dropLast()) { return Int(v * 60) }
        if l.hasSuffix("m"), let v = Int(l.dropLast()) { return v }
        return Int(l)
    }

    /// today, tod, tomorrow, tom, mon…sun, +3d / 3d / 2w / 1m, 2026-10-20, 20.10, 10/20
    public func date(_ raw: String, hour: Int) -> Date? {
        let s = raw.lowercased()
        let today = calendar.startOfDay(for: now)
        func at(_ day: Date) -> Date { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day }
        switch s {
        case "today", "tod", "now": return at(today)
        case "tomorrow", "tom", "tmr": return at(calendar.date(byAdding: .day, value: 1, to: today)!)
        case "yesterday": return at(calendar.date(byAdding: .day, value: -1, to: today)!)
        default: break
        }
        let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        if let idx = weekdays.firstIndex(where: { s.hasPrefix($0) }) {
            let wd = idx + 1
            var d = calendar.date(byAdding: .day, value: 1, to: today)!
            while calendar.component(.weekday, from: d) != wd { d = calendar.date(byAdding: .day, value: 1, to: d)! }
            return at(d)
        }
        let rel = s.hasPrefix("+") ? String(s.dropFirst()) : s
        if let unit = rel.last, "dwmy".contains(unit), let n = Int(rel.dropLast()) {
            let comp: Calendar.Component = switch unit { case "d": .day; case "w": .weekOfYear; case "m": .month; default: .year }
            return at(calendar.date(byAdding: comp, value: n, to: today)!)
        }
        for fmt in ["yyyy-MM-dd", "dd.MM.yyyy", "dd.MM", "MM/dd/yyyy", "MM/dd"] {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            if let d = f.date(from: s) {
                var c = calendar.dateComponents([.year, .month, .day], from: d)
                if !fmt.contains("yyyy") {
                    c.year = calendar.component(.year, from: now)
                    if let candidate = calendar.date(from: c), candidate < today { c.year! += 1 }
                }
                return calendar.date(from: c).map(at)
            }
        }
        return nil
    }
}
