import SwiftUI
import TaskerCore

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let row: OutlineRow

    var body: some View {
        let s = model.snapshot
        if let t = s.tasks[row.id] {
            let i = s.info[row.id] ?? TaskInfo()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if row.depth > 0 || row.hasChildren || row.kind == .project || !row.showContext {
                    Disclosure(row: row).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                if t.isProject {
                    ProjectIcon(project: t)
                } else {
                    CheckCircle(task: t, info: i) { model.toggleComplete(t.id) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    if model.editingID == t.id {
                        InlineTitleEditor(task: t)
                    } else {
                        Text(t.title.isEmpty ? (t.isProject ? "Untitled project" : "Untitled") : t.title)
                            .font(t.isProject ? .body.weight(.semibold) : .body)
                            .foregroundStyle(titleColor(t, i))
                            .strikethrough(t.isCompleted || t.isDropped, color: .secondary)
                            .lineLimit(3)
                            #if os(macOS)
                            .onTapGesture(count: 2) { model.selection = [t.id]; model.editingID = t.id }
                            #endif
                    }
                    MetadataLine(task: t, info: i, showContext: row.showContext, showProject: row.showProject,
                                 selected: model.selection.contains(t.id) && model.selection.count == 1)
                }
                Spacer(minLength: 0)
                if t.isProject, let pi = s.projectInfo[t.id], pi.remainingCount > 0 {
                    Text("\(pi.availableCount)/\(pi.remainingCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !t.isProject { FlagButton(task: t, effective: i.effectiveFlagged) }
            }
            .padding(.leading, CGFloat(row.depth) * 18)
            .padding(.vertical, 2)
            .opacity(i.isAvailable || t.isCompleted || model.recentlyCompleted.contains(t.id) || t.isProject ? 1 : 0.55)
            #if os(iOS)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !t.isProject {
                    Button { model.toggleComplete(t.id) } label: { Label("Complete", systemImage: "checkmark") }.tint(.green)
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { model.deleteItems([t.id]) } label: { Label("Delete", systemImage: "trash") }
                Button { model.toggleFlag([t.id]) } label: { Label("Flag", systemImage: "flag") }.tint(.orange)
                Button { model.moveTargetFor = [t.id] } label: { Label("Move", systemImage: "folder") }.tint(.indigo)
            }
            #endif
        }
    }

    func titleColor(_ t: TaskItem, _ i: TaskInfo) -> Color {
        if t.isCompleted || t.isDropped { return .secondary }
        return .primary
    }
}

struct CheckCircle: View {
    let task: TaskItem
    let info: TaskInfo
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(strokeColor, style: StrokeStyle(lineWidth: 1.5, dash: task.repeatRule != nil ? [3, 2] : []))
                    .background(Circle().fill(task.isCompleted ? Color.secondary.opacity(0.25) : .clear))
                if task.isCompleted {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                } else if info.effectiveFlagged {
                    Circle().fill(Palette.flag).frame(width: 6, height: 6)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .help(task.repeatRule != nil ? "Complete this occurrence" : "Complete")
    }

    var strokeColor: Color {
        if task.isCompleted { return .secondary }
        if let d = info.effectiveDue, d < Date() { return Palette.overdue }
        if info.effectiveFlagged { return Palette.flag }
        return .secondary
    }
}

struct MetadataLine: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    let info: TaskInfo
    let showContext: Bool
    var showProject = true
    var selected = false

    var body: some View {
        let s = model.snapshot
        let parts = items(s)
        if !parts.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { ForEach(parts.indices, id: \.self) { parts[$0] } }
                HStack(spacing: 4) { ForEach(parts.prefix(3).indices, id: \.self) { parts[$0] } }
                HStack(spacing: 4) { ForEach(parts.prefix(1).indices, id: \.self) { parts[$0] } }
            }
        }
    }

    func items(_ s: Snapshot) -> [AnyView] {
        var out: [AnyView] = []
        if !task.isProject {
            // Editable in place: click the project or a tag to change it.
            if showContext && showProject {
                out.append(AnyView(ProjectChip(task: task)))
            } else if selected && info.projectID == nil {
                out.append(AnyView(ProjectChip(task: task, placeholder: true)))
            }
        }
        if let due = info.effectiveDue, !task.isCompleted {
            let overdue = due < s.now
            let soon = due < s.dueSoon
            out.append(AnyView(Badge(text: Fmt.relative(due, now: s.now), systemImage: "calendar",
                                     color: overdue ? Palette.overdue : (soon ? Palette.dueSoon : .secondary), filled: overdue || soon)))
        }
        if let d = task.deferDate, d > s.now, !task.isCompleted {
            out.append(AnyView(Badge(text: Fmt.relative(d, now: s.now), systemImage: "moon.zzz", color: Palette.deferred)))
        }
        if let d = task.plannedDate, !task.isCompleted {
            out.append(AnyView(Badge(text: Fmt.relative(d, now: s.now), systemImage: "calendar.badge.clock", color: .blue)))
        }
        if let c = task.completedAt, task.isCompleted {
            out.append(AnyView(Badge(text: Fmt.relative(c, now: s.now), systemImage: "checkmark")))
        }
        if !task.isProject && (!task.tagIDs.isEmpty || selected) {
            out.append(AnyView(TagChips(task: task, showAdd: selected)))
        } else if task.isProject {
            for name in s.tagNames(task.tagIDs) { out.append(AnyView(Badge(text: name, color: Palette.tag))) }
        }
        if task.repeatRule != nil { out.append(AnyView(Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary))) }
        if let e = task.estimatedMinutes { out.append(AnyView(Badge(text: Fmt.estimate(e), systemImage: "clock"))) }
        if !task.note.isEmpty { out.append(AnyView(Image(systemName: "note.text").font(.caption).foregroundStyle(.secondary))) }
        if info.isBlocked && !task.isCompleted { out.append(AnyView(Image(systemName: "hourglass").font(.caption).foregroundStyle(.secondary))) }
        if task.isProject, task.status == .onHold { out.append(AnyView(Badge(text: "On hold", systemImage: "pause"))) }
        if task.isProject, let pi = s.projectInfo[task.id], pi.isStalled { out.append(AnyView(Badge(text: "Stalled", color: .orange))) }
        if task.isProject, model.sidebar == .review, let next = task.nextReviewDate {
            out.append(AnyView(Badge(text: "Review \(Fmt.relative(next, now: s.now))", systemImage: "cup.and.saucer")))
        }
        return out
    }
}

/// Title field shown while a row is being edited inline.
struct InlineTitleEditor: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    @State private var text = ""
    @State private var hadFocus = false
    @FocusState private var focused: Bool

    private var placeholder: String { task.isProject ? "Project name" : "New action  (#tag ::project ! due:fri)" }

    var body: some View {
        #if os(macOS)
        InlineTextField(text: $text, placeholder: placeholder, bold: task.isProject,
                        onSubmit: { model.commitInline(task.id, title: text, continueWithNew: !text.trimmingCharacters(in: .whitespaces).isEmpty) },
                        onCancel: { model.commitInline(task.id, title: text, continueWithNew: false) },
                        onEndEditing: { if model.editingID == task.id { model.commitInline(task.id, title: text, continueWithNew: false) } })
            .onAppear { text = task.title }
        #else
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear {
                text = task.title
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit { model.commitInline(task.id, title: text, continueWithNew: !text.trimmingCharacters(in: .whitespaces).isEmpty) }
            .onChange(of: focused) { _, isFocused in
                if isFocused { hadFocus = true }
                if !isFocused && hadFocus && model.editingID == task.id { model.commitInline(task.id, title: text, continueWithNew: false) }
            }
        #endif
    }
}
