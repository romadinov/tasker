import SwiftUI
import TaskerCore
#if os(macOS)
import AppKit
#endif

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
        // The running pomodoro sits above every view.
        mainBody.safeAreaInset(edge: .top, spacing: 0) { PomodoroBar() }
    }

    @ViewBuilder var mainBody: some View {
        if model.sidebar == .kanban && model.searchText.isEmpty {
            KanbanView()
                .searchable(text: Bindable(model).searchText, placement: .toolbar, prompt: "Search everything")
                #if os(iOS)
                .toolbar { if !isCompactWidth { MainToolbar(model: model) } }
                #endif
        } else if model.sidebar == .analytics && model.searchText.isEmpty {
            AnalyticsView()
                .searchable(text: Bindable(model).searchText, placement: .toolbar, prompt: "Search everything")
                #if os(iOS)
                .toolbar { if !isCompactWidth { MainToolbar(model: model) } }
                #endif
        } else if model.sidebar == .nearby && model.searchText.isEmpty {
            NearbyView()
                .searchable(text: Bindable(model).searchText, placement: .toolbar, prompt: "Search everything")
                #if os(iOS)
                .toolbar { if !isCompactWidth { MainToolbar(model: model) } }
                #endif
        } else {
            listBody
        }
    }

    @ViewBuilder var listBody: some View {
        @Bindable var model = model
        let sections = model.sections()
        VStack(spacing: 0) {
            if model.syncStatus.initialSync { FirstSyncBanner() }
            #if os(iOS)
            if sizeClass == .compact { PerspectiveStrip() }
            if model.sidebar == .forecast && model.searchText.isEmpty && sizeClass == .compact { ForecastStrip() }
            #endif
            ScrollViewReader { proxy in
            List(selection: $model.selection) {
                if !isCompactWidth {
                    PerspectiveHeader(sections: sections)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                }
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
            // Bare keys: Space completes, F flags.
            .onKeyPress(.space) {
                guard !typingInField, !model.selection.isEmpty else { return .ignored }
                for id in model.selection { model.toggleComplete(id) }
                return .handled
            }
            // Return on a selected row: new item right below it, in edit mode (double-click edits the title).
            .onKeyPress(.return) {
                guard !typingInField, model.selection.count == 1, let id = model.selection.first else { return .ignored }
                if model.snapshot.folders[id] != nil { model.newTask(isProject: true) }
                else { model.newTask() } // after an action; at the top of a selected project
                return .handled
            }
            .onKeyPress("f") {
                guard !typingInField, !model.selection.isEmpty else { return .ignored }
                model.toggleFlag(Array(model.selection))
                return .handled
            }
            #else
            .listStyle(.plain)
            .refreshable { await model.sync?.syncNow() }
            #endif
            #if os(macOS)
            // Double-click a row (anywhere, at once) edits its name.
            .contextMenu(forSelectionType: String.self) { ids in
                ItemContextMenu(ids: Array(ids))
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first { model.beginEditing(id) }
            }
            #else
            .contextMenu(forSelectionType: String.self) { ids in
                ItemContextMenu(ids: Array(ids))
            }
            #endif
            #if os(macOS)
            .onChange(of: model.selection) { old, new in
                let canScroll = ClickAnchor.keepClickedRowInPlace()
                // Synchronously, so a row kept open never closes for a frame first.
                model.selectionMoved(from: old, to: new, canCompensate: canScroll)
            }
            #endif
            .onChange(of: model.scrollToRow) { _, id in
                // Only when moving to the next item (Return after tags): scroll just enough to show it.
                guard let id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo(id)
                    model.scrollToRow = nil
                }
            }
            .onChange(of: model.editingID) { _, id in
                // Only new rows need bringing into view; renaming an existing row must not scroll it.
                guard let id, model.snapshot.tasks[id]?.title.isEmpty == true else { return }
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(isCompactWidth ? .automatic : .inline)
        .toolbar { if !isCompactWidth { MainToolbar(model: model) } }
        #endif
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search everything")
        #if os(iOS)
        .toolbar { toolbar }
        #endif
        #if DEBUG
        .task { DebugHooks.run(model) { addAction() } }
        #endif
    }

    var isCompactWidth: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
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

    #if os(macOS)
    /// Space/F are list shortcuts only when no text is being typed (title, Project/Tags fields, rename, note).
    private var typingInField: Bool {
        if model.editingID != nil || model.inlineField != nil || model.renamingID != nil || model.noteEditingID != nil { return true }
        return NSApp.keyWindow?.firstResponder is NSText
    }
    #endif

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
        // Drag to reorder where the list shows the outline order (Inbox, Projects).
        .onMove(perform: model.canReorder ? { from, to in model.moveRows(from, to: to, in: rows) } : nil)
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
            if (model.sidebar == .projects && isCompactWidth) || model.sidebar == .tags {
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
            if model.sidebar == .projects && isCompactWidth {
                Menu {
                    Button("New Project") { model.newTask(isProject: true) }
                    Button("New Folder") { model.newFolder() }
                } label: { Label("New", systemImage: "folder.badge.plus") }
            }
            #if os(iOS)
            if sizeClass == .compact {
                Button { model.cleanUp() } label: { Label("Clean Up", systemImage: "wand.and.sparkles") }
                Button { addAction() } label: { Label("New Action", systemImage: "plus") }
            }
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
                RenamableName(id: f.id, name: f.name, placeholder: "Untitled folder", bold: true,
                              color: f.dropped ? .secondary : .primary, strikethrough: f.dropped, doubleClick: false)
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
            if tasks.allSatisfy({ !$0.isProject }) { StageMenu(ids: ids) }
            if ids.count == 1, let t = tasks.first, !t.isProject, !t.isCompleted {
                Button { PomodoroTimer.shared.start(t.id) } label: { Label("Start Pomodoro", systemImage: "timer") }
                    .keyboardShortcut("p", modifiers: [.command, .control]) // shows ⌃⌘P in the menu
            }
            Menu("Organize") { OrganizeMenuItems(ids: ids) }
            if tasks.allSatisfy({ !$0.isProject }) {
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
            if ids.count == 1 { Button("Rename") { model.renamingID = ids[0] } }
            if tasks.isEmpty { Menu("Organize") { OrganizeMenuItems(ids: ids) } }
        }
        Divider()
        Button("Delete", role: .destructive) { model.deleteItems(ids) }
    }
}

/// Big title with a count, at the top of the main list.
struct PerspectiveHeader: View {
    @Environment(AppModel.self) private var model
    let sections: [OutlineSection]

    var body: some View {
        let item = model.sidebar ?? .inbox
        let rows = sections.flatMap(\.rows)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(item))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(item.tint.gradient)
                Spacer()
                if item == .review && model.searchText.isEmpty && !model.reviewProjects.isEmpty {
                    Button { model.reviewStep(-1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).help("Previous project")
                    Button { model.reviewStep(1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).help("Next project")
                    Button("Mark Reviewed") { model.markReviewedAndAdvance() }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .disabled(model.projectFocus.first.flatMap { model.snapshot.tasks[$0] }?.isProject != true)
                }
            }
            if !model.focusIDs.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                    Text("Focused on " + model.focusIDs.compactMap { model.snapshot.tasks[$0]?.title ?? model.snapshot.folders[$0]?.name }.sorted().joined(separator: ", "))
                        .lineLimit(1)
                    Button { model.focusIDs = [] } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            if item == .forecast && model.searchText.isEmpty {
                ForecastHeaderStrip()
            } else {
                Text(subtitle(item, rows)).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6).padding(.bottom, 4)
    }

    func title(_ item: SidebarItem) -> String {
        if !model.searchText.isEmpty { return "Search" }
        switch item {
        case .perspective(let id): return model.snapshot.perspectives.first { $0.id == id }?.name ?? "Perspective"
        case .forecast: return "Forecast"
        default: return item.title
        }
    }

    func subtitle(_ item: SidebarItem, _ rows: [OutlineRow]) -> String {
        let s = model.snapshot
        let projects = rows.filter { $0.kind == .project }.count
        let actions = rows.filter { $0.kind == .task }.count
        if item == .review, let id = model.projectFocus.first, let p = s.tasks[id] {
            let list = model.reviewProjects
            let i = (list.firstIndex { $0.id == id } ?? 0) + 1
            var parts = ["Project \(i) of \(list.count)", (p.reviewInterval ?? .weekly).label.replacingOccurrences(of: "Every", with: "Review every")]
            if let l = p.lastReviewDate { parts.append("Last reviewed \(l.formatted(date: .numeric, time: .omitted))") }
            return parts.joined(separator: " • ")
        }
        if !model.projectFocus.isEmpty && (item == .projects || item == .review) {
            let n = model.projectFocus.count
            return n == 1 ? (s.tasks[model.projectFocus.first!]?.title ?? s.folders[model.projectFocus.first!]?.name ?? "1 selected") : "\(n) selected"
        }
        var parts: [String] = []
        if projects > 0 { parts.append(projects == 1 ? "1 project" : "\(projects) projects") }
        if actions > 0 || parts.isEmpty { parts.append(actions == 1 ? "1 action" : "\(actions) actions") }
        return parts.joined(separator: ", ")
    }
}

/// Day strip under the Forecast title (Past, Today, the next 11 days, Future).
struct ForecastHeaderStrip: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.forecastDays) { day in
                    let selected = model.forecastDay == day.id
                    Button { model.forecastDay = day.id } label: {
                        VStack(spacing: 3) {
                            Text(day.label).font(.caption.weight(selected ? .bold : .medium))
                            Text("\(day.count)").font(.title3.monospacedDigit())
                                .foregroundStyle(day.count == 0 ? Color.secondary.opacity(0.4) : .primary)
                            Capsule().fill(day.isPast && day.count > 0 ? Palette.overdue : (selected ? Color.accentColor : .clear))
                                .frame(width: 12, height: 4)
                        }
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(minWidth: 64)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 6)
    }
}

/// Shown on a new device while the first download from iCloud runs.
struct FirstSyncBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let s = model.syncStatus
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Downloading your tasks from iCloud…").font(.callout.weight(.semibold))
                Text(s.received > 0
                     ? "\(s.received.formatted()) changes received. The first sync can take a minute; you can keep using the app."
                     : "Connecting. The first sync can take a minute; you can keep using the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
