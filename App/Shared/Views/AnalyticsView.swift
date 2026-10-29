import Charts
import SwiftUI
import TaskerCore

/// Analytics & trends: throughput, backlog, lead time, when work gets done, where it goes.
/// Everything is computed from the items' added/completed/dropped/due dates, so it covers the
/// whole imported history and needs no extra tracking.
struct AnalyticsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("analytics.range") private var range: AnalyticsRange = .quarter

    var body: some View {
        let a = Analytics(snapshot: model.snapshot, range: range)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Analytics").font(.largeTitle.bold()).foregroundStyle(Color.teal)
                    Spacer()
                    Picker("Range", selection: $range) {
                        ForEach(AnalyticsRange.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    Kpi(title: "Completed this week", value: "\(a.completedThisWeek)",
                        detail: delta(a.completedThisWeek, a.completedLastWeek, suffix: "vs last week"))
                    Kpi(title: "Per day (\(range.shortLabel))", value: String(format: "%.1f", a.perDay), detail: "\(a.completedInRange) completed")
                    Kpi(title: "Added vs done", value: a.netFlow >= 0 ? "+\(a.netFlow)" : "\(a.netFlow)",
                        detail: a.netFlow > 0 ? "backlog growing" : "backlog shrinking", tint: a.netFlow > 0 ? .orange : .green)
                    Kpi(title: "Open actions", value: "\(a.openNow)", detail: "\(a.availableNow) available")
                    Kpi(title: "Overdue", value: "\(a.overdue)", detail: "\(a.dueThisWeek) due in 7 days", tint: a.overdue > 0 ? .red : .secondary)
                    Kpi(title: "Median time to done", value: Analytics.duration(a.medianLeadDays), detail: "added → completed")
                    Kpi(title: "Streak", value: "\(a.streak) d", detail: "days in a row with a completion")
                    Kpi(title: "Focus this week", value: Fmt.estimate(a.focusThisWeek), detail: "\(a.pomodorosThisWeek) pomodoros 🍅")
                    Kpi(title: "Projects", value: "\(a.activeProjects)", detail: "\(a.stalledProjects) stalled · \(a.reviewDue) to review",
                        tint: a.stalledProjects > 0 ? .orange : .secondary)
                }

                Card("Completed and added per \(range.bucketName)") {
                    Chart {
                        ForEach(a.flow) { b in
                            BarMark(x: .value("Period", b.start, unit: range.unit), y: .value("Count", b.completed))
                                .foregroundStyle(by: .value("Kind", "Completed"))
                                .position(by: .value("Kind", "Completed"))
                            BarMark(x: .value("Period", b.start, unit: range.unit), y: .value("Count", b.added))
                                .foregroundStyle(by: .value("Kind", "Added"))
                                .position(by: .value("Kind", "Added"))
                        }
                    }
                    .chartForegroundStyleScale(["Completed": Color.green, "Added": Color.blue.opacity(0.55)])
                    .weekdayAxis(range == .week)
                    .frame(height: 200)
                }

                Card("Open actions over time") {
                    Chart(a.backlog) { p in
                        AreaMark(x: .value("Date", p.date), yStart: .value("Base", a.backlogDomain.lowerBound), yEnd: .value("Open", p.open))
                            .foregroundStyle(.linearGradient(colors: [.teal.opacity(0.35), .teal.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", p.date), y: .value("Open", p.open)).foregroundStyle(.teal)
                    }
                    // Zoomed to the data: the trend matters, not the distance from zero.
                    .chartYScale(domain: a.backlogDomain)
                    .frame(height: 170)
                }

                HStack(alignment: .top, spacing: 16) {
                    Card("When you get things done") {
                        Chart(a.byWeekday) { d in
                            BarMark(x: .value("Day", d.label), y: .value("Completed", d.count))
                                .foregroundStyle(d.count == a.byWeekday.map(\.count).max() ? Color.green : Color.green.opacity(0.45))
                        }
                        .frame(height: 160)
                    }
                    Card("Time to complete") {
                        Chart(a.leadBuckets) { b in
                            BarMark(x: .value("Time", b.label), y: .value("Actions", b.count)).foregroundStyle(.purple.opacity(0.7))
                        }
                        .frame(height: 160)
                    }
                }

                if a.focusInRange > 0 {
                    HStack(alignment: .top, spacing: 16) {
                        Card("Focus time per \(range.bucketName) (pomodoros)") {
                            Chart(a.focus) { b in
                                BarMark(x: .value("Period", b.start, unit: range.unit), y: .value("Minutes", b.completed)).foregroundStyle(.red.opacity(0.7))
                            }
                            .weekdayAxis(range == .week)
                            .frame(height: 150)
                        }
                        Card("Focus by project") { RankList(rows: a.focusByProject, tint: .red) }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    Card("Most completed by project") { RankList(rows: a.topProjects, tint: Palette.project) }
                    Card("Most completed by tag") { RankList(rows: a.topTags, tint: Palette.tag) }
                }

                Card("Coming up: due per day") {
                    Chart(a.upcoming) { d in
                        BarMark(x: .value("Day", d.date, unit: .day), y: .value("Due", d.count))
                            .foregroundStyle(d.count >= 5 ? Color.red.opacity(0.8) : Color.orange.opacity(0.7))
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated).day()) } }
                    .frame(height: 140)
                }

                if !a.stalled.isEmpty {
                    Card("Stalled projects (no available actions)") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(a.stalled, id: \.id) { p in
                                Button {
                                    model.sidebar = .projects
                                    model.projectFocus = [p.id]
                                } label: {
                                    HStack { ProjectIcon(project: p); Text(p.title).foregroundStyle(.primary); Spacer() }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .navigationTitle("Analytics")
    }

    private func delta(_ now: Int, _ before: Int, suffix: String) -> String {
        let d = now - before
        return d == 0 ? "same as last week" : (d > 0 ? "▲ \(d) \(suffix)" : "▼ \(-d) \(suffix)")
    }
}

extension View {
    /// One label per day (Mon 27, Tue 28 …) when the chart shows a single week.
    @ViewBuilder func weekdayAxis(_ on: Bool) -> some View {
        if on {
            chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true) } }
        } else {
            self
        }
    }
}

enum AnalyticsRange: String, CaseIterable, Identifiable {
    case week, month, quarter, half, year
    var id: String { rawValue }
    var label: String { switch self { case .week: "1 week"; case .month: "4 weeks"; case .quarter: "3 months"; case .half: "6 months"; case .year: "1 year" } }
    var shortLabel: String { switch self { case .week: "1 wk"; case .month: "4 wk"; case .quarter: "3 mo"; case .half: "6 mo"; case .year: "1 yr" } }
    var days: Int { switch self { case .week: 7; case .month: 28; case .quarter: 91; case .half: 182; case .year: 365 } }
    var unit: Calendar.Component { self == .week || self == .month ? .day : (self == .year ? .month : .weekOfYear) }
    var bucketName: String { self == .week || self == .month ? "day" : (self == .year ? "month" : "week") }
}

struct Analytics {
    struct Bucket: Identifiable { var start: Date; var completed = 0; var added = 0; var id: Date { start } }
    struct Point: Identifiable { var date: Date; var open: Int; var id: Date { date } }
    struct Labeled: Identifiable { var label: String; var count: Int; var id: String { label } }
    struct Day: Identifiable { var date: Date; var count: Int; var id: Date { date } }

    var completedThisWeek = 0, completedLastWeek = 0, completedInRange = 0, addedInRange = 0
    var perDay = 0.0
    var netFlow: Int { addedInRange - completedInRange }
    var openNow = 0, availableNow = 0, overdue = 0, dueThisWeek = 0
    var medianLeadDays: Double?
    var streak = 0
    var activeProjects = 0, stalledProjects = 0, reviewDue = 0
    var flow: [Bucket] = []
    var backlog: [Point] = []
    var byWeekday: [Labeled] = []
    var leadBuckets: [Labeled] = []
    var topProjects: [Labeled] = []
    var topTags: [Labeled] = []
    var upcoming: [Day] = []
    var stalled: [TaskItem] = []
    // Pomodoro focus (minutes)
    var focusThisWeek = 0, pomodorosThisWeek = 0, focusInRange = 0
    var focus: [Bucket] = []          // `completed` holds minutes
    var focusByProject: [Labeled] = []
    var backlogDomain: ClosedRange<Int> {
        let v = backlog.map(\.open)
        guard let lo = v.min(), let hi = v.max() else { return 0...1 }
        let pad = max(5, (hi - lo) / 5)
        return max(0, lo - pad)...(hi + pad)
    }

    init(snapshot s: Snapshot, range: AnalyticsRange, now: Date = Date()) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let from = cal.date(byAdding: .day, value: -range.days + 1, to: today)!
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let lastWeekStart = cal.date(byAdding: .day, value: -7, to: weekStart)!
        let actions = s.tasks.values.filter { !$0.isProject }

        // Buckets for the flow chart.
        var buckets: [Date: Bucket] = [:]
        var cursor = cal.dateInterval(of: range.unit, for: from)?.start ?? from
        while cursor <= now {
            buckets[cursor] = Bucket(start: cursor)
            cursor = cal.date(byAdding: range.unit, value: 1, to: cursor)!
        }
        func bucket(_ d: Date) -> Date? { cal.dateInterval(of: range.unit, for: d)?.start }

        var weekday = Array(repeating: 0, count: 7)
        var leads: [Double] = []
        var perProject: [String: Int] = [:], perTag: [String: Int] = [:]
        var completionDays = Set<Date>()

        for t in actions {
            if let c = t.completedAt {
                completionDays.insert(cal.startOfDay(for: c))
                if c >= weekStart { completedThisWeek += 1 } else if c >= lastWeekStart { completedLastWeek += 1 }
                if c >= from {
                    completedInRange += 1
                    if let b = bucket(c) { buckets[b]?.completed += 1 }
                    weekday[(cal.component(.weekday, from: c) - cal.firstWeekday + 7) % 7] += 1
                    if let a = t.createdAt, c >= a { leads.append(c.timeIntervalSince(a) / 86400) }
                    if let p = s.info[t.id]?.projectID { perProject[p, default: 0] += 1 }
                    for tag in t.tagIDs { perTag[tag, default: 0] += 1 }
                }
            }
            if let a = t.createdAt, a >= from {
                addedInRange += 1
                if let b = bucket(a) { buckets[b]?.added += 1 }
            }
            if let i = s.info[t.id], i.isRemaining {
                openNow += 1
                if i.isAvailable { availableNow += 1 }
                if let due = i.effectiveDue {
                    if due < now { overdue += 1 }
                    else if due < cal.date(byAdding: .day, value: 7, to: now)! { dueThisWeek += 1 }
                }
            }
        }
        flow = buckets.values.sorted { $0.start < $1.start }

        var focusBuckets = Dictionary(uniqueKeysWithValues: buckets.keys.map { ($0, Bucket(start: $0)) })
        var focusProject: [String: Int] = [:]
        for t in actions {
            for f in t.focusSessions {
                if f.at >= weekStart { focusThisWeek += f.minutes; pomodorosThisWeek += 1 }
                guard f.at >= from else { continue }
                focusInRange += f.minutes
                if let b = bucket(f.at) { focusBuckets[b]?.completed += f.minutes }
                if let p = s.info[t.id]?.projectID { focusProject[p, default: 0] += f.minutes }
            }
        }
        focus = focusBuckets.values.sorted { $0.start < $1.start }
        focusByProject = focusProject.sorted { $0.value > $1.value }.prefix(8).map { Labeled(label: s.tasks[$0.key]?.title ?? "?", count: $0.value) }
        perDay = Double(completedInRange) / Double(range.days)

        // When each action stopped being open. Items closed only by their project (completed or dropped
        // project) use the project's date; if none is known they count as closed long ago, so the curve
        // ends at today's open count.
        func closedAt(_ t: TaskItem) -> Date? {
            if s.info[t.id]?.isRemaining == true { return nil }
            if let d = t.completedAt ?? t.droppedAt { return d }
            if let p = s.info[t.id]?.projectID, let pt = s.tasks[p], let d = pt.completedAt ?? pt.droppedAt { return d }
            return .distantPast
        }
        let lifetimes: [(Date, Date?)] = actions.compactMap { t in t.createdAt.map { ($0, closedAt(t)) } }
        // Open actions at the end of each sample day: added before, not closed yet.
        let samples = 40
        let step = max(1, range.days / samples)
        var points: [Point] = []
        var d = from
        while d <= today {
            let end = cal.date(byAdding: .day, value: 1, to: d)!
            let open = lifetimes.reduce(0) { n, l in
                guard l.0 < end else { return n }
                if let c = l.1, c < end { return n }
                return n + 1
            }
            points.append(Point(date: d, open: open))
            d = cal.date(byAdding: .day, value: step, to: d)!
        }
        backlog = points

        let symbols = cal.shortWeekdaySymbols
        byWeekday = (0..<7).map { i in Labeled(label: symbols[(i + cal.firstWeekday - 1) % 7], count: weekday[i]) }

        leads.sort()
        medianLeadDays = leads.isEmpty ? nil : leads[leads.count / 2]
        let edges: [(String, Double)] = [("< 1 d", 1), ("1–3 d", 3), ("3–7 d", 7), ("1–4 wk", 28), ("1–3 mo", 91), ("3 mo +", .infinity)]
        var lb = Array(repeating: 0, count: edges.count)
        for l in leads { lb[edges.firstIndex { l < $0.1 } ?? edges.count - 1] += 1 }
        leadBuckets = edges.enumerated().map { Labeled(label: $1.0, count: lb[$0]) }

        topProjects = perProject.sorted { $0.value > $1.value }.prefix(8).map { Labeled(label: s.tasks[$0.key]?.title ?? "?", count: $0.value) }
        topTags = perTag.sorted { $0.value > $1.value }.prefix(8).map { Labeled(label: s.tags[$0.key]?.name ?? "?", count: $0.value) }

        // Streak: consecutive days up to today (or yesterday, if nothing yet today) with a completion.
        var day = completionDays.contains(today) ? today : cal.date(byAdding: .day, value: -1, to: today)!
        while completionDays.contains(day) { streak += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }

        var up: [Date: Int] = [:]
        for n in 0..<14 { up[cal.date(byAdding: .day, value: n, to: today)!] = 0 }
        for t in actions {
            guard let i = s.info[t.id], i.isRemaining, let due = i.effectiveDue, due >= today else { continue }
            let k = cal.startOfDay(for: due)
            if up[k] != nil { up[k]! += 1 }
        }
        upcoming = up.map { Day(date: $0.key, count: $0.value) }.sorted { $0.date < $1.date }

        let projects = s.tasks.values.filter { $0.isProject && $0.status == .active }
        activeProjects = projects.count
        stalled = projects.filter { s.projectInfo[$0.id]?.isStalled == true }.sorted { $0.title < $1.title }
        stalledProjects = stalled.count
        reviewDue = s.projectInfo.values.filter(\.needsReview).count
    }

    static func duration(_ days: Double?) -> String {
        guard let days else { return "—" }
        if days < 1 { return "\(max(1, Int(days * 24))) h" }
        if days < 14 { return String(format: "%.0f d", days) }
        if days < 60 { return String(format: "%.0f wk", days / 7) }
        return String(format: "%.0f mo", days / 30)
    }
}

private struct Kpi: View {
    let title: String
    let value: String
    let detail: String
    var tint: Color = .secondary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(tint).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
    }
}

private struct RankList: View {
    let rows: [Analytics.Labeled]
    let tint: Color
    var body: some View {
        if rows.isEmpty {
            Text("Nothing completed in this range.").font(.callout).foregroundStyle(.secondary)
        } else {
            let top = Double(rows.map(\.count).max() ?? 1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { r in
                    HStack(spacing: 8) {
                        Text(r.label).lineLimit(1).frame(width: 170, alignment: .leading)
                        GeometryReader { g in
                            Capsule().fill(tint.opacity(0.55)).frame(width: max(4, g.size.width * Double(r.count) / top))
                        }
                        .frame(height: 10)
                        Text("\(r.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
    }
}
