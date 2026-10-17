import Foundation
import Observation
import SwiftUI
import TaskerCore

enum SidebarItem: Hashable, Codable {
    case inbox, forecast, flagged, projects, tags, review, nearby
    case perspective(String)

    var title: String {
        switch self {
        case .inbox: "Inbox"; case .forecast: "Forecast"; case .flagged: "Flagged"
        case .projects: "Projects"; case .tags: "Tags"; case .review: "Review"; case .nearby: "Nearby"
        case .perspective: "Perspective"
        }
    }
    var icon: String {
        switch self {
        case .inbox: "tray"; case .forecast: "calendar"; case .flagged: "flag"
        case .projects: "folder"; case .tags: "tag"; case .review: "cup.and.saucer"; case .nearby: "location"
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
    private(set) var snapshot: Snapshot
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
    /// Row whose note is being edited inline.
    var noteEditingID: String?
    /// Row whose project field is open (OmniFocus combo), and text to start with.
    var projectEditingID: String?
    var projectEditingSeed = ""
    var recentlyCompleted: Set<String> = []
    /// Items filed out of the Inbox this session; like OmniFocus they stay visible there until Clean Up.
    var inboxKept: Set<String> = []
    /// Where each filed item sat: the inbox item just above it (nil = top), so it can stay in place.
    @ObservationIgnored var inboxAnchor: [String: String?] = [:]
    @ObservationIgnored var inboxIndex: [String: Int] = [:]
    var filter: ItemFilter = .remaining
    var tagFilter: ItemFilter = .available
    var searchText = ""
    var forecastDay: Date = Calendar.current.startOfDay(for: Date())
    var expanded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "expanded") ?? []) {
        didSet { UserDefaults.standard.set(Array(expanded), forKey: "expanded") }
    }
    /// Sidebar selection in Projects/Review (projects or folders shown in the main view).
    var projectFocus: Set<String> = [] { didSet { if projectFocus != oldValue { recordNav() } } }
    /// Sidebar selection in Tags.
    var tagFocus: Set<String> = [] { didSet { if tagFocus != oldValue { recordNav() } } }
    /// OmniFocus "Focus": when set, every view only shows these projects/folders and their contents.
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

    @discardableResult
    func perform(_ name: String, _ body: (inout Tx) -> Void) -> Bool {
        guard let record = store.transact(name, body) else { return false }
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
            if t.isProject { n.parent = s; n.placement = .end }
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

    /// Ends inline editing; Return on a non-empty title opens the next sibling (OmniFocus style).
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

    func indent(_ ids: [String]) { perform("Indent") { tx in for id in ids { tx.indent(id) } } ; for id in ids { if let p = snapshot.info[id]?.parentID { expanded.insert(p) } } }
    func outdent(_ ids: [String]) { perform("Outdent") { tx in for id in ids { tx.outdent(id) } } }

    func moveUpDown(_ id: String, up: Bool) {
        let parentKey: String
        if let t = snapshot.tasks[id] {
            parentKey = t.isProject ? (snapshot.projectInfo[id]?.folderID ?? Snapshot.libraryKey) : (snapshot.info[id]?.parentID ?? Snapshot.inboxKey)
        } else if let f = snapshot.folders[id] {
            parentKey = f.position.parent.flatMap { snapshot.folders[$0] != nil ? $0 : nil } ?? Snapshot.libraryKey
        } else { return }
        let siblings = snapshot.children[parentKey] ?? []
        guard let i = siblings.firstIndex(of: id) else { return }
        let j = up ? i - 1 : i + 1
        guard siblings.indices.contains(j) else { return }
        let parent: String? = parentKey.hasPrefix("#") ? nil : parentKey
        perform("Move") { tx in
            if tx.base.folders[id] != nil { tx.moveFolder(id, to: parent, placement: up ? .before(siblings[j]) : .after(siblings[j])) }
            else { tx.move(id, to: parent, placement: up ? .before(siblings[j]) : .after(siblings[j])) }
        }
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

    /// OmniFocus "Clean Up": hide completed items and items already filed out of the Inbox.
    func cleanUp() {
        recentlyCompleted = []
        inboxKept = []
        inboxAnchor = [:]
        inboxIndex = [:]
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

    // MARK: Quick entry

    struct Capture: Equatable {
        var title = ""
        var note = ""
        var projectID: String?
        var tagIDs: [String] = []
        var flagged = false
        var dueDate: Date?
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
        guard !focusIDs.isEmpty else { return raw }
        return raw.map { sec in
            var s = sec
            s.rows = sec.rows.filter { inFocus($0.id) }
            return s
        }.filter { !$0.rows.isEmpty || $0.title.isEmpty }
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
        case .nearby:
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
            guard let d = t.dueDate ?? t.plannedDate else { continue }
            if d < today { if t.dueDate != nil { past += 1 }; continue }
            let day = cal.startOfDay(for: d)
            counts[day, default: 0] += 1
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
        if forecastDay == today {
            let past = forecastIDs(for: .distantPast).due
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
        let main = ids.due + ids.planned
        if !main.isEmpty || forecastDay == today { out.append(OutlineSection(id: "day", title: dayTitle, rows: flat(main))) }
        if !ids.deferred.isEmpty { out.append(OutlineSection(id: "deferred", title: "Becoming available", rows: flat(ids.deferred))) }
        return out
    }
}
