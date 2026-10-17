import SwiftUI
import TaskerCore

// MARK: - Building blocks

struct InspectorSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Segmented row of icon buttons (OmniFocus status / project type controls).
struct IconSegments<T: Hashable>: View {
    let options: [(value: T, icon: String, help: String)]
    let selection: T
    let onSelect: (T) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let on = o.value == selection
                Button { onSelect(o.value) } label: {
                    Image(systemName: o.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(on ? Color.white : .primary)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(o.help)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }
}

/// Rounded "well" used for the title, tags and note boxes.
struct Well<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
    }
}

/// OmniFocus date field: typeable ("fri", "+3d", "tomorrow 5pm"), calendar popover,
/// and quick buttons Today · +1d · +1w · +1m · clear.
struct OFDateField: View {
    @Environment(AppModel.self) private var model
    let date: Date?
    let defaultHour: Int
    let set: (Date?) -> Void
    @State private var text = ""
    @State private var picking = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                TextField("None", text: $text, prompt: Text("None"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commitText)
                    .onChange(of: focused) { _, f in if !f { commitText() } }
                Button { picking = true } label: { Image(systemName: "calendar") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $picking) {
                        VStack {
                            DatePicker("", selection: Binding(get: { date ?? defaultDate(Date()) }, set: { set($0) }), displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.graphical)
                                .labelsHidden()
                            HStack { Spacer(); Button("Done") { picking = false } }
                        }
                        .padding()
                        .frame(minWidth: 280)
                        .presentationCompactAdaptation(.popover)
                    }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            HStack(spacing: 1) {
                quick(icon: "sun.horizon", help: "Today") { defaultDate(Date()) }
                quick(text: "+1d", help: "One day later") { shift(.day, 1) }
                quick(text: "+1w", help: "One week later") { shift(.weekOfYear, 1) }
                quick(text: "+1m", help: "One month later") { shift(.month, 1) }
                quick(icon: "xmark.square", help: "Clear") { nil }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
        .onAppear { text = display }
        .onChange(of: date) { _, _ in if !focused { text = display } }
    }

    var display: String {
        guard let date else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    func defaultDate(_ day: Date) -> Date {
        Calendar.current.date(bySettingHour: defaultHour, minute: 0, second: 0, of: day) ?? day
    }

    /// +1d etc. move an existing date, or start from today when there isn't one.
    func shift(_ c: Calendar.Component, _ n: Int) -> Date {
        Calendar.current.date(byAdding: c, value: n, to: date ?? defaultDate(Date()))!
    }

    func commitText() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t == display { return }
        if t.isEmpty { set(nil); return }
        let parser = QuickEntryParser(snapshot: model.snapshot)
        if let d = parser.date(t, hour: defaultHour) { set(d) }
        else if let d = Self.detect(t) { set(d) }
        text = display
    }

    static func detect(_ s: String) -> Date? {
        let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        return det?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))?.date
    }

    func quick(icon: String? = nil, text: String? = nil, help: String, _ value: @escaping () -> Date?) -> some View {
        Button { set(value()) } label: {
            Group {
                if let icon { Image(systemName: icon) } else { Text(text ?? "").font(.callout.weight(.medium)) }
            }
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Action / project inspector

struct TaskInspector: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let s = model.snapshot
        if let t = s.tasks[id] {
            let i = s.info[id] ?? TaskInfo()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Well {
                        CommitField(label: t.isProject ? "Project name" : "Action", value: t.title, axis: .vertical) { v in
                            model.perform("Rename") { $0.setTask(id, F.title, .string(v)) }
                        }
                        .textFieldStyle(.plain)
                        .font(.body)
                    }
                    .padding(.bottom, 8)

                    // Note sits right under the title so it's visible on every screen size; links are listed below it.
                    Well {
                        CommitField(label: "Note", value: t.note, axis: .vertical, minLines: 6) { v in
                            model.perform("Edit Note") { $0.setTask(id, F.note, .string(v)) }
                        }
                        .textFieldStyle(.plain)
                    }
                    let urls = links(t.note)
                    if !urls.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(urls, id: \.self) { url in
                                Link(destination: url) {
                                    Label(linkTitle(url), systemImage: linkIcon(url)).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        .font(.callout)
                        .padding(.top, 6)
                    }
                    Spacer().frame(height: 12)

                    if t.isProject { projectStatus(t) } else { actionStatus(t, i) }

                    if t.isProject {
                        InspectorSection(title: "Project Type", trailing: t.singleActions ? "Single Actions" : (t.sequential ? "Sequential" : "Parallel")) {
                            IconSegments(options: [(0, "circle.grid.2x2.fill", "Parallel"), (1, "arrow.down.right.circle.fill", "Sequential"), (2, "list.bullet.circle.fill", "Single actions")],
                                         selection: t.singleActions ? 2 : (t.sequential ? 1 : 0)) { v in
                                model.perform("Change Type") { tx in
                                    tx.setTask(id, F.sequential, .bool(v == 1))
                                    tx.setTask(id, F.singleActions, .bool(v == 2))
                                }
                            }
                            Toggle("Complete with last action", isOn: Binding(get: { t.completesWithChildren }, set: { v in model.perform("Change") { $0.setTask(id, F.autoComplete, .bool(v)) } }))
                                .checkboxStyle()
                        }
                        InspectorSection(title: "Folder", trailing: s.projectInfo[id]?.folderID.flatMap { s.folders[$0]?.name } ?? "None") {
                            Button("Move to Folder…") { model.moveTargetFor = [id] }.buttonStyle(.borderless)
                        }
                    } else {
                        InspectorSection(title: "Project") {
                            ProjectPickerRow(task: t)
                        }
                        if i.hasChildren {
                            InspectorSection(title: "Action Group", trailing: t.sequential ? "Sequential" : "Parallel") {
                                IconSegments(options: [(false, "circle.grid.2x2.fill", "Parallel"), (true, "arrow.down.right.circle.fill", "Sequential")],
                                             selection: t.sequential) { v in model.perform("Change Type") { $0.setTask(id, F.sequential, .bool(v)) } }
                                Toggle("Complete with last action", isOn: Binding(get: { t.completesWithChildren }, set: { v in model.perform("Change") { $0.setTask(id, F.autoComplete, .bool(v)) } }))
                                    .checkboxStyle()
                            }
                        }
                    }

                    InspectorSection(title: "Tags") {
                        Well {
                            VStack(alignment: .leading, spacing: 6) {
                                if !t.tagIDs.isEmpty {
                                    FlowTags(names: t.tagIDs.compactMap { tid in s.tags[tid].map { (tid, $0.name) } }) { tid in
                                        model.perform("Remove Tag") { $0.setTag(id, tid, false) }
                                    }
                                }
                                AutocompleteField(placeholder: "Add tag", icon: "plus",
                                                  suggestions: { Lookup.tags(model.snapshot, $0, excluding: Set(t.tagIDs)) },
                                                  createLabel: { "New tag “\($0)”" },
                                                  onPick: { tag in model.perform("Add Tag") { $0.setTag(id, tag.id, true) } },
                                                  onCreate: { name in
                                                      let tag = model.createTag(named: name)
                                                      model.perform("Add Tag") { $0.setTag(id, tag, true) }
                                                  })
                            }
                        }
                    }

                    InspectorSection(title: "Defer", trailing: inherited(t.deferDate, i.effectiveDefer)) {
                        OFDateField(date: t.deferDate, defaultHour: 0) { model.setDate([id], F.deferDate, $0) }
                    }
                    InspectorSection(title: "Planned") {
                        OFDateField(date: t.plannedDate, defaultHour: 9) { model.setDate([id], F.plannedDate, $0) }
                    }
                    InspectorSection(title: "Due", trailing: inherited(t.dueDate, i.effectiveDue)) {
                        OFDateField(date: t.dueDate, defaultHour: 17) { model.setDate([id], F.dueDate, $0) }
                    }

                    InspectorSection(title: "Repeat", trailing: t.repeatRule?.summary) {
                        RepeatEditor(rule: t.repeatRule) { r in
                            model.perform("Repeat") { $0.setTask(id, F.repeatRule, r.map { JSON(encoding: $0) } ?? .null) }
                        }
                    }

                    if !t.isProject {
                        InspectorSection(title: "Estimated Duration", trailing: t.estimatedMinutes.map(Fmt.estimate)) {
                            EstimateRow(minutes: t.estimatedMinutes) { m in model.perform("Estimate") { $0.setTask(id, F.estimate, .optional(m)) } }
                        }
                    }

                    if t.isProject { reviewSection(t) }

                    VStack(alignment: .leading, spacing: 2) {
                        if let c = t.createdAt { Text("Added \(c.formatted(date: .abbreviated, time: .shortened))") }
                        Text("Changed \(t.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                        if let c = t.completedAt { Text("Completed \(c.formatted(date: .abbreviated, time: .shortened))") }
                        if i.isBlocked { Text("Waiting on earlier actions") }
                        else if i.hasOnHoldTag { Text("On hold because of a tag") }
                        else if i.isDeferred { Text("Deferred") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .overlay(alignment: .top) { Divider() }
                }
                .padding(14)
            }
        }
    }

    func inherited(_ own: Date?, _ effective: Date?) -> String? {
        guard own == nil, let e = effective else { return nil }
        return "Inherited: " + Fmt.relative(e)
    }

    @ViewBuilder
    func projectStatus(_ t: TaskItem) -> some View {
        InspectorSection(title: "Status", trailing: t.status.label) {
            HStack(spacing: 6) {
                IconSegments(options: [(ProjectStatus.active, "play.circle", "Active"), (.onHold, "pause.circle", "On Hold"),
                                       (.done, "checkmark.circle", "Completed"), (.dropped, "minus.circle", "Dropped")],
                             selection: t.status) { v in
                    model.perform("Change Status") { tx in
                        tx.setTask(t.id, F.status, .string(v.rawValue))
                        tx.setTask(t.id, F.completed, v == .done ? .date(Date()) : .null)
                        tx.setTask(t.id, F.dropped, v == .dropped ? .date(Date()) : .null)
                    }
                }
                flagToggle(t)
            }
        }
    }

    @ViewBuilder
    func actionStatus(_ t: TaskItem, _ i: TaskInfo) -> some View {
        let state = t.droppedAt != nil ? 2 : (t.completedAt != nil ? 1 : 0)
        InspectorSection(title: "Status", trailing: state == 2 ? "Dropped" : (state == 1 ? "Completed" : (i.isAvailable ? "Available" : (i.isDeferred ? "Deferred" : (i.isBlocked ? "Blocked" : "Remaining"))))) {
            HStack(spacing: 6) {
                IconSegments(options: [(0, "circle", "Remaining"), (1, "checkmark.circle", "Completed"), (2, "minus.circle", "Dropped")],
                             selection: state) { v in
                    model.perform("Change Status") { tx in
                        switch v {
                        case 1: tx.complete(t.id)
                        case 2: tx.setTask(t.id, F.completed, .null); tx.drop(t.id)
                        default: tx.uncomplete(t.id); tx.undrop(t.id)
                        }
                    }
                }
                flagToggle(t)
            }
        }
    }

    func flagToggle(_ t: TaskItem) -> some View {
        Button { model.toggleFlag([t.id]) } label: {
            Image(systemName: t.flagged ? "flag.fill" : "flag")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(t.flagged ? Color.white : .primary)
                .frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(t.flagged ? Palette.flag : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(t.flagged ? "Unflag" : "Flag")
    }

    @ViewBuilder
    func reviewSection(_ p: TaskItem) -> some View {
        let interval = p.reviewInterval ?? .weekly
        InspectorSection(title: "Review", trailing: interval.label) {
            HStack {
                Stepper("Every \(interval.count)", value: Binding(get: { interval.count }, set: { v in
                    model.perform("Review Interval") { $0.setTask(p.id, F.reviewEvery, JSON(encoding: ReviewInterval(count: max(1, v), unit: interval.unit))) }
                }), in: 1...99)
                Picker("", selection: Binding(get: { interval.unit }, set: { u in
                    model.perform("Review Interval") { $0.setTask(p.id, F.reviewEvery, JSON(encoding: ReviewInterval(count: interval.count, unit: u))) }
                })) { ForEach(ReviewInterval.Unit.allCases, id: \.self) { Text($0.rawValue + "s").tag($0) } }
                .labelsHidden().fixedSize()
            }
            HStack {
                VStack(alignment: .leading) {
                    if let n = p.nextReviewDate { Text("Next review \(Fmt.relative(n))") }
                    if let l = p.lastReviewDate { Text("Last reviewed \(Fmt.relative(l))") }
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Mark Reviewed") {
                    model.perform("Mark Reviewed") { $0.markReviewed(p.id) }
                    model.recentlyCompleted.insert(p.id)
                }
            }
        }
    }

    func linkTitle(_ url: URL) -> String {
        if url.scheme == "message" { return "Open email in Mail" }
        if url.scheme == "scriptorium" { return "Open in Scriptorium" }
        let host = url.host() ?? url.absoluteString
        if host.contains("mimestream") { return "Open email in Mimestream" }
        if host.contains("slack.com") { return "Open Slack message" }
        return host.replacingOccurrences(of: "www.", with: "") + (url.path().count > 1 ? url.path() : "")
    }

    func linkIcon(_ url: URL) -> String {
        let h = url.host() ?? ""
        if url.scheme == "message" || h.contains("mimestream") { return "envelope" }
        if url.scheme == "scriptorium" { return "book" }
        if h.contains("slack.com") { return "bubble.left.and.bubble.right" }
        return "link"
    }

    func links(_ note: String) -> [URL] {
        Links.find(in: note).map(\.url).prefix(8).map { $0 }
    }
}

extension View {
    @ViewBuilder func checkboxStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }
}
