import SwiftUI
import TaskerCore

/// Kanban board: one column per stage (defined in Edit Stages…), cards are actions. Drag a card to
/// another column or between cards; "Up next" offers flagged available actions that aren't on the board.
struct KanbanView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("kanban.showUpNext") private var showUpNext = true
    @State private var editingStages = false

    var body: some View {
        let s = model.snapshot
        let since = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Board").font(.largeTitle.bold()).foregroundStyle(Color.indigo)
                Text("\(s.stages.reduce(0) { $0 + s.cards(in: $1, completedSince: since).count }) cards")
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Up next", isOn: $showUpNext).toggleStyle(.switch).controlSize(.small)
                    .help("Show flagged available actions that aren't on the board yet")
                Button { editingStages = true } label: { Label("Edit Stages…", systemImage: "slider.horizontal.3") }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    if showUpNext {
                        KanbanColumn(stage: nil, title: "Up next", subtitle: "Flagged, not on the board", color: .orange,
                                     cards: upNext(s))
                    }
                    ForEach(s.stages) { st in
                        KanbanColumn(stage: st, title: st.name, subtitle: st.completes ? "Completes the action" : nil,
                                     color: KanbanView.color(st.color), cards: s.cards(in: st, completedSince: since))
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .navigationTitle("Board")
        .onAppear {
            if !model.snapshot.hasStages { model.perform("Set Up Board") { $0.addDefaultStages() } }
        }
        .sheet(isPresented: $editingStages) { StageEditor().environment(model) }
    }

    func upNext(_ s: Snapshot) -> [TaskItem] {
        let onBoard = Set(s.stages.map(\.id))
        return s.tasks.values.filter { t in
            !t.isProject && !(t.stageID.map(onBoard.contains) ?? false)
                && s.info[t.id]?.isAvailable == true && s.info[t.id]?.effectiveFlagged == true
        }
        .sorted { ($0.dueDate ?? .distantFuture, $0.title) < ($1.dueDate ?? .distantFuture, $1.title) }
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "gray": .gray; case "orange": .orange; case "purple": .purple; case "green": .green
        case "red": .red; case "teal": .teal; case "yellow": .yellow; case "pink": .pink
        default: .blue
        }
    }
    static let colorNames = ["gray", "blue", "teal", "green", "yellow", "orange", "red", "pink", "purple"]
}

private struct KanbanColumn: View {
    @Environment(AppModel.self) private var model
    let stage: KanbanStage?
    let title: String
    let subtitle: String?
    let color: Color
    let cards: [TaskItem]
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(title).font(.headline)
                Text("\(cards.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards) { t in
                        KanbanCard(task: t, stage: stage)
                            // A static preview: a full card here would create a second (focus-stealing) title editor.
                            .draggable(t.id) {
                                Text(t.title.isEmpty ? "Untitled" : t.title).lineLimit(3).padding(10).frame(width: 250, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(.background))
                            }
                            .dropDestination(for: String.self) { ids, _ in
                                drop(ids, before: t.id)
                            }
                    }
                    if cards.isEmpty {
                        Text(stage == nil ? "Nothing flagged and available." : "Drop cards here")
                            .font(.callout).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .padding(10)
        .frame(width: 270)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(targeted ? 0.16 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(targeted ? 0.6 : 0), lineWidth: 2))
        .dropDestination(for: String.self) { ids, _ in drop(ids, before: nil) } isTargeted: { targeted = $0 }
    }

    /// Up next = off the board.
    func drop(_ ids: [String], before: String?) -> Bool {
        let ids = ids.filter { $0 != before }
        guard !ids.isEmpty else { return false }
        model.moveToStage(ids, stage: stage?.id, before: before)
        return true
    }
}

private struct KanbanCard: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    let stage: KanbanStage?

    var body: some View {
        let s = model.snapshot
        let i = s.info[task.id]
        let selected = model.selection.contains(task.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button { model.toggleComplete(task.id) } label: {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isCompleted ? Color.secondary : (i?.effectiveFlagged == true ? Palette.flag : Color.secondary))
                }
                .buttonStyle(.plain)
                Group {
                    if model.editingID == task.id {
                        InlineTitleEditor(task: task, continueOnReturn: false)
                    } else {
                        Text(task.title.isEmpty ? "Untitled" : task.title)
                            .strikethrough(task.isCompleted, color: .secondary)
                            .foregroundStyle(task.isCompleted ? .secondary : .primary)
                            .lineLimit(4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if i?.effectiveFlagged == true { Image(systemName: "flag.fill").foregroundStyle(Palette.flag).imageScale(.small) }
            }
            let tags = task.tagIDs.compactMap { s.tags[$0]?.name }
            if selected && model.selection.count == 1, let i {
                // Same editing as a selected row in the lists: Project, Tags, Defer, Due, note.
                SelectedFieldsLine(task: task, info: i, wrap: true)
                InlineNote(task: task)
            } else if i?.projectID != nil || !tags.isEmpty || task.dueDate != nil {
                FlowRow {
                    if let p = i?.projectID, let pt = s.tasks[p] { Badge(text: pt.title, systemImage: "circle.grid.2x2", color: Palette.project) }
                    ForEach(tags, id: \.self) { Badge(text: $0, color: Palette.tag) }
                    PomodoroBadge(task: task)
                    if let d = task.dueDate {
                        Badge(text: Fmt.relative(d), systemImage: "calendar", color: d < s.now ? Palette.overdue : (d < s.dueSoon ? Palette.dueSoon : .secondary),
                              filled: d < s.dueSoon)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .contentShape(Rectangle())
        // Like the lists: click selects (and opens the fields), double-click edits the title.
        .onTapGesture(count: 2) { model.beginEditing(task.id) }
        .simultaneousGesture(TapGesture().onEnded { if model.selection != [task.id] { model.inlineField = nil; model.selection = [task.id] } })
        .contextMenu {
            StageMenu(ids: [task.id])
            Divider()
            ItemContextMenu(ids: [task.id])
        }
    }
}

/// "Board ▸" menu: move to a stage or take off the board. Used on cards and in every list's context menu.
struct StageMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [String]
    var body: some View {
        let s = model.snapshot
        let current = Set(ids.compactMap { s.tasks[$0]?.stageID })
        Menu("Board") {
            ForEach(s.stages) { st in
                Button { model.moveToStage(ids, stage: st.id, before: nil) } label: {
                    if current == [st.id] { Label(st.name, systemImage: "checkmark") } else { Text(st.name) }
                }
            }
            if !current.isEmpty {
                Divider()
                Button("Remove from Board") { model.moveToStage(ids, stage: nil, before: nil) }
            }
            if s.stages.isEmpty {
                Button("Set Up Board") { model.perform("Set Up Board") { $0.addDefaultStages() } }
            }
        }
    }
}

/// Add, rename, recolour, reorder and delete stages.
struct StageEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let stages = model.snapshot.stages
        VStack(alignment: .leading, spacing: 12) {
            Text("Board Stages").font(.title2.bold())
            Text("Columns of the board, left to right. Drag to reorder. Moving a card into a stage marked “Completes” completes the action; moving it out reopens it.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(stages) { st in StageRow(stage: st) }
                    .onMove { from, to in model.reorderStages(from: from, to: to) }
            }
            .frame(minHeight: 240)
            HStack {
                Button { model.addStage() } label: { Label("Add Stage", systemImage: "plus") }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }
}

private struct StageRow: View {
    @Environment(AppModel.self) private var model
    let stage: KanbanStage
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(KanbanView.colorNames, id: \.self) { c in
                    Button(c.capitalized) { var s = stage; s.color = c; model.saveStage(s) }
                }
            } label: { Circle().fill(KanbanView.color(stage.color)).frame(width: 14, height: 14) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            TextField("Stage name", text: $name)
                .textFieldStyle(.plain)
                .onSubmit { commit() }
                .onAppear { name = stage.name }
                .onChange(of: stage.name) { _, n in name = n }
            Toggle("Completes", isOn: Binding(get: { stage.completes }, set: { var s = stage; s.completes = $0; model.saveStage(s) }))
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
            Button(role: .destructive) { model.perform("Delete Stage") { $0.deleteStage(stage.id) } } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete stage (its cards go off the board)")
        }
        .onDisappear { commit() }
    }

    func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != stage.name else { return }
        var s = stage; s.name = n; model.saveStage(s)
    }
}
