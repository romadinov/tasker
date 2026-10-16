import SwiftUI
import TaskerCore

struct InspectorColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        Group {
            if model.selection.count == 1, let id = model.selection.first {
                if s.tasks[id] != nil {
                    TaskInspector(id: id).id(id)
                } else if s.folders[id] != nil {
                    FolderInspector(id: id).id(id)
                } else {
                    placeholder("Nothing selected")
                }
            } else if model.selection.count > 1 {
                MultiInspector(ids: Array(model.selection))
            } else if model.sidebar == .tags {
                TagListInspector()
            } else {
                placeholder("Select an item to see its details")
            }
        }
    }

    func placeholder(_ text: String) -> some View {
        ContentUnavailableView(text, systemImage: "sidebar.right")
    }
}

/// Text field that commits on submit / focus loss instead of per keystroke (keeps the op log lean).
struct CommitField: View {
    let label: String
    let value: String
    var axis: Axis = .horizontal
    var minLines = 1
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text(label), axis: axis)
            .labelsHidden()
            .focused($focused)
            .lineLimit(axis == .vertical ? minLines...20 : 1...1)
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focused { text = v } }
            .onChange(of: focused) { _, f in if !f && text != value { commit(text) } }
            .onSubmit { if text != value { commit(text) } }
            .onDisappear { if text != value { commit(text) } }
    }
}

struct DateRow: View {
    let label: String
    let icon: String
    let date: Date?
    let defaultHour: Int
    let set: (Date?) -> Void
    @Environment(AppModel.self) private var model
    @State private var typed = ""

    var body: some View {
        HStack {
            Label(label, systemImage: icon).frame(minWidth: 90, alignment: .leading)
            Spacer()
            if let date {
                DatePicker("", selection: Binding(get: { date }, set: { set($0) }), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                Button { set(nil) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
            } else {
                TextField("Date", text: $typed, prompt: Text("today, fri, +3d"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                    .onSubmit {
                        if let d = QuickEntryParser(snapshot: model.snapshot).date(typed, hour: defaultHour) { set(d); typed = "" }
                    }
                Menu {
                    Button("Today") { quick("today") }
                    Button("Tomorrow") { quick("tomorrow") }
                    Button("Next Monday") { quick("mon") }
                    Button("In a week") { quick("+7d") }
                    Button("In a month") { quick("+1m") }
                } label: { Image(systemName: "calendar.badge.plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    func quick(_ s: String) { set(QuickEntryParser(snapshot: model.snapshot).date(s, hour: defaultHour)) }
}

struct TaskInspector: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let s = model.snapshot
        if let t = s.tasks[id] {
            let i = s.info[id] ?? TaskInfo()
            Form {
                Section {
                    HStack(alignment: .top) {
                        if t.isProject { ProjectIcon(project: t) } else { CheckCircle(task: t, info: i) { model.toggleComplete(id) } }
                        CommitField(label: t.isProject ? "Project name" : "Title", value: t.title, axis: .vertical) { v in
                            model.perform("Rename") { $0.setTask(id, F.title, .string(v)) }
                        }
                        .font(.title3)
                    }
                    LabeledContent(t.isProject ? "Folder" : "Project") {
                        Button(locationName(t, s)) { model.moveTargetFor = [id] }
                            .buttonStyle(.borderless)
                    }
                    TagEditor(task: t)
                }

                Section("Dates") {
                    DateRow(label: "Defer", icon: "moon.zzz", date: t.deferDate, defaultHour: 0) { model.setDate([id], F.deferDate, $0) }
                    DateRow(label: "Planned", icon: "calendar.badge.clock", date: t.plannedDate, defaultHour: 9) { model.setDate([id], F.plannedDate, $0) }
                    DateRow(label: "Due", icon: "calendar", date: t.dueDate, defaultHour: 17) { model.setDate([id], F.dueDate, $0) }
                    if let inherited = i.effectiveDue, t.dueDate == nil {
                        LabeledContent("Due (inherited)", value: Fmt.relative(inherited, now: s.now)).foregroundStyle(.secondary)
                    }
                    Toggle(isOn: Binding(get: { t.flagged }, set: { v in model.perform(v ? "Flag" : "Unflag") { $0.setTask(id, F.flagged, .bool(v)) } })) {
                        Label("Flagged", systemImage: "flag")
                    }
                    EstimateRow(minutes: t.estimatedMinutes) { m in model.perform("Estimate") { $0.setTask(id, F.estimate, .optional(m)) } }
                }

                Section("Repeat") {
                    RepeatEditor(rule: t.repeatRule) { r in
                        model.perform("Repeat") { $0.setTask(id, F.repeatRule, r.map { JSON(encoding: $0) } ?? .null) }
                    }
                }

                if t.isProject { ProjectSection(project: t) } else if i.hasChildren {
                    Section("Action group") {
                        Picker("Children", selection: Binding(get: { t.sequential }, set: { v in model.perform("Change Type") { $0.setTask(id, F.sequential, .bool(v)) } })) {
                            Text("Parallel").tag(false); Text("Sequential").tag(true)
                        }
                        Toggle("Complete with last action", isOn: Binding(get: { t.completesWithChildren }, set: { v in model.perform("Change") { $0.setTask(id, F.autoComplete, .bool(v)) } }))
                    }
                }

                Section("Note") {
                    CommitField(label: "Note", value: t.note, axis: .vertical, minLines: 4) { v in model.perform("Edit Note") { $0.setTask(id, F.note, .string(v)) } }
                        .font(.body)
                    ForEach(links(t.note), id: \.self) { url in
                        Link(destination: url) { Label(url.absoluteString, systemImage: "link").lineLimit(1) }
                    }
                }

                Section {
                    if let c = t.createdAt { LabeledContent("Added", value: c.formatted(date: .abbreviated, time: .shortened)) }
                    LabeledContent("Changed", value: t.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    if let c = t.completedAt { LabeledContent("Completed", value: c.formatted(date: .abbreviated, time: .shortened)) }
                    if let d = t.droppedAt { LabeledContent("Dropped", value: d.formatted(date: .abbreviated, time: .shortened)) }
                    if i.isBlocked { LabeledContent("Status", value: "Waiting on earlier actions") }
                    else if i.hasOnHoldTag { LabeledContent("Status", value: "On hold (tag)") }
                    else if i.isDeferred { LabeledContent("Status", value: "Deferred") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle(t.isProject ? "Project" : "Action")
        }
    }

    func locationName(_ t: TaskItem, _ s: Snapshot) -> String {
        if t.isProject { return s.projectInfo[t.id]?.folderID.flatMap { s.folders[$0]?.name } ?? "No folder" }
        let path = s.path(of: t.id)
        return path.isEmpty ? "Inbox" : path
    }

    func links(_ note: String) -> [URL] {
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return det.matches(in: note, range: NSRange(note.startIndex..., in: note)).compactMap(\.url).prefix(5).map { $0 }
    }
}

struct EstimateRow: View {
    let minutes: Int?
    let set: (Int?) -> Void
    var body: some View {
        HStack {
            Label("Estimate", systemImage: "clock")
            Spacer()
            Menu(minutes.map(Fmt.estimate) ?? "None") {
                ForEach([5, 10, 15, 30, 45, 60, 90, 120, 240], id: \.self) { m in Button(Fmt.estimate(m)) { set(m) } }
                Divider()
                Button("None") { set(nil) }
            }
            .fixedSize()
        }
    }
}

struct TagEditor: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    @State private var newTagName = ""
    @State private var askingName = false

    var body: some View {
        let s = model.snapshot
        HStack(alignment: .firstTextBaseline) {
            Text("Tags")
            Spacer()
            FlowTags(names: task.tagIDs.compactMap { id in s.tags[id].map { (id, $0.name) } }) { id in
                model.perform("Remove Tag") { $0.setTag(task.id, id, false) }
            }
            Menu {
                ForEach(s.orderedTags, id: \.tag.id) { entry in
                    let has = task.tagIDs.contains(entry.tag.id)
                    Button {
                        model.perform(has ? "Remove Tag" : "Add Tag") { $0.setTag(task.id, entry.tag.id, !has) }
                    } label: {
                        Label(String(repeating: "   ", count: entry.depth) + entry.tag.name, systemImage: has ? "checkmark" : "")
                    }
                }
                Divider()
                Button("New Tag…") { askingName = true }
            } label: { Image(systemName: "tag.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .alert("New Tag", isPresented: $askingName) {
            TextField("Name", text: $newTagName)
            Button("Add") {
                let name = newTagName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                model.perform("New Tag") { tx in let id = tx.createTag(name); tx.setTag(task.id, id, true) }
                newTagName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct FlowTags: View {
    let names: [(String, String)]
    let remove: (String) -> Void
    var body: some View {
        HStack(spacing: 4) {
            ForEach(names, id: \.0) { pair in
                Button { remove(pair.0) } label: {
                    Badge(text: pair.1, systemImage: "xmark", color: Palette.tag)
                }
                .buttonStyle(.plain)
                .help("Remove tag")
            }
        }
    }
}

struct RepeatEditor: View {
    let rule: RepeatRule?
    let set: (RepeatRule?) -> Void

    enum Kind: String, CaseIterable { case none, daily, weekly, monthly, yearly }

    var body: some View {
        let parsed = rule?.parsed
        let kind: Kind = switch parsed?.freq {
        case nil: .none; case .daily, .hourly, .minutely: .daily; case .weekly: .weekly; case .monthly: .monthly; case .yearly: .yearly
        }
        Picker("Repeat", selection: Binding(get: { kind }, set: { k in
            switch k {
            case .none: set(nil)
            case .daily: set(updated { $0.freq = .daily; $0.byDay = []; $0.byMonthDay = [] })
            case .weekly: set(updated { $0.freq = .weekly; $0.byMonthDay = [] })
            case .monthly: set(updated { $0.freq = .monthly; $0.byDay = [] })
            case .yearly: set(updated { $0.freq = .yearly; $0.byDay = []; $0.byMonthDay = [] })
            }
        })) {
            Text("Never").tag(Kind.none); Text("Daily").tag(Kind.daily); Text("Weekly").tag(Kind.weekly)
            Text("Monthly").tag(Kind.monthly); Text("Yearly").tag(Kind.yearly)
        }
        if let rule, let parsed {
            Stepper("Every \(parsed.interval) \(unit(parsed.freq))\(parsed.interval == 1 ? "" : "s")", value: Binding(get: { parsed.interval }, set: { v in set(updated { $0.interval = max(1, v) }) }), in: 1...365)
            if parsed.freq == .weekly {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { offset in
                        let wd = (Calendar.current.firstWeekday + offset - 2) % 7 + 1
                        let on = parsed.byDay.contains { $0.weekday == wd }
                        Button(Calendar.current.veryShortWeekdaySymbols[wd - 1]) {
                            set(updated { r in
                                if on { r.byDay.removeAll { $0.weekday == wd } } else { r.byDay.append(.init(ordinal: nil, weekday: wd)); r.byDay.sort { $0.weekday < $1.weekday } }
                            })
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .secondary)
                    }
                }
            }
            Picker("Schedule", selection: Binding(get: { rule.fromCompletion }, set: { v in var r = rule; r.fromCompletion = v; set(r) })) {
                Text("Regularly").tag(false); Text("From completion").tag(true)
            }
            Picker("Based on", selection: Binding(get: { rule.anchor }, set: { v in var r = rule; r.anchor = v; set(r) })) {
                Text("Due date").tag(RepeatRule.Anchor.due); Text("Defer date").tag(RepeatRule.Anchor.deferDate); Text("Planned date").tag(RepeatRule.Anchor.planned)
            }
            Text(rule.summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    func unit(_ f: RRule.Freq) -> String {
        switch f { case .minutely: "minute"; case .hourly: "hour"; case .daily: "day"; case .weekly: "week"; case .monthly: "month"; case .yearly: "year" }
    }

    func updated(_ change: (inout RRule) -> Void) -> RepeatRule {
        var base = rule ?? RepeatRule(rrule: "FREQ=WEEKLY")
        var r = base.parsed
        change(&r)
        base.rrule = r.string
        return base
    }
}

struct ProjectSection: View {
    @Environment(AppModel.self) private var model
    let project: TaskItem

    var body: some View {
        let id = project.id
        Section("Project") {
            Picker("Status", selection: Binding(get: { project.status }, set: { v in
                model.perform("Change Status") { tx in
                    tx.setTask(id, F.status, .string(v.rawValue))
                    tx.setTask(id, F.completed, v == .done ? .date(Date()) : .null)
                    tx.setTask(id, F.dropped, v == .dropped ? .date(Date()) : .null)
                }
            })) { ForEach(ProjectStatus.allCases, id: \.self) { Text($0.label).tag($0) } }
            Picker("Type", selection: Binding(get: { project.singleActions ? 2 : (project.sequential ? 1 : 0) }, set: { v in
                model.perform("Change Type") { tx in
                    tx.setTask(id, F.sequential, .bool(v == 1))
                    tx.setTask(id, F.singleActions, .bool(v == 2))
                }
            })) {
                Text("Parallel").tag(0); Text("Sequential").tag(1); Text("Single actions").tag(2)
            }
            Toggle("Complete with last action", isOn: Binding(get: { project.completesWithChildren }, set: { v in model.perform("Change") { $0.setTask(id, F.autoComplete, .bool(v)) } }))
        }
        Section("Review") {
            let interval = project.reviewInterval ?? .weekly
            HStack {
                Stepper("Every \(interval.count)", value: Binding(get: { interval.count }, set: { v in
                    model.perform("Review Interval") { $0.setTask(id, F.reviewEvery, JSON(encoding: ReviewInterval(count: max(1, v), unit: interval.unit))) }
                }), in: 1...99)
                Picker("", selection: Binding(get: { interval.unit }, set: { u in
                    model.perform("Review Interval") { $0.setTask(id, F.reviewEvery, JSON(encoding: ReviewInterval(count: interval.count, unit: u))) }
                })) { ForEach(ReviewInterval.Unit.allCases, id: \.self) { Text($0.rawValue + "s").tag($0) } }
                .labelsHidden().fixedSize()
            }
            if let n = project.nextReviewDate { LabeledContent("Next review", value: Fmt.relative(n)) }
            if let l = project.lastReviewDate { LabeledContent("Last reviewed", value: Fmt.relative(l)) }
            Button("Mark Reviewed") {
                model.perform("Mark Reviewed") { $0.markReviewed(id) }
                model.recentlyCompleted.insert(id)
            }
        }
    }
}

struct FolderInspector: View {
    @Environment(AppModel.self) private var model
    let id: String
    var body: some View {
        if let f = model.snapshot.folders[id] {
            Form {
                CommitField(label: "Folder name", value: f.name) { v in model.perform("Rename Folder") { $0.set(.folder, id, F.name, .string(v)) } }
                    .font(.title3)
                Toggle("Dropped", isOn: Binding(get: { f.dropped }, set: { v in model.perform("Change Folder") { $0.set(.folder, id, F.status, v ? "dropped" : "active") } }))
                Button("Move To…") { model.moveTargetFor = [id] }
            }
            .formStyle(.grouped)
            .navigationTitle("Folder")
        }
    }
}

struct TagListInspector: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""
    var body: some View {
        let s = model.snapshot
        Form {
            Section("Tags") {
                ForEach(s.orderedTags, id: \.tag.id) { entry in
                    HStack {
                        CommitField(label: "Tag", value: entry.tag.name) { v in model.perform("Rename Tag") { $0.set(.tag, entry.tag.id, F.name, .string(v)) } }
                            .padding(.leading, CGFloat(entry.depth) * 14)
                        Picker("", selection: Binding(get: { entry.tag.status }, set: { v in model.perform("Tag Status") { $0.setTagStatus(entry.tag.id, v) } })) {
                            ForEach(TagStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    .contextMenu { Button("Delete Tag", role: .destructive) { model.perform("Delete Tag") { $0.set(.tag, entry.tag.id, F.deleted, true) } } }
                }
                TextField("New tag", text: $newName).onSubmit {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { model.perform("New Tag") { $0.createTag(n) }; newName = "" }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tags")
    }
}

struct MultiInspector: View {
    @Environment(AppModel.self) private var model
    let ids: [String]
    var body: some View {
        Form {
            Text("\(ids.count) items selected").font(.headline)
            Button("Complete") { for id in ids { model.toggleComplete(id) } }
            Button("Flag / Unflag") { model.toggleFlag(ids) }
            Button("Move To…") { model.moveTargetFor = ids }
            DateRow(label: "Defer all", icon: "moon.zzz", date: nil, defaultHour: 0) { model.setDate(ids, F.deferDate, $0) }
            DateRow(label: "Due all", icon: "calendar", date: nil, defaultHour: 17) { model.setDate(ids, F.dueDate, $0) }
            Button("Delete", role: .destructive) { model.deleteItems(ids) }
        }
        .formStyle(.grouped)
    }
}

/// Searchable destination picker for moving actions, projects and folders.
struct MoveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    @State private var query = ""

    var body: some View {
        let s = model.snapshot
        let movingProjectsOrFolders = ids.allSatisfy { s.tasks[$0]?.isProject == true || s.folders[$0] != nil }
        NavigationStack {
            List {
                if movingProjectsOrFolders {
                    Button { model.moveItems(ids, to: nil); dismiss() } label: { Label("Top level", systemImage: "square.stack.3d.up") }
                    ForEach(s.orderedFolders.filter { matches($0.folder.name) && !ids.contains($0.folder.id) }, id: \.folder.id) { e in
                        Button { model.moveItems(ids, to: e.folder.id); dismiss() } label: {
                            Label(e.folder.name, systemImage: "folder").padding(.leading, CGFloat(e.depth) * 14)
                        }
                    }
                } else {
                    Button { model.moveItems(ids, to: nil); dismiss() } label: { Label("Inbox", systemImage: "tray") }
                    ForEach(s.orderedProjects.filter { s.info[$0.id]?.isRemaining == true && matches($0.title + " " + s.path(of: $0.id)) }) { p in
                        Button { model.moveItems(ids, to: p.id); dismiss() } label: {
                            VStack(alignment: .leading) {
                                Label(p.title, systemImage: "circle.grid.2x2")
                                let path = s.path(of: p.id)
                                if !path.isEmpty { Text(path).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .searchable(text: $query, prompt: movingProjectsOrFolders ? "Folder" : "Project")
            .navigationTitle("Move \(ids.count == 1 ? "item" : "\(ids.count) items")")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    func matches(_ s: String) -> Bool { query.isEmpty || s.localizedCaseInsensitiveContains(query) }
}
