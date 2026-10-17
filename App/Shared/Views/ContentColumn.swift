import SwiftUI
import TaskerCore

struct ContentColumn: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var title: String {
        switch model.sidebar ?? .inbox {
        case .perspective(let id): model.snapshot.perspectives.first { $0.id == id }?.name ?? "Perspective"
        case let item: item.title
        }
    }

    var body: some View {
        @Bindable var model = model
        let sections = model.sections()
        VStack(spacing: 0) {
            #if os(iOS)
            PerspectiveStrip()
            #endif
            if model.sidebar == .forecast && model.searchText.isEmpty { ForecastStrip() }
            ScrollViewReader { proxy in
            List(selection: $model.selection) {
                if model.sidebar == .forecast && model.searchText.isEmpty {
                    let events = forecastEvents
                    if !events.isEmpty {
                        Section("Calendar") {
                            ForEach(events) { EventRow(event: $0).selectionDisabled() }
                        }
                    }
                }
                ForEach(sections) { section in
                    if section.title.isEmpty {
                        rows(section.rows)
                    } else {
                        Section(section.title) { rows(section.rows) }
                    }
                }
                if sections.allSatisfy({ $0.rows.isEmpty }) && !(model.sidebar == .forecast && !forecastEvents.isEmpty) {
                    emptyState
                }
            }
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .onDeleteCommand { model.deleteItems(Array(model.selection)) }
            // OmniFocus bare keys: Space completes, F flags.
            .onKeyPress(.space) {
                guard model.editingID == nil, !model.selection.isEmpty else { return .ignored }
                for id in model.selection { model.toggleComplete(id) }
                return .handled
            }
            .onKeyPress("f") {
                guard model.editingID == nil, !model.selection.isEmpty else { return .ignored }
                model.toggleFlag(Array(model.selection))
                return .handled
            }
            #else
            .listStyle(.plain)
            .refreshable { await model.sync?.syncNow() }
            #endif
            .contextMenu(forSelectionType: String.self) { ids in
                ItemContextMenu(ids: Array(ids))
            }
            .onChange(of: model.editingID) { _, id in
                guard let id else { return }
                // The row only exists after the list has diffed in the new snapshot.
                for delay in [0.0, 0.08, 0.25] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if model.editingID == id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            }
        }
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            Button { addAction() } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.accentColor).shadow(radius: 4, y: 2))
            }
            .accessibilityLabel("Add Action")
            .padding(.trailing, 20)
            .padding(.bottom, 72)
        }
        #endif
        .navigationTitle(title)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search everything")
        .toolbar { toolbar }
        #if DEBUG
        .task { DebugHooks.run(model) { addAction() } }
        #endif
    }

    var forecastEvents: [CalendarModel.Event] {
        let day = model.forecastDay
        if day == .distantPast { return [] }
        if day == .distantFuture {
            let cal = Calendar.current
            let start = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: Date()))!
            return CalendarModel.shared.events(from: start, to: cal.date(byAdding: .day, value: 30, to: start)!)
        }
        return CalendarModel.shared.events(on: day)
    }

    /// The toolbar "+" (and the debug hook) go through here.
    func addAction() {
        #if os(iOS)
        if sizeClass == .compact { model.presentQuickEntry(); return }
        #endif
        model.newTask()
    }

    @ViewBuilder
    func rows(_ rows: [OutlineRow]) -> some View {
        ForEach(rows) { row in
            switch row.kind {
            case .folder: FolderRow(row: row).tag(row.id)
            case .project, .task: TaskRow(row: row).tag(row.id).id(row.id)
            }
        }
    }

    @ViewBuilder
    var emptyState: some View {
        let text: String = switch model.sidebar ?? .inbox {
        case .inbox: "Inbox zero. Capture with ⌃⌥Space on the Mac or the share sheet on iPhone."
        case .review: "Nothing to review."
        case .forecast: "Nothing scheduled."
        default: model.searchText.isEmpty ? "Nothing here." : "No matches."
        }
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.sidebar == .projects || model.sidebar == .tags {
                Menu {
                    @Bindable var model = model
                    if model.sidebar == .projects {
                        Picker("Show", selection: $model.filter) { ForEach(ItemFilter.allCases) { Text($0.label).tag($0) } }
                    } else {
                        Picker("Show", selection: $model.tagFilter) { ForEach(ItemFilter.allCases) { Text($0.label).tag($0) } }
                    }
                } label: { Label("View", systemImage: "eye") }
            }
            if case .perspective(let id) = model.sidebar, let p = model.snapshot.perspectives.first(where: { $0.id == id }) {
                Button { model.editingPerspective = p } label: { Label("Edit Perspective", systemImage: "slider.horizontal.3") }
            }
            if model.sidebar == .projects {
                Menu {
                    Button("New Project") { model.newTask(isProject: true) }
                    Button("New Folder") { model.newFolder() }
                } label: { Label("New", systemImage: "folder.badge.plus") }
            }
            #if os(iOS)
            Button { model.cleanUp() } label: { Label("Clean Up", systemImage: "wand.and.sparkles") }
            Button { addAction() } label: { Label("New Action", systemImage: "plus") }
            #endif
            #if os(iOS)
            if sizeClass != .compact {
                Button { model.presentQuickEntry() } label: { Label("Quick Entry", systemImage: "square.and.pencil") }
            }
            #endif
        }
    }
}

struct ForecastStrip: View {
    @Environment(AppModel.self) private var model
    @State private var calendar = CalendarModel.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.forecastDays) { day in
                    let selected = model.forecastDay == day.id
                    Button { model.forecastDay = day.id } label: {
                        VStack(spacing: 2) {
                            Text(day.label).font(.caption.weight(.semibold))
                            Text(day.sublabel.isEmpty ? " " : day.sublabel).font(.title3.monospacedDigit())
                            HStack(spacing: 3) {
                                Text(day.count > 0 ? "\(day.count)" : " ")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(day.isPast && day.count > 0 ? Palette.overdue : .secondary)
                                if !day.isPast && day.id != .distantFuture && !CalendarModel.shared.events(on: day.id).isEmpty {
                                    Image(systemName: "calendar").font(.system(size: 8)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(width: 56, height: 64)
                        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .task {
            if calendar.enabled && calendar.status == .notDetermined { await calendar.requestAccess() }
        }
    }
}

struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let row: OutlineRow

    var body: some View {
        if let f = model.snapshot.folders[row.id] {
            HStack(spacing: 6) {
                Disclosure(row: row)
                Image(systemName: "folder.fill").foregroundStyle(f.dropped ? .secondary : Palette.folder)
                Text(f.name.isEmpty ? "Untitled folder" : f.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(f.dropped ? .secondary : .primary)
                    .strikethrough(f.dropped)
                Spacer()
            }
            .padding(.leading, CGFloat(row.depth) * 18)
        }
    }
}

struct Disclosure: View {
    @Environment(AppModel.self) private var model
    let row: OutlineRow
    var body: some View {
        Button { withAnimation(.snappy(duration: 0.15)) { model.toggleExpanded(row.id) } } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .rotationEffect(.degrees(row.expanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(row.hasChildren ? 1 : 0)
        .disabled(!row.hasChildren)
    }
}

struct ItemContextMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [String]

    var body: some View {
        let s = model.snapshot
        let tasks = ids.compactMap { s.tasks[$0] }
        if !tasks.isEmpty {
            Button(tasks.allSatisfy(\.isCompleted) ? "Mark Incomplete" : "Complete") { for id in ids { model.toggleComplete(id) } }
            Button(tasks.allSatisfy(\.flagged) ? "Unflag" : "Flag") { model.toggleFlag(ids) }
            Menu("Defer Until") {
                Button("Tomorrow") { model.setDate(ids, F.deferDate, QuickEntryParser(snapshot: s).date("tomorrow", hour: 0)) }
                Button("Next Monday") { model.setDate(ids, F.deferDate, QuickEntryParser(snapshot: s).date("mon", hour: 0)) }
                Button("Next Week (+7d)") { model.setDate(ids, F.deferDate, QuickEntryParser(snapshot: s).date("+7d", hour: 0)) }
                Button("Clear Defer Date") { model.setDate(ids, F.deferDate, nil) }
            }
            Menu("Due") {
                Button("Today") { model.setDate(ids, F.dueDate, QuickEntryParser(snapshot: s).date("today", hour: 17)) }
                Button("Tomorrow") { model.setDate(ids, F.dueDate, QuickEntryParser(snapshot: s).date("tomorrow", hour: 17)) }
                Button("Friday") { model.setDate(ids, F.dueDate, QuickEntryParser(snapshot: s).date("fri", hour: 17)) }
                Button("Clear Due Date") { model.setDate(ids, F.dueDate, nil) }
            }
            Divider()
            Button("Move To…") { model.moveTargetFor = ids }
            if tasks.allSatisfy({ !$0.isProject }) {
                Button("Indent") { model.indent(ids) }
                Button("Outdent") { model.outdent(ids) }
                if ids.count == 1 {
                    Button("Convert to Project") { model.perform("Convert to Project") { $0.convertToProject(ids[0], folder: nil) } }
                }
            }
            if tasks.allSatisfy(\.isProject) {
                Button("Mark Reviewed") { model.perform("Mark Reviewed") { tx in for id in ids { tx.markReviewed(id) } }; model.recentlyCompleted.formUnion(ids) }
            }
            Button(tasks.allSatisfy(\.isDropped) ? "Restore" : "Drop") {
                let restore = tasks.allSatisfy(\.isDropped)
                model.perform(restore ? "Restore" : "Drop") { tx in for id in ids { restore ? tx.undrop(id) : tx.drop(id) } }
            }
        }
        if ids.contains(where: { s.folders[$0] != nil }) {
            Button("Move To…") { model.moveTargetFor = ids }
        }
        Divider()
        Button("Delete", role: .destructive) { model.deleteItems(ids) }
    }
}
