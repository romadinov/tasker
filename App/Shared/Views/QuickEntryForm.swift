import SwiftUI
import TaskerCore

/// Quick Entry: one item laid out like a list row
/// (circle · "Untitled Item" · Project / Tags / Due / Repeat · Add Note), with Cancel / Save below.
struct QuickEntryForm: View {
    @Environment(AppModel.self) private var model
    let capture: AppModel.Capture
    let onDone: () -> Void

    enum Focus: Hashable { case title, note }
    enum Field: Hashable { case project, tags }

    @State private var title = ""
    @State private var note = ""
    @State private var projectID: String?
    @State private var tagIDs: [String] = []
    @State private var flagged = false
    @State private var due: Date?
    @State private var deferDate: Date?
    @State private var planned: Date?
    @State private var estimate: Int?
    @State private var repeatRule: RepeatRule?
    @State private var showNote = false
    @State private var showMore = false
    @State private var editing: Field?
    @State private var dueOpen = false
    @State private var repeatOpen = false
    @State private var savedCount = 0
    @FocusState private var focus: Focus?

    var body: some View {
        let s = model.snapshot
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Untitled Item", text: $title, prompt: Text("Untitled Item"), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1...4)
                        .focused($focus, equals: .title)
                        .onSubmit { save(keepOpen: false) }
                    fieldsRow(s)
                    if showMore { moreRow(s) }
                    if showNote || !note.isEmpty {
                        TextField("Note", text: $note, prompt: Text("Note"), axis: .vertical)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2...10)
                            .focused($focus, equals: .note)
                    } else {
                        Button { showNote = true; DispatchQueue.main.async { focus = .note } } label: {
                            Text("Add Note").font(.callout).foregroundStyle(.secondary.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Button { showNote = true; DispatchQueue.main.async { focus = .note } } label: {
                        Image(systemName: "note.text").foregroundStyle(note.isEmpty ? Color.secondary.opacity(0.6) : Color.secondary)
                    }
                    .buttonStyle(.plain).help("Note")
                    Button { flagged.toggle() } label: {
                        Image(systemName: flagged ? "flag.fill" : "flag").foregroundStyle(flagged ? Palette.flag : Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain).help("Flag")
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: 3).padding(.vertical, 10)
            }

            Divider()
            HStack {
                Button { withAnimation(.snappy(duration: 0.15)) { showMore.toggle() } } label: {
                    Image(systemName: showMore ? "eye.fill" : "eye").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showMore ? "Hide more fields" : "Show Defer, Planned and Estimate")
                if savedCount > 0 { Text("Saved \(savedCount)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("Save") { save(keepOpen: false) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                // ⇧⌘↩ saves and starts the next item.
                Button("") { save(keepOpen: true) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .frame(width: 0, height: 0).opacity(0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear {
            title = capture.title
            note = capture.note
            showNote = !capture.note.isEmpty
            projectID = capture.projectID
            tagIDs = capture.tagIDs
            flagged = capture.flagged || model.sidebar == .flagged
            due = capture.dueDate
            DispatchQueue.main.async { focus = .title }
        }
        #if os(iOS)
        .navigationTitle("New Action")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Fields

    @ViewBuilder
    func fieldsRow(_ s: Snapshot) -> some View {
        HStack(spacing: 10) {
            // Project
            if editing == .project {
                comboField(kind: .project, placeholder: "Project") { item, viaTab in
                    if let item {
                        projectID = item.createName.map { model.createProject(named: $0) } ?? item.id
                    }
                    editing = .tags
                    return false
                }
                .frame(width: 220)
            } else {
                fieldButton(icon: "circle.grid.2x2", text: projectID.flatMap { s.tasks[$0]?.title } ?? "Project",
                            set: projectID != nil, tint: Palette.project) { editing = .project }
            }
            // Tags
            if editing == .tags {
                ForEach(tagIDs, id: \.self) { id in Badge(text: s.tags[id]?.name ?? "", color: Palette.tag) }
                comboField(kind: .tag, placeholder: "Add tag") { item, viaTab in
                    if let item {
                        let id = item.createName.map { model.createTag(named: $0) } ?? item.id
                        if !tagIDs.contains(id) { tagIDs.append(id) }
                    }
                    if viaTab || item == nil { editing = nil; focus = .title; return false }
                    return true
                }
                .frame(width: 160)
            } else {
                fieldButton(icon: "tag", text: tagIDs.isEmpty ? "Tags" : s.tagNames(tagIDs).joined(separator: ", "),
                            set: !tagIDs.isEmpty, tint: Palette.tag) { editing = .tags }
            }
            // Due
            fieldButton(icon: "calendar", text: due.map { Fmt.relative($0) } ?? "Due", set: due != nil,
                        tint: due.map { $0 < Date() ? Palette.overdue : Palette.dueSoon } ?? .secondary) { dueOpen = true }
                .popover(isPresented: $dueOpen, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Due").font(.headline)
                        OFDateField(date: due, defaultHour: 17) { due = $0 }
                    }
                    .padding(12).frame(width: 300)
                }
            // Repeat
            fieldButton(icon: "repeat", text: repeatRule?.summary ?? "Repeat", set: repeatRule != nil, tint: .secondary) { repeatOpen = true }
                .popover(isPresented: $repeatOpen, arrowEdge: .bottom) {
                    Form { RepeatEditor(rule: repeatRule) { repeatRule = $0 } }
                        .formStyle(.grouped)
                        .frame(width: 340, height: 280)
                }
        }
        .font(.callout)
    }

    @ViewBuilder
    func moreRow(_ s: Snapshot) -> some View {
        HStack(spacing: 10) {
            DateFieldButton(label: "Defer", icon: "arrow.turn.up.right", date: $deferDate, hour: 0)
            DateFieldButton(label: "Planned", icon: "calendar.badge.clock", date: $planned, hour: 9)
            Menu {
                ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { m in Button(Fmt.estimate(m)) { estimate = m } }
                Divider()
                Button("None") { estimate = nil }
            } label: {
                Label(estimate.map(Fmt.estimate) ?? "Estimate", systemImage: "clock")
                    .foregroundStyle(estimate == nil ? Color.secondary.opacity(0.75) : .primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.callout)
    }

    func fieldButton(icon: String, text: String, set: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).imageScale(.small)
                Text(text).lineLimit(1)
            }
            .foregroundStyle(set ? tint : Color.secondary.opacity(0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func comboField(kind: ComboKind, placeholder: String, onCommit: @escaping (ComboItem?, Bool) -> Bool) -> some View {
        #if os(macOS)
        QuickComboField(kind: kind, placeholder: placeholder, excluded: Set(tagIDs), onCommit: onCommit, onCancel: { editing = nil })
        #else
        AutocompleteField(placeholder: placeholder, icon: kind == .project ? "circle.grid.2x2" : "tag",
                          suggestions: { kind == .project ? Lookup.projects(model.snapshot, $0) : Lookup.tags(model.snapshot, $0, excluding: Set(tagIDs)) },
                          createLabel: kind == .project ? Lookup.newProjectLabel : { "New tag “\($0)”" },
                          onPick: { s in _ = onCommit(ComboItem(id: s.id, folder: "", title: s.title, onHold: false), false) },
                          onCreate: { name in _ = onCommit(ComboItem(id: "#new", folder: "", title: name, onHold: false, createName: name), false) },
                          showAllWhenEmpty: true)
        #endif
    }

    // MARK: Save

    func save(keepOpen: Bool) {
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty || !note.isEmpty else { if !keepOpen { onDone() }; return }
        let id = model.quickAdd(title: raw.isEmpty ? "Untitled Item" : raw, note: note, projectID: projectID, tagIDs: tagIDs,
                                flagged: flagged, deferDate: deferDate, dueDate: due)
        if let id {
            model.perform("Quick Entry details") { tx in
                if let planned { tx.setTask(id, F.plannedDate, .date(planned)) }
                if let estimate { tx.setTask(id, F.estimate, .optional(estimate)) }
                if let repeatRule { tx.setTask(id, F.repeatRule, JSON(encoding: repeatRule)) }
            }
        }
        savedCount += 1
        if keepOpen {
            title = ""; note = ""; showNote = false; flagged = false; due = nil; deferDate = nil; planned = nil
            estimate = nil; repeatRule = nil
            focus = .title
        } else {
            onDone()
        }
    }
}

/// Date field with a popover (Defer / Planned in Quick Entry's extra row).
struct DateFieldButton: View {
    let label: String
    let icon: String
    @Binding var date: Date?
    let hour: Int
    @State private var open = false
    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).imageScale(.small)
                Text(date.map { Fmt.relative($0) } ?? label)
            }
            .foregroundStyle(date == nil ? Color.secondary.opacity(0.75) : .primary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.headline)
                OFDateField(date: date, defaultHour: hour) { date = $0 }
            }
            .padding(12).frame(width: 300)
        }
    }
}

#if os(macOS)
/// Project/tag type-ahead for Quick Entry (not tied to an existing task).
struct QuickComboField: View {
    let kind: ComboKind
    let placeholder: String
    let excluded: Set<String>
    let onCommit: (ComboItem?, Bool) -> Bool
    let onCancel: () -> Void
    @State private var state: ComboState

    init(kind: ComboKind, placeholder: String, excluded: Set<String>, onCommit: @escaping (ComboItem?, Bool) -> Bool, onCancel: @escaping () -> Void) {
        self.kind = kind; self.placeholder = placeholder; self.excluded = excluded; self.onCommit = onCommit; self.onCancel = onCancel
        let s = ComboState(kind: kind) { AppModel.shared.snapshot }
        s.excluded = excluded
        s.refresh()
        _state = State(initialValue: s)
    }

    var body: some View {
        ComboTextField(state: state, placeholder: placeholder, onCommit: { item, tab in
            let keep = onCommit(item, tab)
            if keep, let item { state.excluded.insert(item.id) ; state.refresh() }
            return keep
        }, onCancel: onCancel)
    }
}
#endif
