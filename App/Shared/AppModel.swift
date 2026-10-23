import Foundation
import Observation
import SwiftUI
import TaskerCore

enum SidebarItem: Hashable, Codable {
    case inbox, forecast, flagged, projects, tags, review, nearby, analytics, kanban
    case perspective(String)

    var title: String {
        switch self {
        case .inbox: "Inbox"; case .forecast: "Forecast"; case .flagged: "Flagged"
        case .projects: "Projects"; case .tags: "Tags"; case .review: "Review"; case .nearby: "Nearby"; case .analytics: "Analytics"; case .kanban: "Board"
        case .perspective: "Perspective"
        }
    }
    var icon: String {
        switch self {
        case .inbox: "tray"; case .forecast: "calendar"; case .flagged: "flag"
        case .projects: "folder"; case .tags: "tag"; case .review: "cup.and.saucer"; case .nearby: "location"; case .analytics: "chart.bar.xaxis"; case .kanban: "rectangle.split.3x1"
        case .perspective: "line.3.horizontal.decrease.circle"
        }
    }
}

enum ItemFilter: String, CaseIterable, Identifiable {
    case available, remaining, all
    var id: String { rawValue }
    var label: String { switch self { case .available: "Available"; case .remaining: "Remaining"; case .all: "Everything" } }
}

/// A visible row in an outline (already flattened, so the list stays lazy and fast).
struct OutlineRow: Identifiable, Hashable {
    enum Kind: Hashable { case task, project, folder }
    let id: String
    let kind: Kind
    let depth: Int
    let hasChildren: Bool
    let expanded: Bool
    /// Show the project name under the title (flat lists such as perspectives).
    let showContext: Bool
    /// False when the section header already names the project.
    var showProject = true
}

struct OutlineSection: Identifiable {
    let id: String
    let title: String
    var rows: [OutlineRow]
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let store: Store
    let sync: CloudSync?
    private(set) var snapshot: Snapshot {
        didSet { if snapshot.version != oldValue.version { announceChange() } }
    }

    @ObservationIgnored private var announceScheduled = false
    /// Tell companion apps the data changed (at most every 2 s); see `TaskerConfig.dataChangedNotification`.
    private func announceChange() {
        guard !announceScheduled else { return }
        announceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.announceScheduled = false
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName(TaskerConfig.dataChangedNotification as CFString), nil, nil, true)
        }
    }
    var syncStatus = SyncStatus()
    var openError: String?

    var sidebar: SidebarItem? = .inbox {
        didSet {
            guard oldValue != sidebar else { return }
            inboxKept = []
            pendingSelection = [] // only selections made after this point survive the switch
            // Deferred: mutating the list's selection while it is handling a sidebar click
            // re-enters the table view delegate.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recentlyCompleted = []
                self.selection = self.selection.filter { self.pendingSelection.contains($0) }
                self.pendingSelection = []
                if let e = self.editingID, !self.selection.contains(e) { self.editingID = nil }
                if self.sidebar == .review, self.projectFocus.isEmpty, let first = self.reviewProjects.first {
                    self.projectFocus = [first.id]
                }
                self.recordNav()
            }
        }
    }
    var selection: Set<String> = [] { didSet { pendingSelection.formUnion(selection.subtracting(oldValue)) } }
    @ObservationIgnored private var pendingSelection: Set<String> = []
    var editingID: String?
    /// Folder, project or tag being renamed in place (sidebar, folder rows); see `RenamableName`.
    var renamingID: String?
    /// Row whose note is being edited inline.
    var noteEditingID: String?
    /// Which inline field of the selected row has focus (chain: project → tags → flag).
    struct InlineField: Equatable {
        enum Field { case project, tags, flag }
        var id: String
        var field: Field
    }
    var inlineField: InlineField?
    /// Set to bring a row into view (minimal scroll); used when moving to the next task.
    var scrollToRow: String?
    var projectEditingSeed = ""
    var recentlyCompleted: Set<String> = []
    /// Items filed out of the Inbox this session; they stay visible there until Clean Up.
    var inboxKept: Set<String> = []
    /// Rows that left the current view because of an edit made here (completed, unflagged, filed into
    /// another project…) stay where they were until Clean Up or navigating elsewhere. See `keepInPlace`.
    struct KeptRow { var row: OutlineRow; var section: String; var sectionTitle: String; var sectionIndex: Int; var anchor: String?; var parent: String?; var index: Int; var seq: Int }
    @ObservationIgnored private var keptRows: [String: KeptRow] = [:]
    /// Items whose project was changed here: shown at their old place even if they'd appear elsewhere in the view.
    @ObservationIgnored private var pinnedRows: Set<String> = []
    @ObservationIgnored private var shownLayout: [OutlineSection] = []
    @ObservationIgnored private var shownViewKey = ""
    @ObservationIgnored private var localEditPending = false
    @ObservationIgnored private var keptSeq = 0
    /// Rows that stay open (showing their fields) after the selection moved below them, because closing
    /// them would shift the clicked row and the list can't scroll to make up for it. Cleared like kept rows.
    var lingeringOpen: Set<String> = []
    /// Where each filed item sat: the inbox item just above it (nil = top), so it can stay in place.
    @ObservationIgnored var inboxAnchor: [String: String?] = [:]
    @ObservationIgnored var inboxIndex: [String: Int] = [:]
    var filter: ItemFilter = .remaining
    var tagFilter: ItemFilter = .available
    var searchText = ""
    /// The day picked in Forecast; nil = today. Storing "today" as a date froze it at launch, so after
    /// midnight Forecast showed yesterday (empty) until the app was restarted.
    private var forecastPick: Date?
    var forecastDay: Date {
        get { forecastPick ?? Calendar.current.startOfDay(for: Date()) }
        set { forecastPick = newValue == Calendar.current.startOfDay(for: Date()) ? nil : newValue }
    }
    var expanded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "expanded") ?? []) {
        didSet { UserDefaults.standard.set(Array(expanded), forKey: "expanded") }
    }
    /// Sidebar selection in Projects/Review (projects or folders shown in the main view).
    var projectFocus: Set<String> = [] { didSet { if projectFocus != oldValue { recordNav() } } }
    /// Sidebar selection in Tags.
    var tagFocus: Set<String> = [] { didSet { if tagFocus != oldValue { recordNav() } } }
    /// Focus: when set, every view only shows these projects/folders and their contents.
    var focusIDs: Set<String> = []

    // MARK: Back / Forward

    struct NavState: Equatable { var sidebar: SidebarItem?; var projectFocus: Set<String>; var tagFocus: Set<String> }
    @ObservationIgnored private var history: [NavState] = []
    @ObservationIgnored private var navigating = false
    private(set) var historyIndex = -1
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    func recordNav() {
        guard !navigating else { return }
        let st = NavState(sidebar: sidebar, projectFocus: projectFocus, tagFocus: tagFocus)
        if historyIndex >= 0, history[historyIndex] == st { return }
        // Clicking through projects replaces the last step rather than piling up entries.
        if historyIndex >= 0, history[historyIndex].sidebar == st.sidebar, !history[historyIndex].projectFocus.isEmpty || !history[historyIndex].tagFocus.isEmpty,
           !st.projectFocus.isEmpty || !st.tagFocus.isEmpty {
            history[historyIndex] = st
        } else {
            history = Array(history.prefix(historyIndex + 1)) + [st]
            if history.count > 100 { history.removeFirst(history.count - 100) }
            historyIndex = history.count - 1
        }
    }

    func goBack() { guard canGoBack else { return }; historyIndex -= 1; apply(history[historyIndex]) }
    func goForward() { guard canGoForward else { return }; historyIndex += 1; apply(history[historyIndex]) }

    private func apply(_ st: NavState) {
        navigating = true
        sidebar = st.sidebar
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                self.projectFocus = st.projectFocus
                self.tagFocus = st.tagFocus
                self.navigating = false
            }
        }
    }

    // MARK: Focus

    func toggleFocus() {
        if !focusIDs.isEmpty { focusIDs = []; return }
        let candidates = projectFocus.union(selection).filter { snapshot.folders[$0] != nil || snapshot.tasks[$0]?.isProject == true }
        focusIDs = candidates
    }

    var canFocus: Bool {
        !focusIDs.isEmpty || projectFocus.union(selection).contains { snapshot.folders[$0] != nil || snapshot.tasks[$0]?.isProject == true }
    }

    func inFocus(_ id: String) -> Bool {
        guard !focusIDs.isEmpty else { return true }
        if focusIDs.contains(id) { return true }
        if snapshot.ancestors(of: id).contains(where: focusIDs.contains) { return true }
        // Folders above a focused item stay so the outline keeps its shape.
        return focusIDs.contains { snapshot.ancestors(of: $0).contains(id) }
    }
    var collapsedFolders: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedFolders") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedFolders), forKey: "collapsedFolders") }
    }
    var showSidebar = UserDefaults.standard.object(forKey: "showSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSidebar, forKey: "showSidebar") }
    }
    var sidebarWidth: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "sidebarWidth") as? Double ?? 270) {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebarWidth") }
    }
    var inspectorWidth: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "inspectorWidth") as? Double ?? 340) {
        didSet { UserDefaults.standard.set(Double(inspectorWidth), forKey: "inspectorWidth") }
    }
    var showInspector = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }
    var moveTargetFor: [String]?
    var editingPerspective: Perspective?
    var showSyncStatus = false
    var showQuickEntry = false

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var timer: Timer?

    private init() {
        let url = TaskerConfig.databaseURL()
        var opened: Store
        do {
            opened = try Store(url: url, role: "app")
        } catch {
            // Never start empty over a database we failed to open: move it aside, keep it.
            let aside = url.deletingLastPathComponent().appendingPathComponent("tasker-unreadable-\(Int(Date().timeIntervalSince1970)).sqlite")
            try? FileManager.default.moveItem(at: url, to: aside)
            opened = try! Store(url: url, role: "app")
            openError = "The database couldn't be opened and was moved to \(aside.lastPathComponent). Data will re-sync from iCloud. (\(error))"
        }
        store = opened
        snapshot = opened.snapshot()
        #if os(macOS)
        let device = Host.current().localizedName ?? "Mac"
        let platform = "macOS"
        #else
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        sync = !TaskerConfig.cloudKitAvailable ? nil : CloudSync(containerIdentifier: TaskerConfig.cloudContainer, store: opened, deviceName: device, platform: platform)

        store.onChange = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        if sync == nil {
            syncStatus.phase = .error("Sync off: this build isn't signed for iCloud")
        }
        sync?.onStatus = { [weak self] s in
            Task { @MainActor in self?.syncStatus = s }
        }
        observeExternalChanges()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.snapshot = self?.store.snapshot() ?? .empty
            }
        }
        // Belt and braces next to push: poll iCloud every 5 minutes while running.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.sync?.syncNow() }
        }
    }

    func start() {
        sync?.start()
        NearbyModel.shared.startIfNeeded()
        let store = self.store
        DispatchQueue.global(qos: .utility).async { store.backupIfNeeded() }
    }

    func becameActive() {
        try? store.pullNewOps()
        sync?.localChangesCommitted()
        Task { await sync?.syncNow() }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.snapshot = self.store.snapshot()
        }
    }

    private func observeExternalChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, _, _, _, _ in
            Task { @MainActor in
                try? AppModel.shared.store.pullNewOps()
                AppModel.shared.sync?.localChangesCommitted()
            }
        }, TaskerConfig.externalChangeNotification as CFString, nil, .deliverImmediately)
    }

    // MARK: Mutations

    /// Double-click: edit an action's or project's title in its row, or rename a folder/tag in place.
    /// Closes an open Project/Tags field first, so it works from there too.
    func beginEditing(_ id: String) {
        inlineField = nil
        if snapshot.tasks[id] != nil {
            renamingID = nil
            selection = [id]
            editingID = id
        } else {
            editingID = nil
            renamingID = id
        }
    }

    /// Renames a folder, tag, project or action (plain text, no quick-entry shorthand).
    func rename(_ id: String, to name: String) {
        renamingID = nil
        let v = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        if let t = snapshot.tasks[id], t.title != v { perform(t.isProject ? "Rename Project" : "Rename") { $0.setTask(id, F.title, .string(v)) } }
        else if let f = snapshot.folders[id], f.name != v { perform("Rename Folder") { $0.set(.folder, id, F.name, .string(v)) } }
        else if let g = snapshot.tags[id], g.name != v { perform("Rename Tag") { $0.set(.tag, id, F.name, .string(v)) } }
    }

    /// Shows an action where it lives (its project, or the Inbox) and selects it.
    func reveal(_ id: String) {
        guard let t = snapshot.tasks[id] else { return }
        if let p = snapshot.info[id]?.projectID {
            sidebar = .projects
            projectFocus = [p]
            expanded.formUnion(snapshot.ancestors(of: id))
        } else if snapshot.info[id]?.isInbox == true || t.position.parent == nil {
            sidebar = .inbox
        }
        DispatchQueue.main.async { self.selection = [id]; self.scrollToRow = id }
    }

    // MARK: Board (Kanban)

    func moveToStage(_ ids: [String], stage: String?, before: String?) {
        perform(stage == nil ? "Remove from Board" : "Move Card") { tx in
            for id in ids { tx.moveToStage(id, stage: stage, before: before) }
        }
    }

    func saveStage(_ s: KanbanStage) { perform("Edit Stage") { $0.saveStage(s) } }

    func addStage() {
        let last = snapshot.stages.last?.order
        perform("Add Stage") { $0.saveStage(KanbanStage(id: IDs.make(), name: "New Stage", order: FractionalIndex.between(last, nil))) }
    }

    func reorderStages(from: IndexSet, to: Int) {
        var list = snapshot.stages
        list.move(fromOffsets: from, toOffset: to)
        let keys = FractionalIndex.evenlySpaced(list.count)
        perform("Reorder Stages") { tx in
            for (i, var s) in list.enumerated() where s.order != keys[i] { s.order = keys[i]; tx.saveStage(s) }
        }
    }

    /// Re-reads the store after something wrote to it directly (e.g. the OmniFocus import).
    func reloadSnapshot() { snapshot = store.snapshot() }

    @discardableResult
    func perform(_ name: String, _ body: (inout Tx) -> Void) -> Bool {
        guard let record = store.transact(name, body) else { return false }
        localEditPending = true
        snapshot = store.snapshot()
        registerUndo(record)
        sync?.localChangesCommitted()
        return true
    }

    private func registerUndo(_ record: UndoRecord) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                if let inverse = model.store.undo(record) {
                    model.snapshot = model.store.snapshot()
                    model.registerUndo(inverse)
                    model.sync?.localChangesCommitted()
                }
            }
        }
        um.setActionName(record.name)
    }

    /// Several at once in one transaction: one snapshot rebuild and one redraw instead of one per item.
    func toggleComplete(_ ids: [String]) {
        guard ids.count > 1 else { if let id = ids.first { toggleComplete(id) }; return }
        let tasks = ids.compactMap { snapshot.tasks[$0] }
        let reopen = tasks.allSatisfy { $0.isCompleted && $0.repeatRule == nil }
        perform(reopen ? "Uncomplete" : "Complete") { tx in
            for t in tasks {
                if reopen { tx.uncomplete(t.id) } else if !t.isCompleted || t.repeatRule != nil { tx.complete(t.id) }
            }
        }
        if reopen { recentlyCompleted.subtract(ids) } else { recentlyCompleted.formUnion(tasks.filter { $0.repeatRule == nil }.map(\.id)) }
    }

    func toggleComplete(_ id: String) {
        guard let t = snapshot.tasks[id] else { return }
        if t.isCompleted && t.repeatRule == nil {
            perform("Uncomplete") { $0.uncomplete(id) }
            recentlyCompleted.remove(id)
        } else {
            perform("Complete") { $0.complete(id) }
            if t.repeatRule == nil { recentlyCompleted.insert(id) }
        }
    }

    func toggleFlag(_ ids: [String]) {
        let on = !ids.allSatisfy { snapshot.tasks[$0]?.flagged == true }
        perform(on ? "Flag" : "Unflag") { tx in for id in ids { tx.setTask(id, F.flagged, .bool(on)) } }
    }

    func setDate(_ ids: [String], _ field: String, _ date: Date?) {
        perform("Change Date") { tx in for id in ids { tx.setTask(id, field, .date(date)) } }
    }

    func deleteItems(_ ids: [String]) {
        perform("Delete") { tx in
            for id in ids {
                if tx.base.tasks[id] != nil { tx.delete(id) }
                else if tx.base.folders[id] != nil { tx.set(.folder, id, F.deleted, true) }
                else if tx.base.tags[id] != nil { tx.set(.tag, id, F.deleted, true) }
            }
        }
        selection.subtract(ids)
    }

    /// New action next to the selection, or in the current context.
    func newTask(isProject: Bool = false) {
        var n = NewTask(title: "")
        n.isProject = isProject
        let selected = selection.count == 1 ? selection.first : nil
        if isProject {
            if let s = selected, let f = snapshot.folders[s] { n.parent = f.id }
            else if let s = selected, let p = snapshot.tasks[s], p.isProject {
                n.parent = snapshot.projectInfo[s]?.folderID; n.placement = .after(s)
            }
        } else if let s = selected, let t = snapshot.tasks[s] {
            // A project: the new action goes at its top, i.e. right below the selected row.
            if t.isProject { n.parent = s; n.placement = .start }
            else { n.parent = snapshot.info[s]?.parentID; n.placement = .after(s); n.tagIDs = t.tagIDs.filter { _ in sidebar == .tags } }
        }
        // With nothing selected a new inbox item goes on top, where it's visible immediately.
        if !isProject && n.parent == nil && selected == nil { n.placement = .start }
        if sidebar == .flagged { n.flagged = true }
        if sidebar == .forecast {
            n.dueDate = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: forecastDay)
        }
        var newID = ""
        perform(isProject ? "New Project" : "New Action") { tx in newID = tx.createTask(n) }
        if let p = n.parent { expanded.insert(p) }
        if isProject && sidebar != .projects { sidebar = .projects }
        if !isProject && sidebar != .inbox && n.parent == nil && sidebar != .forecast && sidebar != .flagged { sidebar = .inbox }
        selection = [newID]
        editingID = newID
    }

    func newFolder() {
        var id = ""
        perform("New Folder") { tx in id = tx.createFolder("New Folder") }
        sidebar = .projects
        selection = [id]
    }

    /// Ends inline editing; Return on a non-empty title opens the next sibling.
    func commitInline(_ id: String, title: String, continueWithNew: Bool) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let t = snapshot.tasks[id], t.title.isEmpty {
                // Abandoned new row: remove without leaving an undo step behind.
                _ = store.transact("Delete") { $0.delete(id) }
                snapshot = store.snapshot()
                sync?.localChangesCommitted()
            }
            editingID = nil
            selection = []
            return
        }
        if snapshot.tasks[id]?.title != trimmed {
            let parsed = QuickEntryParser(snapshot: snapshot).parse(trimmed)
            perform("Rename") { tx in
                tx.setTask(id, F.title, .string(parsed.title.isEmpty ? trimmed : parsed.title))
                for t in parsed.tagIDs { tx.setTag(id, t, true) }
                for name in parsed.unknownTags { let tag = tx.createTag(name); tx.setTag(id, tag, true) }
                if parsed.flagged { tx.setTask(id, F.flagged, true) }
                if let d = parsed.dueDate { tx.setTask(id, F.dueDate, .date(d)) }
                if let d = parsed.deferDate { tx.setTask(id, F.deferDate, .date(d)) }
                if let d = parsed.plannedDate { tx.setTask(id, F.plannedDate, .date(d)) }
                if let e = parsed.estimatedMinutes { tx.setTask(id, F.estimate, .optional(e)) }
                if let p = parsed.projectID, tx.base.tasks[id]?.isProject == false { tx.move(id, to: p) }
            }
        }
        editingID = nil
        if continueWithNew, let t = snapshot.tasks[id] {
            selection = [id]
            newTask(isProject: t.isProject)
        }
    }

    // MARK: Organize (OmniFocus's Organize menu)

    /// What Organize commands act on: the list selection, else the folders/projects/tags picked in the sidebar.
    var organizeIDs: [String] {
        if !selection.isEmpty { return Array(selection) }
        switch sidebar {
        case .projects: return Array(projectFocus)
        case .tags: return Array(tagFocus)
        default: return []
        }
    }

    var canOrganize: Bool { !organizeIDs.isEmpty && editingID == nil }


    func indent(_ ids: [String]) {
        // What's visibly above each row at the same depth. Usually that's its real previous sibling and the
        // outline indent does the job; when it isn't (e.g. a project converted here and kept in place),
        // indent into what you see.
        let rows = shownLayout.flatMap(\.rows)
        let chosen = Set(ids)
        var visual: [String: String] = [:]
        for id in ids where snapshot.tasks[id]?.isProject == false {
            guard let i = rows.firstIndex(where: { $0.id == id }) else { continue }
            let d = rows[i].depth
            guard let prev = rows[..<i].last(where: { $0.depth <= d && !chosen.contains($0.id) }), prev.depth == d,
                  snapshot.tasks[prev.id] != nil else { continue }
            let parentKey = snapshot.info[id]?.parentID ?? Snapshot.inboxKey
            let sibs = (snapshot.children[parentKey] ?? []).filter { !chosen.contains($0) || $0 == id }
            let realPrev = sibs.firstIndex(of: id).flatMap { $0 > 0 ? sibs[$0 - 1] : nil }
            if realPrev != prev.id { visual[id] = prev.id }
        }
        var parents: [String] = []
        perform("Indent") { tx in
            parents = tx.indent(ids.filter { visual[$0] == nil })
            for (id, target) in visual { tx.move(id, to: target, placement: .end); parents.append(target) }
        }
        expanded.formUnion(parents)
    }

    /// Convert to Action: the project becomes an Inbox action (its actions its subtasks), stays in place in
    /// this view, and its Project field opens so it can be filed right away.
    func convertToAction(_ id: String) {
        pinInPlace([id])
        perform("Convert to Action") { $0.convertToAction(id) }
        if sidebar != .projects || projectFocus.isEmpty || !projectFocus.contains(id) {
            openInline(id, .project)
        } else {
            // It was the focused project: show it where it now lives.
            sidebar = .inbox
            DispatchQueue.main.async { self.openInline(id, .project) }
        }
    }

    /// Convert to Project: it stays where it is in this view (expanded) so you can add actions to it right
    /// there; it goes into the folder of the project it was in (top level from the Inbox).
    func convertToProject(_ id: String) {
        let folder = snapshot.info[id]?.projectID.flatMap { snapshot.projectInfo[$0]?.folderID }
        pinInPlace([id])
        expanded.insert(id)
        perform("Convert to Project") { $0.convertToProject(id, folder: folder) }
    }

    func outdent(_ ids: [String]) { perform("Outdent") { tx in tx.outdent(ids) } }

    func moveUpDown(_ ids: [String], up: Bool) { perform("Move") { tx in tx.moveVertically(ids, up: up) } }
    func moveUpDown(_ id: String, up: Bool) { moveUpDown([id], up: up) }

    /// Add Inside (⇧⌘]): a new child at the top of the selected action/project.
    func addInside() {
        guard let s = selection.first, snapshot.tasks[s] != nil else { return }
        var id: String?
        perform("Add Inside") { tx in id = tx.addInside(s) }
        guard let id else { return }
        expanded.insert(s)
        selection = [id]; editingID = id
    }

    /// Add Outside (⇧⌘[): a new sibling right after the selected item's parent group.
    func addOutside() {
        guard let s = selection.first else { return }
        var id: String?
        perform("Add Outside") { tx in id = tx.addOutside(s) }
        guard let id else { return }
        selection = [id]; editingID = id
    }

    /// Group (⌥⌘G): actions go into a new action group, projects/folders into a new folder.
    func group(_ ids: [String]) {
        var g: String?
        perform("Group") { tx in g = tx.group(ids) }
        guard let g else { return }
        expanded.insert(g)
        selection = [g]
        if snapshot.tasks[g] != nil { editingID = g }
    }

    func ungroup(_ ids: [String]) {
        let kids = ids.flatMap { snapshot.children[$0] ?? [] }
        perform("Ungroup") { tx in tx.ungroup(ids) }
        selection = Set(kids)
    }

    /// Sort Once: the selected container's children, the selected siblings, or (nothing selected)
    /// the top level of the current view.
    func sortOnce(_ ids: [String], by sort: OutlineSort) {
        let root: String? = switch sidebar {
        case .inbox: Snapshot.inboxKey
        case .projects: Snapshot.libraryKey
        case .tags: Snapshot.tagsKey
        default: nil
        }
        perform("Sort") { tx in tx.sortOnce(ids, by: sort, rootKey: root) }
        if ids.count == 1 { expanded.insert(ids[0]) }
    }

    func moveItems(_ ids: [String], to target: String?) {
        perform("Move") { tx in
            for id in ids {
                if tx.base.tasks[id]?.isProject == true {
                    tx.move(id, to: target.flatMap { tx.base.folders[$0] != nil ? $0 : nil })
                } else if tx.base.folders[id] != nil {
                    tx.moveFolder(id, to: target.flatMap { tx.base.folders[$0] != nil ? $0 : nil })
                } else {
                    tx.move(id, to: target)
                }
            }
        }
        if let target { expanded.insert(target) }
    }

    /// Clean Up: hide completed items and items already filed out of the Inbox.
    func cleanUp() {
        recentlyCompleted = []
        inboxKept = []
        inboxAnchor = [:]
        inboxIndex = [:]
        resetKeptRows()
        snapshot = store.snapshot()
    }

    func assignProject(_ ids: [String], _ projectID: String?) {
        // Remember the row visibly above each filed item (and its position) so it can stay put.
        let visible = sidebar == .inbox ? sections().flatMap(\.rows).map(\.id) : []
        for id in ids where snapshot.info[id]?.isInbox == true && snapshot.tasks[id]?.isProject == false {
            if inboxAnchor[id] == nil, let i = visible.firstIndex(of: id) {
                inboxAnchor[id] = .some(i > 0 ? visible[i - 1] : nil)
                inboxIndex[id] = i
            }
            inboxKept.insert(id)
        }
        if sidebar != .inbox { pinInPlace(ids) }
        moveItems(ids, to: projectID)
    }

    /// Accepts "Folder : Sub : Name"; missing folders are created. Re-uses an existing project at that path.
    @discardableResult
    func createProject(named path: String, folder: String? = nil) -> String {
        if folder == nil, let existing = snapshot.project(atPath: path) { return existing.id }
        var id = ""
        perform("New Project") { tx in
            if let folder {
                var n = NewTask(title: path); n.isProject = true; n.parent = folder
                id = tx.createTask(n)
            } else {
                id = tx.createProject(path: path)
            }
        }
        return id
    }

    @discardableResult
    func createTag(named name: String) -> String {
        if let existing = snapshot.tags.values.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) { return existing.id }
        var id = ""
        perform("New Tag") { tx in id = tx.createTag(name) }
        return id
    }

    // MARK: Review

    /// Projects due for review, plus ones reviewed this session (so the list doesn't jump).
    var reviewProjects: [TaskItem] {
        snapshot.orderedProjects.filter { snapshot.projectInfo[$0.id]?.needsReview == true || recentlyCompleted.contains($0.id) }
    }

    func markReviewedAndAdvance() {
        let list = reviewProjects
        guard let id = projectFocus.first, snapshot.tasks[id]?.isProject == true else { return }
        perform("Mark Reviewed") { $0.markReviewed(id) }
        recentlyCompleted.insert(id)
        if let i = list.firstIndex(where: { $0.id == id }), i + 1 < list.count { projectFocus = [list[i + 1].id] }
    }

    func reviewStep(_ delta: Int) {
        let list = reviewProjects
        guard !list.isEmpty else { return }
        let i = projectFocus.first.flatMap { id in list.firstIndex { $0.id == id } } ?? -1
        let j = min(max(i + delta, 0), list.count - 1)
        projectFocus = [list[j].id]
    }

    // MARK: Drag to reorder

    /// Views whose order is the outline order (others are sorted or grouped and can't be reordered).
    var canReorder: Bool {
        guard searchText.isEmpty, focusIDs.isEmpty else { return false }
        switch sidebar ?? .inbox {
        case .inbox, .projects: return true
        default: return false
        }
    }

    /// SwiftUI `onMove` for a section's flattened rows: works out the new parent and position from
    /// the row just above the drop point, keeping tasks among tasks, projects among projects/folders.
    func moveRows(_ from: IndexSet, to dest: Int, in rows: [OutlineRow]) {
        let moving = from.map { rows[$0].id }
        var aboveIndex = dest - 1
        while aboveIndex >= 0, moving.contains(rows[aboveIndex].id) { aboveIndex -= 1 }
        let above = aboveIndex >= 0 ? rows[aboveIndex] : nil
        let s = snapshot
        perform("Move") { tx in
            // Insert in reverse so a multi-row drag keeps its order after the same anchor.
            for id in moving.reversed() {
                if s.folders[id] != nil {
                    guard let (parent, place) = libraryTarget(for: id, above: above, s) else { continue }
                    tx.moveFolder(id, to: parent, placement: place)
                } else if let t = s.tasks[id], t.isProject {
                    guard let (parent, place) = libraryTarget(for: id, above: above, s) else { continue }
                    tx.move(id, to: parent, placement: place)
                } else {
                    guard let (parent, place) = taskTarget(above: above, s) else { continue }
                    tx.move(id, to: parent, placement: place)
                }
            }
        }
    }

    /// Where a project or folder dropped below `above` goes (folders/library level only).
    private func libraryTarget(for id: String, above: OutlineRow?, _ s: Snapshot) -> (String?, Placement)? {
        guard let above else { return (nil, .start) }
        if let f = s.folders[above.id] {
            if above.expanded && above.id != id { return (f.id, .start) }      // into the open folder
            return (f.position.parent.flatMap { s.folders[$0] != nil ? $0 : nil }, .after(f.id))
        }
        // Above is a project, or a task inside one: go right after that project.
        let projectID = s.tasks[above.id]?.isProject == true ? above.id : s.info[above.id]?.projectID
        guard let pid = projectID else { return nil }   // Inbox tasks: no library position here
        return (s.projectInfo[pid]?.folderID, .after(pid))
    }

    /// Where an action dropped below `above` goes.
    private func taskTarget(above: OutlineRow?, _ s: Snapshot) -> (String?, Placement)? {
        guard let above else { return (nil, .start) }                       // top of the Inbox
        if s.folders[above.id] != nil { return nil }                         // actions don't live in folders
        if let t = s.tasks[above.id], t.isProject { return (t.id, .start) }  // first action of that project
        if above.expanded && above.hasChildren { return (above.id, .start) } // into the open group
        return (s.info[above.id]?.parentID, .after(above.id))               // next to it
    }

    /// Reorders tags in the Tags sidebar (stays at the same level as the tag it's dropped below).
    func moveTags(_ from: IndexSet, to dest: Int, in ordered: [(tag: Tag, depth: Int)]) {
        let moving = from.map { ordered[$0].tag.id }
        var i = dest - 1
        while i >= 0, moving.contains(ordered[i].tag.id) { i -= 1 }
        perform("Move Tag") { tx in
            for id in moving.reversed() {
                if i < 0 {
                    let first = tx.base.tagChildren[Snapshot.tagsKey]?.first.flatMap { tx.base.tags[$0]?.position.order }
                    tx.set(.tag, id, F.pos, .object(["p": .null, "o": .string(FractionalIndex.between(nil, first))]))
                    continue
                }
                let anchor = ordered[i].tag
                let siblings = (tx.base.tagChildren[anchor.position.parent ?? Snapshot.tagsKey] ?? []).filter { $0 != id }
                let idx = siblings.firstIndex(of: anchor.id) ?? siblings.count - 1
                let next = idx + 1 < siblings.count ? tx.base.tags[siblings[idx + 1]]?.position.order : nil
                let order = FractionalIndex.between(anchor.position.order, next)
                tx.set(.tag, id, F.pos, .object(["p": anchor.position.parent.map(JSON.string) ?? .null, "o": .string(order)]))
            }
        }
    }

    /// Clicking a row's project or tags (selected or not): select it and open that inline field.
    func openInline(_ id: String, _ field: InlineField.Field) {
        if selection != [id] { selection = [id] }
        projectEditingSeed = ""
        // After the row has re-rendered as the selected (editable) row.
        DispatchQueue.main.async { self.inlineField = .init(id: id, field: field) }
    }

    /// Moves to the next action in the current list and opens its Project field, so a run of
    /// items (e.g. the Inbox) can be processed with the keyboard: Project ↩ Tags ↩ → next item.
    func editNextTask(after id: String) {
        let rows = sections().flatMap(\.rows).filter { $0.kind == .task }
        guard let i = rows.firstIndex(where: { $0.id == id }) else { inlineField = nil; return }
        guard i + 1 < rows.count else { inlineField = nil; return } // last item: just finish
        let next = rows[i + 1].id
        selection = [next]
        scrollToRow = next
        projectEditingSeed = ""
        inlineField = .init(id: next, field: .project)
    }

    func toggleFolder(_ id: String) {
        if collapsedFolders.contains(id) { collapsedFolders.remove(id) } else { collapsedFolders.insert(id) }
    }

    func newProject(inFolder folder: String?) {
        var n = NewTask(title: ""); n.isProject = true; n.parent = folder
        var id = ""
        perform("New Project") { tx in id = tx.createTask(n) }
        if sidebar != .projects { sidebar = .projects }
        projectFocus = [id]
        DispatchQueue.main.async { self.projectFocus = [id]; self.selection = [id]; self.editingID = id }
    }

    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: tasker://add (other apps, e.g. Scriptorium)

    /// Short confirmation shown in the app (iOS) after a quick add from another app.
    var banner: String?

    func handleAdd(_ r: AddRequest) {
        let s = snapshot
        let parser = QuickEntryParser(snapshot: s)
        func date(_ v: String?, _ hour: Int) -> Date? {
            guard let v else { return nil }
            if let d = ISO8601DateFormatter().date(from: v) { return d }
            return parser.date(v, hour: hour)
        }
        var projectID = r.project.flatMap { name -> String? in
            if let p = s.project(atPath: name) { return p.id }
            let remaining = s.orderedProjects.filter { s.info[$0.id]?.isRemaining == true }
            return Fuzzy.rank(remaining, name) { ([$0.title] + s.folderPath(of: $0.id)).joined(separator: "  ") }.first?.id
        }
        var tagIDs = r.tags.compactMap { n in s.tags.values.first { $0.name.compare(n, options: .caseInsensitive) == .orderedSame }?.id }
        let title = r.title.isEmpty ? (r.url.map { _ in "Link" } ?? String(r.note.prefix(80))) : r.title
        if r.quick {
            if projectID == nil, let name = r.project, name.contains(":") { projectID = createProject(named: name) }
            for n in r.tags where !s.tags.values.contains(where: { $0.name.compare(n, options: .caseInsensitive) == .orderedSame }) {
                tagIDs.append(createTag(named: n))
            }
            let id = quickAdd(title: title, note: r.fullNote, projectID: projectID, tagIDs: tagIDs, flagged: r.flagged,
                              deferDate: date(r.deferDate, 0), dueDate: date(r.due, 17))
            if let id, let planned = date(r.planned, 9) { perform("Planned") { $0.setTask(id, F.plannedDate, .date(planned)) } }
            banner = "Added to Uberdoer: \(title)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.banner = nil }
            #if os(macOS)
            NotificationCenter.default.post(name: .taskerQuickAdded, object: title)
            #endif
            if let x = r.xSuccess { openExternal(x) }
        } else {
            var c = Capture(title: title, note: r.fullNote)
            c.projectID = projectID; c.tagIDs = tagIDs; c.flagged = r.flagged; c.dueDate = date(r.due, 17)
            #if os(macOS)
            NotificationCenter.default.post(name: .taskerShowQuickEntry, object: nil, userInfo: ["capture": c])
            #else
            quickEntryCapture = c
            showQuickEntry = true
            #endif
        }
    }

    func openExternal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    // MARK: Quick entry

    struct Capture: Equatable {
        var title = ""
        var note = ""
        var projectID: String?
        var tagIDs: [String] = []
        var flagged = false
        var dueDate: Date?
        /// Open Quick Entry already listening (voice entry).
        var listen = false
    }

    var quickEntryCapture = Capture()

    /// Opens Quick Entry pre-filled for the current context (used for "+" on compact screens,
    /// where inline row editing would fight with navigation).
    func presentQuickEntry() {
        var c = Capture()
        if let s = selection.first, selection.count == 1, let t = snapshot.tasks[s] {
            c.projectID = t.isProject ? s : snapshot.info[s]?.projectID
        }
        if sidebar == .flagged { c.flagged = true }
        if sidebar == .forecast { c.dueDate = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: forecastDay) }
        quickEntryCapture = c
        showQuickEntry = true
    }

    @discardableResult
    func quickAdd(title raw: String, note: String, projectID: String?, tagIDs: [String], flagged: Bool,
                  deferDate: Date?, dueDate: Date?) -> String? {
        let parsed = QuickEntryParser(snapshot: snapshot).parse(raw)
        guard !parsed.title.isEmpty || !note.isEmpty else { return nil }
        var id: String?
        perform("Quick Entry") { tx in
            var n = NewTask(title: parsed.title.isEmpty ? raw : parsed.title)
            n.note = note
            n.parent = parsed.projectID ?? projectID
            n.flagged = flagged || parsed.flagged
            n.deferDate = parsed.deferDate ?? deferDate
            n.dueDate = parsed.dueDate ?? dueDate
            n.plannedDate = parsed.plannedDate
            n.estimatedMinutes = parsed.estimatedMinutes
            var tags = Set(tagIDs).union(parsed.tagIDs)
            for name in parsed.unknownTags { tags.insert(tx.createTag(name)) }
            n.tagIDs = Array(tags)
            id = tx.createTask(n)
        }
        return id
    }

    // MARK: List content

    var dueSoonCount: Int {
        snapshot.tasks.values.filter { t in
            !t.isProject && (snapshot.info[t.id].map { $0.isRemaining && ($0.effectiveDue.map { $0 < snapshot.dueSoon } ?? false) } ?? false)
        }.count
    }
    var inboxCount: Int { snapshot.inboxIDs.filter { snapshot.info[$0]?.isRemaining == true }.count }
    var flaggedCount: Int { flaggedIDs().count }
    var reviewCount: Int { snapshot.projectInfo.values.filter(\.needsReview).count }

    private func visible(_ id: String, filter: ItemFilter) -> Bool {
        if recentlyCompleted.contains(id) || editingID == id { return true }
        guard let i = snapshot.info[id] else { return false }
        switch filter {
        case .available: return i.isAvailable || (i.isRemaining && i.hasChildren && i.remainingChildren > 0 && !i.isDeferred)
        case .remaining: return i.isRemaining
        case .all: return true
        }
    }

    private func outline(_ ids: [String], depth: Int, filter: ItemFilter, into rows: inout [OutlineRow], forceOpen: Set<String> = []) {
        for id in ids {
            if let f = snapshot.folders[id] {
                if filter != .all && f.dropped { continue }
                var sub: [OutlineRow] = []
                let open = expanded.contains(id)
                outline(snapshot.children[id] ?? [], depth: depth + 1, filter: filter, into: &sub)
                if sub.isEmpty && filter != .all && !selection.contains(id) { continue }
                rows.append(OutlineRow(id: id, kind: .folder, depth: depth, hasChildren: !sub.isEmpty, expanded: open, showContext: false))
                if open { rows.append(contentsOf: sub) }
            } else if let t = snapshot.tasks[id] {
                guard visible(id, filter: t.isProject && filter == .available ? .remaining : filter) else { continue }
                if t.isProject && filter == .available && t.status != .active && !selection.contains(id) { continue }
                var sub: [OutlineRow] = []
                let open = expanded.contains(id) || forceOpen.contains(id) || (editingID != nil && snapshot.info[editingID!]?.parentID == id)
                outline(snapshot.children[id] ?? [], depth: depth + 1, filter: filter, into: &sub)
                rows.append(OutlineRow(id: id, kind: t.isProject ? .project : .task, depth: depth, hasChildren: !sub.isEmpty, expanded: open, showContext: false))
                if open { rows.append(contentsOf: sub) }
            }
        }
    }

    func sections() -> [OutlineSection] {
        let raw = unfocusedSections()
        let focused = focusIDs.isEmpty ? raw : raw.map { sec in
            var s = sec
            s.rows = sec.rows.filter { inFocus($0.id) }
            return s
        }.filter { !$0.rows.isEmpty || $0.title.isEmpty }
        return keepInPlace(focused)
    }

    // MARK: Keep edited rows in place (all views, like the Inbox)

    /// Identifies "the same screen": changing any of these is navigating away, which drops kept rows.
    private var viewKey: String {
        let d = forecastDay.timeIntervalSinceReferenceDate
        return "\(String(describing: sidebar))|\(projectFocus.sorted())|\(tagFocus.sorted())|\(focusIDs.sorted())|\(searchText)|\(d)|\(filter)|\(tagFilter)"
    }

    private func resetKeptRows() {
        keptRows = [:]; pinnedRows = []; shownLayout = []; localEditPending = false
        if !lingeringOpen.isEmpty { DispatchQueue.main.async { self.lingeringOpen = [] } }
    }

    /// Called by the list when the selection changes.
    func selectionMoved(from old: Set<String>, to new: Set<String>, canCompensate: Bool) {
        guard new.count == 1, let target = new.first else { return }
        let order = shownLayout.flatMap { $0.rows.map(\.id) }
        guard let ti = order.firstIndex(of: target) else { return }
        func above(_ id: String) -> Bool { (order.firstIndex(of: id) ?? .max) < ti }
        var keep = lingeringOpen.filter(above)          // rows below the click may close: nothing above it moves
        if !canCompensate, old.count == 1, let prev = old.first, prev != target, above(prev) { keep.insert(prev) }
        keep.remove(target)
        if keep != lingeringOpen { lingeringOpen = keep }
    }

    /// Remembers where `ids` are shown now, so they stay there after the edit that follows.
    private func pinInPlace(_ ids: [String]) {
        for id in ids where keptRows[id] == nil {
            if let k = keptRow(id) { keptRows[id] = k }
        }
        pinnedRows.formUnion(ids)
    }

    private func keptRow(_ id: String) -> KeptRow? {
        for (si, sec) in shownLayout.enumerated() {
            guard let i = sec.rows.firstIndex(where: { $0.id == id }) else { continue }
            return makeKept(sec, si, i)
        }
        return nil
    }

    private func makeKept(_ sec: OutlineSection, _ si: Int, _ i: Int) -> KeptRow {
        let row = sec.rows[i]
        let parent = row.depth == 0 ? nil : sec.rows[..<i].last { $0.depth < row.depth }?.id
        keptSeq += 1
        return KeptRow(row: row, section: sec.id, sectionTitle: sec.title, sectionIndex: si,
                       anchor: i > 0 ? sec.rows[i - 1].id : nil, parent: parent, index: i, seq: keptSeq)
    }

    /// Rows that disappeared because of an edit made in this view are put back at their old place
    /// (after the row that was above them); Clean Up or navigating elsewhere lets them go.
    private func keepInPlace(_ computed: [OutlineSection]) -> [OutlineSection] {
        let key = viewKey
        if key != shownViewKey { resetKeptRows(); shownViewKey = key }
        // The Inbox has its own anchoring for filed items; it gets completed/unflagged handling from here too.
        var result = computed
        if localEditPending {
            localEditPending = false
            let now = Set(result.flatMap { $0.rows.map(\.id) })
            for (si, sec) in shownLayout.enumerated() {
                // Folders too: one emptied by this edit stays, so what was in it has somewhere to show.
                for (i, row) in sec.rows.enumerated() where !now.contains(row.id) && keptRows[row.id] == nil
                    && (snapshot.tasks[row.id] != nil || snapshot.folders[row.id] != nil) {
                    keptRows[row.id] = makeKept(sec, si, i)
                }
            }
        }
        if !keptRows.isEmpty {
            keptRows = keptRows.filter { snapshot.tasks[$0.key] != nil || snapshot.folders[$0.key] != nil } // deleted items do go away
            // A kept row that is (now) a project — e.g. converted here — shows its actions underneath,
            // so you can add to it in place (Return, Add Inside, Indent) like to a group.
            var childRows: [String: [OutlineRow]] = [:]
            var childIDs = Set<String>()
            for (p, k) in keptRows where snapshot.tasks[p]?.isProject == true && expanded.contains(p) {
                var rows: [OutlineRow] = []
                outline(snapshot.children[p] ?? [], depth: k.row.depth + 1, filter: .remaining, into: &rows)
                childRows[p] = rows
                childIDs.formUnion(rows.map(\.id))
            }
            if !pinnedRows.isEmpty || !childIDs.isEmpty {
                for i in result.indices {
                    // Pinned rows (with their subtree) leave their new place; children show under the kept project.
                    var out: [OutlineRow] = []
                    var skipDepth: Int?
                    for r in result[i].rows {
                        if let d = skipDepth, r.depth > d { continue }
                        skipDepth = nil
                        if pinnedRows.contains(r.id) && keptRows[r.id] != nil { skipDepth = r.depth; continue }
                        if childIDs.contains(r.id) { continue }
                        out.append(r)
                    }
                    result[i].rows = out
                }
            }
            // Rows whose parent is itself a kept row wait for it, so keep passing until nothing more fits.
            var pending = keptRows.values.sorted(by: { $0.seq < $1.seq })
            var progress = true
            while progress && !pending.isEmpty {
            progress = false
            var waiting: [KeptRow] = []
            for k in pending {
                if childIDs.contains(k.row.id) { continue }
                if result.contains(where: { $0.rows.contains { $0.id == k.row.id } }) { continue }
                // Its parent row was collapsed or is gone: nothing to show it under (yet).
                if let p = k.parent, !result.contains(where: { $0.rows.contains { $0.id == p && $0.expanded } }) {
                    if keptRows[p] != nil { waiting.append(k) }
                    continue
                }
                progress = true
                var si = result.firstIndex { $0.id == k.section }
                if si == nil {
                    let at = min(k.sectionIndex, result.count)
                    result.insert(OutlineSection(id: k.section, title: k.sectionTitle, rows: []), at: at)
                    si = at
                }
                var rows = result[si!].rows
                var row = k.row
                let kids = childRows[k.row.id] ?? []
                if let t = snapshot.tasks[k.row.id], (t.isProject ? OutlineRow.Kind.project : .task) != row.kind {
                    // Converted since it was captured (project ⇄ action).
                    row = OutlineRow(id: row.id, kind: t.isProject ? .project : .task, depth: row.depth, hasChildren: row.hasChildren,
                                     expanded: row.expanded, showContext: row.showContext, showProject: row.showProject)
                }
                if snapshot.tasks[k.row.id]?.isProject == true {
                    row = OutlineRow(id: row.id, kind: .project, depth: row.depth, hasChildren: !(snapshot.children[row.id] ?? []).isEmpty,
                                     expanded: expanded.contains(row.id), showContext: row.showContext, showProject: row.showProject)
                }
                let at: Int
                if let a = k.anchor, let ai = rows.firstIndex(where: { $0.id == a }) {
                    var j = ai + 1
                    // Above it was a sibling (or its subtree): go past that subtree. A parent: right below it.
                    if k.row.depth <= rows[ai].depth { while j < rows.count, rows[j].depth > rows[ai].depth { j += 1 } }
                    at = j
                } else if k.anchor == nil {
                    at = 0
                } else {
                    at = min(k.index, rows.count)
                }
                rows.insert(contentsOf: [row] + kids, at: at)
                result[si!].rows = rows
            }
            pending = waiting
            }
        }
        shownLayout = result
        return result
    }

    private func unfocusedSections() -> [OutlineSection] {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { return searchSections() }
        switch sidebar ?? .inbox {
        case .inbox:
            var rows: [OutlineRow] = []
            outline(snapshot.inboxIDs, depth: 0, filter: .remaining, into: &rows)
            // Filed items stay exactly where they were until Clean Up, so editing project then tags
            // doesn't make the row jump.
            let kept = inboxKept.filter { snapshot.tasks[$0] != nil && snapshot.info[$0]?.isInbox == false }
            for id in snapshot.inboxIDs.isEmpty ? Array(kept) : kept.sorted(by: { anchorDepth($0) < anchorDepth($1) }) {
                let row = OutlineRow(id: id, kind: .task, depth: 0, hasChildren: false, expanded: false, showContext: true)
                var anchor = inboxAnchor[id] ?? nil
                // Walk up past anchors that were themselves filed but are no longer shown.
                var guardN = 0
                while let a = anchor, !rows.contains(where: { $0.id == a }), guardN < 50 { anchor = inboxAnchor[a] ?? nil; guardN += 1 }
                if let a = anchor, let i = rows.lastIndex(where: { $0.id == a || isDescendantRow($0.id, of: a) }) {
                    rows.insert(row, at: i + 1)
                } else if anchor == nil, inboxAnchor[id] == .some(nil) {
                    rows.insert(row, at: 0) // it was the first row
                } else {
                    rows.insert(row, at: min(inboxIndex[id] ?? 0, rows.count))
                }
            }
            return [OutlineSection(id: "inbox", title: "", rows: rows)]
        case .projects, .review:
            if projectFocus.isEmpty {
                if sidebar == .review {
                    let projects = snapshot.orderedProjects.filter { snapshot.projectInfo[$0.id]?.needsReview == true || recentlyCompleted.contains($0.id) }
                    return [OutlineSection(id: "review", title: "", rows: projects.map {
                        OutlineRow(id: $0.id, kind: .project, depth: 0, hasChildren: false, expanded: false, showContext: false)
                    })]
                }
                var rows: [OutlineRow] = []
                outline(snapshot.libraryIDs, depth: 0, filter: filter, into: &rows)
                return [OutlineSection(id: "library", title: "", rows: rows)]
            }
            // Focused: the selected folders' contents and the selected projects, opened, in library order.
            let order = PerspectiveEngine(snapshot).manualOrder()
            var rows: [OutlineRow] = []
            for id in projectFocus.sorted(by: { (order[$0] ?? .max) < (order[$1] ?? .max) }) {
                if snapshot.folders[id] != nil {
                    outline(snapshot.children[id] ?? [], depth: 0, filter: filter, into: &rows, forceOpen: [])
                } else {
                    outline([id], depth: 0, filter: sidebar == .review ? .remaining : filter, into: &rows, forceOpen: [id])
                }
            }
            return [OutlineSection(id: "focus", title: "", rows: rows)]
        case .tags:
            return snapshot.orderedTags.filter { tagFocus.isEmpty || tagFocus.contains($0.tag.id) }.compactMap { entry in
                let ids = (snapshot.tasksByTag[entry.tag.id] ?? []).filter { visible($0, filter: tagFilter) && snapshot.tasks[$0]?.isProject == false }
                guard !ids.isEmpty else { return nil }
                let sorted = PerspectiveEngine(snapshot).sort(ids, by: .manual)
                return OutlineSection(id: entry.tag.id, title: String(repeating: "    ", count: entry.depth) + entry.tag.name, rows: flat(sorted))
            }
        case .flagged:
            return PerspectiveEngine(snapshot).group(PerspectiveEngine(snapshot).sort(flaggedIDs(), by: .due), by: .project).map {
                OutlineSection(id: $0.id, title: $0.title, rows: flat($0.taskIDs, showProject: $0.id == "inbox"))
            }
        case .forecast:
            return forecastSections()
        case .nearby, .analytics, .kanban:
            return []
        case .perspective(let pid):
            guard let p = snapshot.perspectives.first(where: { $0.id == pid }) else { return [] }
            let sections = PerspectiveEngine(snapshot).evaluate(p)
            let extra = recentlyCompleted.filter { id in !sections.contains { $0.taskIDs.contains(id) } }
            let byProject = p.groupBy == .project
            var result = sections.map { OutlineSection(id: $0.id, title: $0.title, rows: flat($0.taskIDs, showProject: !byProject || $0.id == "inbox")) }
            if !extra.isEmpty { result.append(OutlineSection(id: "recent", title: "Just completed", rows: flat(Array(extra).sorted()))) }
            return result
        }
    }

    private func anchorDepth(_ id: String) -> Int {
        var n = 0, cur = inboxAnchor[id] ?? nil
        while let c = cur, n < 50 { n += 1; cur = inboxAnchor[c] ?? nil }
        return n
    }

    private func isDescendantRow(_ id: String, of ancestor: String) -> Bool {
        snapshot.ancestors(of: id).contains(ancestor)
    }

    func flat(_ ids: [String], showProject: Bool = true) -> [OutlineRow] {
        ids.compactMap { id in
            guard let t = snapshot.tasks[id] else { return nil }
            return OutlineRow(id: id, kind: t.isProject ? .project : .task, depth: 0, hasChildren: false, expanded: false,
                              showContext: true, showProject: showProject)
        }
    }

    func flaggedIDs() -> [String] {
        snapshot.tasks.values.filter { t in
            guard !t.isProject, let i = snapshot.info[t.id] else { return recentlyCompleted.contains(t.id) }
            return (i.isRemaining && i.effectiveFlagged && !i.isBlocked) || recentlyCompleted.contains(t.id)
        }.map(\.id)
    }

    func searchSections() -> [OutlineSection] {
        // Matches in either keyboard layout, so "ubnfhf" finds "гитара".
        let hits = snapshot.tasks.values.filter { t in Fuzzy.containsAllWords(searchText, in: t.title + " " + t.note) }
        let remaining = hits.filter { snapshot.info[$0.id]?.isRemaining == true }.map(\.id)
        let done = hits.filter { snapshot.info[$0.id]?.isRemaining != true }.map(\.id)
        let engine = PerspectiveEngine(snapshot)
        var out = [OutlineSection(id: "s-remaining", title: "Remaining", rows: flat(engine.sort(remaining, by: .manual)))]
        if !done.isEmpty { out.append(OutlineSection(id: "s-done", title: "Completed & dropped", rows: flat(engine.sort(done, by: .completed).prefix(200).map { $0 }))) }
        return out
    }

    // MARK: Forecast

    struct ForecastDay: Identifiable, Hashable {
        let id: Date
        let label: String
        let sublabel: String
        let count: Int
        let isPast: Bool
    }

    static let forecastStripDays = 12

    @ObservationIgnored private var countsCache: (version: Int, day: Date, counts: [Date: Int], past: Int, future: Int)?

    /// Due + planned counts per day (one pass over the database, cached per snapshot).
    var forecastCounts: (byDay: [Date: Int], past: Int, future: Int) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: snapshot.now)
        if let c = countsCache, c.version == snapshot.version, c.day == today { return (c.counts, c.past, c.future) }
        let horizon = cal.date(byAdding: .day, value: Self.forecastStripDays, to: today)!
        var counts: [Date: Int] = [:]
        var past = 0, future = 0
        for t in snapshot.tasks.values {
            guard let i = snapshot.info[t.id], i.isRemaining else { continue }
            // Available flagged actions are also listed under Today (see forecastSections).
            let flaggedToday = !t.isProject && i.isAvailable && i.effectiveFlagged
            guard let d = t.dueDate ?? t.plannedDate else {
                if flaggedToday { counts[today, default: 0] += 1 }
                continue
            }
            if d < today { if t.dueDate != nil { past += 1 } else if flaggedToday { counts[today, default: 0] += 1 }; continue }
            let day = cal.startOfDay(for: d)
            counts[day, default: 0] += 1
            if day != today && flaggedToday { counts[today, default: 0] += 1 }
            if day >= horizon { future += 1 }
        }
        countsCache = (snapshot.version, today, counts, past, future)
        return (counts, past, future)
    }

    var forecastDays: [ForecastDay] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: snapshot.now)
        let counts = forecastCounts
        let wd = DateFormatter(); wd.dateFormat = "EEE d"
        var out = [ForecastDay(id: .distantPast, label: "Past", sublabel: "", count: counts.past, isPast: true)]
        for n in 0..<Self.forecastStripDays {
            let d = cal.date(byAdding: .day, value: n, to: today)!
            out.append(ForecastDay(id: d, label: n == 0 ? "Today" : wd.string(from: d), sublabel: "\(cal.component(.day, from: d))",
                                   count: counts.byDay[d] ?? 0, isPast: false))
        }
        out.append(ForecastDay(id: .distantFuture, label: "Future", sublabel: "", count: counts.future, isPast: false))
        return out
    }

    func forecastIDs(for day: Date) -> (due: [String], planned: [String], deferred: [String]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: snapshot.now)
        let horizon = cal.date(byAdding: .day, value: Self.forecastStripDays, to: today)!
        func inDay(_ d: Date?) -> Bool {
            guard let d else { return false }
            if day == .distantPast { return d < today }
            if day == .distantFuture { return d >= horizon }
            return cal.isDate(d, inSameDayAs: day)
        }
        var due: [String] = [], planned: [String] = [], deferred: [String] = []
        for t in snapshot.tasks.values {
            guard let i = snapshot.info[t.id], i.isRemaining || recentlyCompleted.contains(t.id) else { continue }
            if inDay(t.dueDate) { due.append(t.id) }
            else if inDay(t.plannedDate) { planned.append(t.id) }
            else if day != .distantPast, inDay(t.deferDate) { deferred.append(t.id) }
        }
        let e = PerspectiveEngine(snapshot)
        return (e.sort(due, by: .due), e.sort(planned, by: .planned), e.sort(deferred, by: .deferDate))
    }

    func forecastSections() -> [OutlineSection] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: snapshot.now)
        var out: [OutlineSection] = []
        var past: [String] = []
        if forecastDay == today {
            past = forecastIDs(for: .distantPast).due
            if !past.isEmpty { out.append(OutlineSection(id: "past", title: "Past", rows: flat(past))) }
        }
        let ids = forecastIDs(for: forecastDay)
        let dayTitle: String = {
            if forecastDay == .distantPast { return "Past" }
            if forecastDay == .distantFuture { return "Future" }
            let d = forecastDay.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            if forecastDay == today { return "Today — \(d)" }
            if cal.isDateInTomorrow(forecastDay) { return "Tomorrow — \(d)" }
            return d
        }()
        var main = ids.due + ids.planned
        if forecastDay == today {
            // Today also lists every available flagged action, and ready work comes first:
            // flagged & available, then other available items, then what isn't available yet.
            let shown = Set(main + past)
            let flagged = snapshot.tasks.values
                .filter { !$0.isProject && !shown.contains($0.id) && snapshot.info[$0.id]?.isAvailable == true && snapshot.info[$0.id]?.effectiveFlagged == true }
                .map(\.id)
            main += PerspectiveEngine(snapshot).sort(flagged, by: .due)
            func rank(_ id: String) -> Int {
                let available = snapshot.info[id]?.isAvailable == true
                let flag = snapshot.info[id]?.effectiveFlagged == true
                return available ? (flag ? 0 : 1) : 2
            }
            let pos = Dictionary(uniqueKeysWithValues: main.enumerated().map { ($1, $0) })
            main.sort { (rank($0), pos[$0]!) < (rank($1), pos[$1]!) }
        }
        if !main.isEmpty || forecastDay == today { out.append(OutlineSection(id: "day", title: dayTitle, rows: flat(main))) }
        if !ids.deferred.isEmpty { out.append(OutlineSection(id: "deferred", title: "Becoming available", rows: flat(ids.deferred))) }
        return out
    }
}

extension Notification.Name {
    static let taskerQuickAdded = Notification.Name("taskerQuickAdded")
    static let taskerShowQuickEntry = Notification.Name("taskerShowQuickEntry")
}
