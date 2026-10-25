import SwiftUI
import TaskerCore

extension SidebarItem {
    /// Colours for the perspective rail.
    var tint: Color {
        switch self {
        case .inbox: .blue; case .projects: .indigo; case .tags: .purple
        case .forecast: .red; case .flagged: .orange; case .review: .purple; case .nearby: .green; case .analytics: .teal; case .kanban: .indigo
        case .perspective: .teal
        }
    }

    /// Perspectives whose sidebar has its own content (outline, days, review list).
    var hasSidebarContent: Bool {
        switch self { case .projects, .tags, .forecast, .review: true; default: false }
    }
}

/// Vertical perspective rail at the window's leading edge (Mac and iPad).
struct PerspectiveRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(model.barItems) { bar in RailButton(bar: bar) }
                    Button {
                        var p = Perspective(id: IDs.make())
                        p.name = "New Perspective"
                        p.rules = [.object(["actionAvailability": "available"])]
                        model.editingPerspective = p
                    } label: {
                        Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 60, height: 32)
                    }
                    .buttonStyle(.plain)
                    .help("New Perspective")
                }
                .padding(.vertical, 8)
            }
            Divider()
            Button { model.showSyncStatus = true } label: {
                Image(systemName: SyncBadge().icon(model.syncStatus))
                    .font(.system(size: 16))
                    .foregroundStyle(SyncBadge().color(model.syncStatus))
                    .frame(width: 60, height: 36)
            }
            .buttonStyle(.plain)
            .help("Sync: " + SyncBadge().title(model.syncStatus))
            #if os(iOS)
            if DeveloperBuild.isDeveloper {
                Button { model.suggestImprovement() } label: {
                    Image(systemName: "lightbulb").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 60, height: 36)
                }
                .buttonStyle(.plain)
            }
            NavigationLink { SettingsView() } label: {
                Image(systemName: "gearshape").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 60, height: 36)
            }
            .buttonStyle(.plain)
            #endif
        }
        .frame(width: 76)
        .background(.background.secondary)
    }
}

struct RailButton: View {
    @Environment(AppModel.self) private var model
    let bar: BarItem

    var body: some View {
        let selected = model.sidebar == bar.item
        Button { model.sidebar = bar.item } label: {
            VStack(spacing: 3) {
                Image(systemName: bar.icon)
                    .symbolVariant(.fill)
                    .font(.system(size: 22))
                    .foregroundStyle(bar.item.tint.gradient)
                    .frame(width: 40, height: 34)
                    .overlay(alignment: .topTrailing) {
                        if bar.count > 0 {
                            Text("\(min(bar.count, 999))")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(bar.alert ? Palette.overdue : bar.item.tint.opacity(0.85)))
                                .foregroundStyle(.white)
                                .fixedSize()
                                .offset(x: 12, y: -4)
                        }
                    }
                Text(bar.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(width: 66)
            }
            .padding(.vertical, 5)
            .frame(width: 68)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.primary.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(bar.title)
        .contextMenu {
            if case .perspective(let id) = bar.item, let p = model.snapshot.perspectives.first(where: { $0.id == id }) {
                Button("Edit Perspective…") { model.editingPerspective = p }
                Button("Delete", role: .destructive) {
                    model.perform("Delete Perspective") { $0.set(.perspective, p.id, F.deleted, true) }
                    if model.sidebar == bar.item { model.sidebar = .inbox }
                }
            }
        }
    }
}

/// The sidebar column for the current perspective .
struct PerspectiveSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.sidebar ?? .inbox {
        case .projects: ProjectTree()
        case .tags: TagTree()
        case .forecast: ForecastDayList()
        case .review: ReviewList()
        default: EmptyView()
        }
    }
}

struct ProjectTree: View {
    @Environment(AppModel.self) private var model

    struct Node: Identifiable { let id: String; let depth: Int; let isFolder: Bool; let hasChildren: Bool; let open: Bool }

    var nodes: [Node] {
        let s = model.snapshot
        var out: [Node] = []
        func walk(_ ids: [String], _ depth: Int) {
            for id in ids {
                if !model.inFocus(id) { continue }
                if let f = s.folders[id] {
                    if f.dropped && model.filter != .all { continue }
                    let kids = (s.children[id] ?? []).filter { s.folders[$0] != nil || s.tasks[$0]?.isProject == true }
                    let open = !model.collapsedFolders.contains(id)
                    out.append(Node(id: id, depth: depth, isFolder: true, hasChildren: !kids.isEmpty, open: open))
                    if open { walk(kids, depth + 1) }
                } else if let p = s.tasks[id], p.isProject {
                    let remaining = s.info[id]?.isRemaining == true
                    if !remaining && model.filter != .all && !model.projectFocus.contains(id)
                        && !model.recentlyCompleted.contains(id) { continue }
                    out.append(Node(id: id, depth: depth, isFolder: false, hasChildren: false, open: false))
                }
            }
        }
        walk(s.libraryIDs, 0)
        return out
    }

    var body: some View {
        @Bindable var model = model
        let s = model.snapshot
        let currentNodes = nodes
        List(selection: $model.projectFocus) {
            ForEach(currentNodes) { n in
                HStack(spacing: 6) {
                    if n.isFolder {
                        Button { model.toggleFolder(n.id) } label: {
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                                .rotationEffect(.degrees(n.open ? 90 : 0)).foregroundStyle(.secondary)
                                .frame(width: 12)
                        }
                        .buttonStyle(.plain)
                        .opacity(n.hasChildren ? 1 : 0)
                        Image(systemName: "folder").foregroundStyle(Palette.folder)
                        RenamableName(id: n.id, name: s.folders[n.id]?.name ?? "", placeholder: "Untitled folder")
                    } else if let p = s.tasks[n.id] {
                        Color.clear.frame(width: 12)
                        ProjectIcon(project: p)
                        RenamableName(id: n.id, name: p.title, placeholder: "Untitled project",
                                      color: p.status == .active ? .primary : .secondary)
                        Spacer(minLength: 0)
                        if p.status == .onHold { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
                        if s.projectInfo[n.id]?.isStalled == true { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("Stalled: no available actions") }
                    }
                }
                .padding(.leading, CGFloat(n.depth) * 14)
                .tag(n.id)
                .contextMenu {
                    Button("New Project") { model.selection = []; model.projectFocus = n.isFolder ? [n.id] : model.projectFocus; model.newProject(inFolder: n.isFolder ? n.id : s.projectInfo[n.id]?.folderID) }
                    Button("New Folder") { model.newFolder() }
                    Button("Rename") { model.renamingID = n.id }
                    if !n.isFolder { Button("Convert to Action") { model.convertToAction(n.id) } }
                    if !n.isFolder, let p = s.tasks[n.id] {
                        let ids = model.projectFocus.contains(n.id) ? model.projectFocus.filter { s.tasks[$0]?.isProject == true } : [n.id]
                        Divider()
                        Button(p.status == .done ? "Mark Active" : (ids.count > 1 ? "Complete Projects" : "Complete Project")) {
                            model.setProjectStatus(Array(ids), p.status == .done ? .active : .done)
                        }
                        Menu("Status") {
                            ForEach(ProjectStatus.allCases, id: \.self) { st in
                                Button { model.setProjectStatus(Array(ids), st) } label: {
                                    if p.status == st { Label(st.label, systemImage: "checkmark") } else { Text(st.label) }
                                }
                            }
                        }
                    }
                    Divider()
                    Menu("Organize") { OrganizeMenuItems(ids: model.projectFocus.contains(n.id) ? Array(model.projectFocus) : [n.id]) }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteItems([n.id]) }
                }
            }
            .onMove { from, to in
                let rows = currentNodes.map { OutlineRow(id: $0.id, kind: $0.isFolder ? .folder : .project, depth: $0.depth,
                                                          hasChildren: $0.hasChildren, expanded: $0.open, showContext: false) }
                model.moveRows(from, to: to, in: rows)
            }
        }
        .listStyle(.sidebar)
        .plainSidebarBackground()
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("New Project") { model.newProject(inFolder: model.projectFocus.first.flatMap { s.folders[$0] != nil ? $0 : nil }) }
                    Button("New Folder") { model.newFolder() }
                } label: { Image(systemName: "plus") }
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                Picker("", selection: $model.filter) { ForEach(ItemFilter.allCases) { Text($0.label).tag($0) } }
                    .labelsHidden().fixedSize()
            }
            .padding(8)
            .buttonStyle(.borderless)
        }
        .onChange(of: model.projectFocus) { _, _ in model.selection = [] }
    }
}

struct TagTree: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        let s = model.snapshot
        let ordered = s.orderedTags
        List(selection: $model.tagFocus) {
            ForEach(ordered, id: \.tag.id) { e in
                HStack {
                    Image(systemName: e.tag.status == .onHold ? "pause.circle" : (e.tag.agent != nil ? "sparkles" : "tag")).foregroundStyle(Palette.tag)
                    RenamableName(id: e.tag.id, name: e.tag.name, placeholder: "Untitled tag",
                                  color: e.tag.status == .active ? .primary : .secondary)
                    Spacer()
                    let n = (s.tasksByTag[e.tag.id] ?? []).filter { s.info[$0]?.isAvailable == true }.count
                    if n > 0 { Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                .padding(.leading, CGFloat(e.depth) * 14)
                .tag(e.tag.id)
                .contextMenu {
                    Button("Rename") { model.renamingID = e.tag.id }
                    Menu("Organize") { OrganizeMenuItems(ids: model.tagFocus.contains(e.tag.id) ? Array(model.tagFocus) : [e.tag.id]) }
                    if DeveloperBuild.isDeveloper {
                        Divider()
                        Menu("Agent") { AgentMenuItems(tag: e.tag) }
                        Menu("New Agent Tag") {
                            ForEach(s.agentApps) { app in Button(app.name) { model.newAgentTag(app) } }
                        }
                    }
                }
            }
            .onMove { from, to in model.moveTags(from, to: to, in: ordered) }
        }
        .listStyle(.sidebar)
        .plainSidebarBackground()
        .onChange(of: model.tagFocus) { _, _ in model.selection = [] }
    }
}

/// Forecast sidebar: Past, a five-week calendar from this week, Future.
struct ForecastDayList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: model.snapshot.now)
        let counts = model.forecastCounts
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let days = (0..<35).map { cal.date(byAdding: .day, value: $0, to: weekStart)! }
        let symbols = (0..<7).map { i in cal.shortWeekdaySymbols[(cal.firstWeekday - 1 + i) % 7].uppercased() }
        ScrollView {
            VStack(spacing: 10) {
                bigButton("Past", counts.past, id: .distantPast, alert: counts.past > 0)
                VStack(spacing: 1) {
                    HStack(spacing: 1) {
                        ForEach(symbols, id: \.self) { Text($0).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                    }
                    .padding(.bottom, 4)
                    ForEach(0..<5, id: \.self) { w in
                        HStack(spacing: 1) {
                            ForEach(0..<7, id: \.self) { d in dayCell(days[w * 7 + d], today: today, count: counts.byDay[days[w * 7 + d]] ?? 0) }
                        }
                    }
                }
                bigButton("Future", counts.future, id: .distantFuture, alert: false)
            }
            .padding(10)
        }
        .task {
            let c = CalendarModel.shared
            if c.enabled && c.status == .notDetermined { await c.requestAccess() }
        }
    }

    func bigButton(_ title: String, _ count: Int, id: Date, alert: Bool) -> some View {
        let selected = model.forecastDay == id
        return Button { model.forecastDay = id } label: {
            VStack(spacing: 2) {
                Text(title).font(.title3.weight(.medium))
                Text("\(count)").font(.title3.monospacedDigit())
                Capsule().fill(alert ? Palette.overdue : .clear).frame(width: 10, height: 4)
            }
            .foregroundStyle(selected ? Color.white : .secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    func dayCell(_ day: Date, today: Date, count: Int) -> some View {
        let cal = Calendar.current
        let selected = model.forecastDay == day
        let isPast = day < today
        let isToday = day == today
        let dayNumber = cal.component(.day, from: day)
        let label = dayNumber == 1 ? day.formatted(.dateTime.month(.abbreviated)) : "\(dayNumber)"
        let hasEvents = !isPast && !CalendarModel.shared.events(on: day).isEmpty
        return Button { if !isPast { model.forecastDay = day } } label: {
            VStack(spacing: 2) {
                HStack {
                    Spacer()
                    Text(isToday ? "Today" : label).font(.caption2).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(count > 0 ? "\(count)" : " ").font(.title3.weight(isToday ? .semibold : .regular).monospacedDigit())
                Circle().fill(hasEvents ? Color.secondary : .clear).frame(width: 4, height: 4)
            }
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(selected ? Color.white : (isPast ? Color.secondary.opacity(0.4) : .primary))
            .background(Rectangle().fill(selected ? Color.accentColor : (isToday ? Color.secondary.opacity(0.22) : Color.secondary.opacity(isPast ? 0.04 : 0.1))))
        }
        .buttonStyle(.plain)
        .disabled(isPast)
    }
}

struct ReviewList: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        let s = model.snapshot
        let projects = model.reviewProjects
        List(selection: $model.projectFocus) {
            ForEach(projects) { p in
                HStack(spacing: 6) {
                    ProjectIcon(project: p)
                    Text(p.title).lineLimit(1).foregroundStyle(p.status == .active ? .primary : .secondary)
                    Spacer(minLength: 4)
                    if p.status == .onHold { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
                    if model.recentlyCompleted.contains(p.id) {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    } else if s.projectInfo[p.id]?.needsReview == true {
                        Circle().fill(Color.indigo).frame(width: 8, height: 8).help("Needs review")
                    }
                }
                .tag(p.id)
            }
        }
        .listStyle(.sidebar)
        .plainSidebarBackground()
        .onChange(of: model.projectFocus) { _, _ in model.selection = [] }
    }
}

extension View {
    /// Mac: white like the main list instead of the grey translucent sidebar material.
    func plainSidebarBackground() -> some View {
        #if os(macOS)
        scrollContentBackground(.hidden)
        #else
        self
        #endif
    }
}
