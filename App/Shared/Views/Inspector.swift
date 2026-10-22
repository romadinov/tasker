import SwiftUI
import TaskerCore

struct InspectorColumn: View {
    @Environment(AppModel.self) private var model
    /// The selection the inspector shows. It follows `model.selection` one run-loop turn later, so a click
    /// highlights the row at once and the (rebuilt-per-item) inspector catches up in the next frame;
    /// rapid clicks coalesce into one rebuild.
    @State private var shown: Set<String> = []
    @State private var generation = 0

    var body: some View {
        let s = model.snapshot
        let selection = shown
        Group {
            if selection.count == 1, let id = selection.first {
                if s.tasks[id] != nil {
                    TaskInspector(id: id).id(id)
                } else if s.folders[id] != nil {
                    FolderInspector(id: id).id(id)
                } else {
                    placeholder("Nothing selected")
                }
            } else if selection.isEmpty, model.sidebar == .projects || model.sidebar == .review,
                      model.projectFocus.count == 1, let pid = model.projectFocus.first, s.tasks[pid] != nil {
                TaskInspector(id: pid).id(pid)
            } else if selection.count > 1 {
                MultiInspector(ids: Array(selection))
            } else if model.sidebar == .tags, model.tagFocus.count == 1, let tid = model.tagFocus.first, s.tags[tid] != nil {
                TagInspector(id: tid).id(tid)
            } else if model.sidebar == .tags {
                TagListInspector()
            } else {
                placeholder("Select an item to see its details")
            }
        }
        .onAppear { shown = model.selection }
        .onChange(of: model.selection) { _, new in
            generation += 1
            let g = generation
            DispatchQueue.main.async { if g == generation { shown = new } }
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

struct ProjectPickerRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                let path = s.path(of: task.id)
                Image(systemName: path.isEmpty ? "tray" : "circle.grid.2x2").foregroundStyle(path.isEmpty ? Color.secondary : Palette.project)
                Text(path.isEmpty ? "Inbox" : path).lineLimit(2)
                Spacer()
                if s.info[task.id]?.projectID != nil {
                    Button { model.assignProject([task.id], nil) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help("Move back to the Inbox")
                }
            }
            AutocompleteField(placeholder: "Move to project…", icon: "circle.grid.2x2",
                              suggestions: { Lookup.projects(model.snapshot, $0) },
                                  isExisting: { model.snapshot.project(atPath: $0) != nil },
                              createLabel: Lookup.newProjectLabel,
                              onPick: { model.assignProject([task.id], $0.id) },
                              onCreate: { name in model.assignProject([task.id], model.createProject(named: name)) })
        }
    }
}

struct TagEditor: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tags")
                Spacer()
                FlowTags(names: task.tagIDs.compactMap { id in s.tags[id].map { (id, $0.name) } }) { id in
                    model.perform("Remove Tag") { $0.setTag(task.id, id, false) }
                }
            }
            AutocompleteField(placeholder: "Add tag…", icon: "tag",
                              suggestions: { Lookup.tags(model.snapshot, $0, excluding: Set(task.tagIDs)) },
                              createLabel: { "New tag “\($0)”" },
                              onPick: { tag in model.perform("Add Tag") { $0.setTag(task.id, tag.id, true) } },
                              onCreate: { name in
                                  let tag = model.createTag(named: name)
                                  model.perform("Add Tag") { $0.setTag(task.id, tag, true) }
                              })
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
                model.perform("Change Status") { $0.setProjectStatus(id, v) }
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
            Button("Complete") { model.toggleComplete(ids) }
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
                    Button { model.assignProject(ids, nil); dismiss() } label: { Label("Inbox", systemImage: "tray") }
                    ForEach(s.orderedProjects.filter { s.info[$0.id]?.isRemaining == true && matches($0.title + " " + s.path(of: $0.id)) }) { p in
                        Button { model.assignProject(ids, p.id); dismiss() } label: {
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
